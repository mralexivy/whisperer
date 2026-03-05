#!/usr/bin/env python3
"""
Minimal Whisper inference using PyTorch (no transformers/whisper library needed).
Loads weights from safetensors format and runs greedy decoding.
Uses OpenAI whisper weight naming convention (encoder.blocks.X.attn.query, etc.)
"""

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import json
import struct
import os
import sys
import math

MODEL_DIR = os.path.expanduser("~/Library/Application Support/Whisperer/mlx-models/mlx-whisper-tiny")
RECORDINGS_DIR = os.path.expanduser("~/Library/Application Support/Whisperer/Recordings/")
MEL_FILTERS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mel_filters.npz")

N_FFT = 400
HOP_LENGTH = 160
SAMPLE_RATE = 16000
TARGET_LENGTH = 30 * SAMPLE_RATE


# ---- Safetensors Reader ----

def load_safetensors(path):
    """Load tensors from a safetensors file."""
    with open(path, 'rb') as f:
        header_size = struct.unpack('<Q', f.read(8))[0]
        header = json.loads(f.read(header_size))
        data_start = 8 + header_size

        tensors = {}
        for name, info in header.items():
            if name == '__metadata__':
                continue
            dtype_str = info['dtype']
            shape = info['shape']
            offsets = info['data_offsets']

            dtype_map = {
                'F32': np.float32, 'F16': np.float16,
                'BF16': np.float32,  # Will convert manually
                'I32': np.int32, 'I64': np.int64,
            }

            f.seek(data_start + offsets[0])
            size = offsets[1] - offsets[0]
            raw = f.read(size)

            if dtype_str == 'BF16':
                arr16 = np.frombuffer(raw, dtype=np.uint16)
                arr32 = np.zeros(len(arr16), dtype=np.uint32)
                arr32[:] = arr16.astype(np.uint32) << 16
                arr = arr32.view(np.float32).reshape(shape)
            else:
                np_dtype = dtype_map.get(dtype_str, np.float32)
                arr = np.frombuffer(raw, dtype=np_dtype).reshape(shape)

            tensors[name] = torch.from_numpy(arr.copy()).float()

    return tensors


# ---- Audio Loading ----

def load_wav_float32(path):
    with open(path, 'rb') as f:
        f.read(12)
        format_tag = 1
        while True:
            chunk_id = f.read(4)
            if len(chunk_id) < 4:
                break
            chunk_size = struct.unpack('<I', f.read(4))[0]
            if chunk_id == b'fmt ':
                fmt_data = f.read(chunk_size)
                format_tag = struct.unpack('<H', fmt_data[:2])[0]
            elif chunk_id == b'data':
                if format_tag == 3:
                    return np.frombuffer(f.read(chunk_size), dtype=np.float32)
                else:
                    return np.frombuffer(f.read(chunk_size), dtype=np.int16).astype(np.float32) / 32768.0
            else:
                f.read(chunk_size)
    raise ValueError("Could not read WAV")


# ---- Mel Spectrogram ----

def compute_mel(audio_np, n_mels=80):
    mel_filters = np.load(MEL_FILTERS_PATH)[f'mel_{n_mels}']
    audio = torch.from_numpy(audio_np.copy()).float()
    if len(audio) < TARGET_LENGTH:
        audio = F.pad(audio, (0, TARGET_LENGTH - len(audio)))
    else:
        audio = audio[:TARGET_LENGTH]

    window = torch.hann_window(N_FFT)
    stft = torch.stft(audio, N_FFT, HOP_LENGTH, window=window, return_complex=True)
    magnitudes = stft[..., :-1].abs() ** 2

    filters = torch.from_numpy(mel_filters).float()
    mel_spec = filters @ magnitudes
    log_spec = torch.clamp(mel_spec, min=1e-10).log10()
    log_spec = torch.maximum(log_spec, log_spec.max() - 8.0)
    log_spec = (log_spec + 4.0) / 4.0

    return log_spec.unsqueeze(0)  # [1, n_mels, 3000]


# ---- Whisper Model (OpenAI weight naming) ----

class WhisperAttention(nn.Module):
    def __init__(self, d, n_heads, weights, prefix):
        super().__init__()
        self.n_heads = n_heads
        self.head_dim = d // n_heads

        self.q_proj = nn.Linear(d, d)
        self.q_proj.weight.data = weights[f'{prefix}.query.weight']
        self.q_proj.bias.data = weights[f'{prefix}.query.bias']

        self.k_proj = nn.Linear(d, d, bias=False)
        self.k_proj.weight.data = weights[f'{prefix}.key.weight']

        self.v_proj = nn.Linear(d, d)
        self.v_proj.weight.data = weights[f'{prefix}.value.weight']
        self.v_proj.bias.data = weights[f'{prefix}.value.bias']

        self.out_proj = nn.Linear(d, d)
        self.out_proj.weight.data = weights[f'{prefix}.out.weight']
        self.out_proj.bias.data = weights[f'{prefix}.out.bias']

    def forward(self, x, xa=None, mask=None):
        batch, seq, _ = x.shape
        q = self.q_proj(x).view(batch, seq, self.n_heads, self.head_dim).transpose(1, 2)

        source = xa if xa is not None else x
        src_seq = source.shape[1]
        k = self.k_proj(source).view(batch, src_seq, self.n_heads, self.head_dim).transpose(1, 2)
        v = self.v_proj(source).view(batch, src_seq, self.n_heads, self.head_dim).transpose(1, 2)

        scale = 1.0 / math.sqrt(self.head_dim)
        attn = torch.matmul(q, k.transpose(-2, -1)) * scale
        if mask is not None:
            attn = attn + mask
        attn = F.softmax(attn, dim=-1)
        out = torch.matmul(attn, v)

        out = out.transpose(1, 2).contiguous().view(batch, seq, -1)
        return self.out_proj(out)


class WhisperEncoderBlock(nn.Module):
    def __init__(self, d, n_heads, ffn_dim, weights, prefix):
        super().__init__()
        self.self_attn = WhisperAttention(d, n_heads, weights, f'{prefix}.attn')
        self.attn_ln = nn.LayerNorm(d)
        self.attn_ln.weight.data = weights[f'{prefix}.attn_ln.weight']
        self.attn_ln.bias.data = weights[f'{prefix}.attn_ln.bias']

        self.mlp1 = nn.Linear(d, ffn_dim)
        self.mlp1.weight.data = weights[f'{prefix}.mlp1.weight']
        self.mlp1.bias.data = weights[f'{prefix}.mlp1.bias']
        self.mlp2 = nn.Linear(ffn_dim, d)
        self.mlp2.weight.data = weights[f'{prefix}.mlp2.weight']
        self.mlp2.bias.data = weights[f'{prefix}.mlp2.bias']
        self.mlp_ln = nn.LayerNorm(d)
        self.mlp_ln.weight.data = weights[f'{prefix}.mlp_ln.weight']
        self.mlp_ln.bias.data = weights[f'{prefix}.mlp_ln.bias']

    def forward(self, x):
        residual = x
        x = self.attn_ln(x)
        x = self.self_attn(x) + residual

        residual = x
        x = self.mlp_ln(x)
        x = F.gelu(self.mlp1(x))
        x = self.mlp2(x) + residual
        return x


class WhisperEncoder(nn.Module):
    def __init__(self, config, weights):
        super().__init__()
        d = config['d_model']
        n_heads = config['encoder_attention_heads']
        n_layers = config['encoder_layers']
        n_mels = config['num_mel_bins']

        self.conv1 = nn.Conv1d(n_mels, d, 3, padding=1)
        self.conv2 = nn.Conv1d(d, d, 3, stride=2, padding=1)

        # MLX stores conv weights as [out, kernel, in], PyTorch needs [out, in, kernel]
        conv1_w = weights['encoder.conv1.weight']  # [384, 3, 80]
        self.conv1.weight.data = conv1_w.permute(0, 2, 1)  # [384, 80, 3]
        self.conv1.bias.data = weights['encoder.conv1.bias']

        conv2_w = weights['encoder.conv2.weight']  # [384, 3, 384]
        self.conv2.weight.data = conv2_w.permute(0, 2, 1)  # [384, 384, 3]
        self.conv2.bias.data = weights['encoder.conv2.bias']

        # Positional embedding: stored directly (no embed_positions wrapper)
        # OpenAI whisper computes sinusoidal positional embedding but MLX models
        # may store it under a different key. Let's check.
        if 'encoder.positional_embedding' in weights:
            self.positional_embedding = weights['encoder.positional_embedding']
        else:
            # Compute sinusoidal positional embedding matching mlx-whisper's sinusoids()
            max_len = 1500
            half_dim = d // 2
            log_timescale_increment = math.log(10000.0) / (half_dim - 1)
            inv_timescales = torch.exp(-log_timescale_increment * torch.arange(half_dim).float())
            scaled_time = torch.arange(max_len).unsqueeze(1).float() * inv_timescales.unsqueeze(0)
            # Concatenate [sin, cos] (NOT interleaved)
            self.positional_embedding = torch.cat([torch.sin(scaled_time), torch.cos(scaled_time)], dim=1)

        self.layers = nn.ModuleList()
        for i in range(n_layers):
            layer = WhisperEncoderBlock(d, n_heads, config['encoder_ffn_dim'], weights, f'encoder.blocks.{i}')
            self.layers.append(layer)

        self.ln_post = nn.LayerNorm(d)
        self.ln_post.weight.data = weights['encoder.ln_post.weight']
        self.ln_post.bias.data = weights['encoder.ln_post.bias']

    def forward(self, mel):
        x = F.gelu(self.conv1(mel))
        x = F.gelu(self.conv2(x))
        x = x.permute(0, 2, 1)  # [batch, seq, d]
        x = x + self.positional_embedding[:x.shape[1]]
        for layer in self.layers:
            x = layer(x)
        x = self.ln_post(x)
        return x


class WhisperDecoderBlock(nn.Module):
    def __init__(self, d, n_heads, ffn_dim, weights, prefix):
        super().__init__()
        self.self_attn = WhisperAttention(d, n_heads, weights, f'{prefix}.attn')
        self.attn_ln = nn.LayerNorm(d)
        self.attn_ln.weight.data = weights[f'{prefix}.attn_ln.weight']
        self.attn_ln.bias.data = weights[f'{prefix}.attn_ln.bias']

        self.cross_attn = WhisperAttention(d, n_heads, weights, f'{prefix}.cross_attn')
        self.cross_attn_ln = nn.LayerNorm(d)
        self.cross_attn_ln.weight.data = weights[f'{prefix}.cross_attn_ln.weight']
        self.cross_attn_ln.bias.data = weights[f'{prefix}.cross_attn_ln.bias']

        self.mlp1 = nn.Linear(d, ffn_dim)
        self.mlp1.weight.data = weights[f'{prefix}.mlp1.weight']
        self.mlp1.bias.data = weights[f'{prefix}.mlp1.bias']
        self.mlp2 = nn.Linear(ffn_dim, d)
        self.mlp2.weight.data = weights[f'{prefix}.mlp2.weight']
        self.mlp2.bias.data = weights[f'{prefix}.mlp2.bias']
        self.mlp_ln = nn.LayerNorm(d)
        self.mlp_ln.weight.data = weights[f'{prefix}.mlp_ln.weight']
        self.mlp_ln.bias.data = weights[f'{prefix}.mlp_ln.bias']

    def forward(self, x, audio_features, mask=None):
        residual = x
        x = self.attn_ln(x)
        x = self.self_attn(x, mask=mask) + residual

        residual = x
        x = self.cross_attn_ln(x)
        x = self.cross_attn(x, xa=audio_features) + residual

        residual = x
        x = self.mlp_ln(x)
        x = F.gelu(self.mlp1(x))
        x = self.mlp2(x) + residual
        return x


class WhisperDecoder(nn.Module):
    def __init__(self, config, weights):
        super().__init__()
        d = config['d_model']
        n_heads = config['decoder_attention_heads']
        n_layers = config['decoder_layers']
        vocab_size = config['vocab_size']

        self.embed_tokens = nn.Embedding(vocab_size, d)
        self.embed_tokens.weight.data = weights['decoder.token_embedding.weight']
        self.embed_positions = weights['decoder.positional_embedding']  # [448, d]

        self.layers = nn.ModuleList()
        for i in range(n_layers):
            layer = WhisperDecoderBlock(d, n_heads, config['decoder_ffn_dim'], weights, f'decoder.blocks.{i}')
            self.layers.append(layer)

        self.ln = nn.LayerNorm(d)
        self.ln.weight.data = weights['decoder.ln.weight']
        self.ln.bias.data = weights['decoder.ln.bias']

    def forward(self, tokens, audio_features, offset=0):
        seq_len = tokens.shape[1]
        x = self.embed_tokens(tokens) + self.embed_positions[offset:offset + seq_len]

        # Causal mask for multi-token input
        mask = None
        if seq_len > 1:
            mask = torch.full((seq_len, seq_len), float('-inf'))
            mask = torch.triu(mask, diagonal=1).unsqueeze(0).unsqueeze(0)

        for layer in self.layers:
            x = layer(x, audio_features, mask=mask)

        x = self.ln(x)
        # Project to vocab using tied weights
        logits = x @ self.embed_tokens.weight.T
        return logits


# ---- Tokenizer ----

def load_tokenizer(model_dir):
    """Load tokenizer vocabulary from tokenizer.json."""
    with open(os.path.join(model_dir, 'tokenizer.json')) as f:
        tok_data = json.load(f)

    vocab = tok_data.get('model', {}).get('vocab', {})
    id_to_token = {v: k for k, v in vocab.items()}
    return id_to_token


def decode_tokens(token_ids, id_to_token, eot_token=50257):
    """Decode token IDs to text, filtering special tokens."""
    text_pieces = []
    for t in token_ids:
        if t >= 50257 or t == eot_token:
            continue
        token_str = id_to_token.get(t, '')
        # Handle byte-level BPE: Ġ = space
        token_str = token_str.replace('Ġ', ' ')
        # Handle special byte tokens like <0xNN>
        if token_str.startswith('<0x') and token_str.endswith('>'):
            try:
                byte_val = int(token_str[3:-1], 16)
                token_str = chr(byte_val)
            except ValueError:
                pass
        text_pieces.append(token_str)
    return ''.join(text_pieces)


# ---- Main ----

def main():
    print("=" * 60)
    print("WHISPER TINY INFERENCE BENCHMARK")
    print("=" * 60)

    # Load config
    with open(os.path.join(MODEL_DIR, 'config.json')) as f:
        config = json.load(f)

    n_mels = config['num_mel_bins']
    print(f"\nModel config: d={config['d_model']}, enc={config['encoder_layers']}L, "
          f"dec={config['decoder_layers']}L, mels={n_mels}")

    # Load weights
    print("\nLoading safetensors weights...")
    weights_path = os.path.join(MODEL_DIR, 'model.safetensors')
    weights = load_safetensors(weights_path)
    print(f"  Loaded {len(weights)} tensors")

    # Print some weight stats for debugging
    for key in ['encoder.conv1.weight', 'decoder.token_embedding.weight', 'encoder.ln_post.weight']:
        if key in weights:
            w = weights[key]
            print(f"  {key}: shape={list(w.shape)}, mean={w.mean():.6f}, std={w.std():.6f}")

    # Build model
    print("Building model...")
    encoder = WhisperEncoder(config, weights)
    decoder = WhisperDecoder(config, weights)
    encoder.eval()
    decoder.eval()

    # Load tokenizer
    id_to_token = load_tokenizer(MODEL_DIR)
    print(f"  Vocab size: {len(id_to_token)}")

    # Find audio
    audio_file = None
    for fname in os.listdir(RECORDINGS_DIR):
        if fname.endswith('.wav') and 'Hello' in fname:
            audio_file = os.path.join(RECORDINGS_DIR, fname)
            break
    if audio_file is None:
        for fname in sorted(os.listdir(RECORDINGS_DIR)):
            if fname.endswith('.wav') and 'BLANK' not in fname:
                audio_file = os.path.join(RECORDINGS_DIR, fname)
                break

    if audio_file is None:
        print("ERROR: No audio files found")
        sys.exit(1)

    print(f"\nAudio: {os.path.basename(audio_file)}")
    audio = load_wav_float32(audio_file)
    print(f"  Duration: {len(audio)/SAMPLE_RATE:.2f}s")

    # Compute mel
    print("\nComputing mel spectrogram...")
    mel = compute_mel(audio, n_mels)
    print(f"  Mel shape: {mel.shape}")
    print(f"  Mel range: [{mel.min():.4f}, {mel.max():.4f}]")
    print(f"  Mel mean: {mel.mean():.4f}, std: {mel.std():.4f}")

    # Encode
    print("Encoding audio...")
    import time
    t0 = time.time()
    with torch.no_grad():
        audio_features = encoder(mel)
    t_enc = time.time() - t0
    print(f"  Encoder output: {audio_features.shape}")
    print(f"  Encoder time: {t_enc*1000:.1f}ms")
    print(f"  Encoder output stats: mean={audio_features.mean():.4f}, std={audio_features.std():.4f}")

    # Decode with greedy search
    print("Decoding (greedy)...")
    SOT = 50258
    EN = 50259
    TRANSCRIBE = 50359
    NOTIMESTAMPS = 50363
    EOT = 50257

    initial_tokens = [SOT, EN, TRANSCRIBE, NOTIMESTAMPS]
    generated = []

    t0 = time.time()
    with torch.no_grad():
        # Full-context decoding: feed all tokens each step (no KV cache)
        all_tokens = list(initial_tokens)
        token_input = torch.tensor([all_tokens], dtype=torch.long)
        logits = decoder(token_input, audio_features, offset=0)
        next_token = logits[0, -1].argmax().item()

        # Print top-5 tokens at first step
        probs = F.softmax(logits[0, -1], dim=-1)
        top5 = probs.topk(5)
        print(f"  First token top-5:")
        for i in range(5):
            tid = top5.indices[i].item()
            prob = top5.values[i].item()
            tok_str = id_to_token.get(tid, f'[{tid}]')
            print(f"    {tid} ({tok_str}): {prob:.4f}")

        # Full-context decode loop
        for step in range(224):
            if next_token == EOT:
                break
            generated.append(next_token)
            all_tokens.append(next_token)

            token_input = torch.tensor([all_tokens], dtype=torch.long)
            logits = decoder(token_input, audio_features, offset=0)
            next_token = logits[0, -1].argmax().item()

    t_dec = time.time() - t0
    print(f"\n  Generated {len(generated)} tokens in {t_dec*1000:.1f}ms")
    print(f"  Token IDs: {generated[:20]}{'...' if len(generated) > 20 else ''}")

    # Decode to text
    text = decode_tokens(generated, id_to_token)
    print(f"\n{'='*60}")
    print(f"TRANSCRIPTION: \"{text.strip()}\"")
    print(f"{'='*60}")

    # Also save encoder output for Swift comparison
    diag_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'reference_encoder_output.npy')
    np.save(diag_path, audio_features.numpy())
    print(f"\nSaved encoder output to {diag_path}")

    return text.strip()


if __name__ == "__main__":
    main()
