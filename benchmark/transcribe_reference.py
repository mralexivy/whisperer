#!/usr/bin/env python3
"""
Reference transcription using PyTorch + the same MLX whisper model weights.
Tests the mel spectrogram → encoder → decoder pipeline against known audio.
"""

import numpy as np
import torch
import torch.nn.functional as F
import json
import struct
import os
import sys

# Constants
N_FFT = 400
HOP_LENGTH = 160
SAMPLE_RATE = 16000
TARGET_LENGTH = 30 * SAMPLE_RATE

MODEL_DIR = os.path.expanduser("~/Library/Application Support/Whisperer/mlx-models/mlx-whisper-tiny")
RECORDINGS_DIR = os.path.expanduser("~/Library/Application Support/Whisperer/Recordings/")
MEL_FILTERS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mel_filters.npz")


def load_wav_float32(path):
    """Load a WAV file with float32 PCM format."""
    with open(path, 'rb') as f:
        f.read(12)  # RIFF + size + WAVE
        while True:
            chunk_id = f.read(4)
            if len(chunk_id) < 4:
                break
            chunk_size = struct.unpack('<I', f.read(4))[0]
            if chunk_id == b'fmt ':
                fmt_data = f.read(chunk_size)
                format_tag = struct.unpack('<H', fmt_data[:2])[0]
            elif chunk_id == b'data':
                if format_tag == 3:  # float32
                    return np.frombuffer(f.read(chunk_size), dtype=np.float32)
                elif format_tag == 1:  # int16
                    return np.frombuffer(f.read(chunk_size), dtype=np.int16).astype(np.float32) / 32768.0
            else:
                f.read(chunk_size)
    raise ValueError("Could not read WAV file")


def compute_mel_spectrogram(audio_np, n_mels=80):
    """Compute mel spectrogram using reference whisper algorithm."""
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

    return log_spec


def main():
    print("=" * 60)
    print("REFERENCE TRANSCRIPTION BENCHMARK")
    print("=" * 60)

    # Check model files
    config_path = os.path.join(MODEL_DIR, "config.json")
    if not os.path.exists(config_path):
        print(f"ERROR: Model not found at {MODEL_DIR}")
        sys.exit(1)

    with open(config_path) as f:
        config = json.load(f)

    n_mels = config.get('num_mel_bins', 80)
    print(f"\nModel: whisper-tiny")
    print(f"  d_model: {config.get('d_model', '?')}")
    print(f"  encoder_layers: {config.get('encoder_layers', '?')}")
    print(f"  decoder_layers: {config.get('decoder_layers', '?')}")
    print(f"  num_mel_bins: {n_mels}")
    print(f"  vocab_size: {config.get('vocab_size', '?')}")

    # Find audio file
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
        print("ERROR: No recordings found")
        sys.exit(1)

    print(f"\nAudio: {os.path.basename(audio_file)}")
    audio_samples = load_wav_float32(audio_file)
    duration = len(audio_samples) / SAMPLE_RATE
    print(f"  Duration: {duration:.2f}s, Samples: {len(audio_samples)}")
    print(f"  RMS: {np.sqrt(np.mean(audio_samples**2)):.4f}")

    # Compute mel spectrogram
    print(f"\nComputing mel spectrogram (n_mels={n_mels})...")
    mel = compute_mel_spectrogram(audio_samples, n_mels=n_mels)
    print(f"  Shape: {mel.shape}")
    print(f"  Range: [{mel.min():.4f}, {mel.max():.4f}]")
    print(f"  Mean: {mel.mean():.4f}, Std: {mel.std():.4f}")

    # Save mel spectrogram for Swift comparison
    mel_np = mel.numpy()
    np.save(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'reference_mel.npy'), mel_np)
    print(f"  Saved reference mel to benchmark/reference_mel.npy")

    # Print first few values for manual comparison
    print(f"\n  First 10 values (mel[0, :10]): {mel_np[0, :10]}")
    print(f"  First 10 values (mel[64, :10]): {mel_np[min(64, n_mels-1), :10]}")
    print(f"  Max position: {np.unravel_index(mel_np.argmax(), mel_np.shape)}")

    # Try to do inference with transformers if available
    try:
        from transformers import WhisperForConditionalGeneration, WhisperProcessor
        print("\n--- TRANSFORMERS INFERENCE ---")
        print("Loading model from local directory...")

        model = WhisperForConditionalGeneration.from_pretrained(MODEL_DIR)
        model.eval()

        # Use our mel as input features
        mel_input = mel.unsqueeze(0)  # [1, n_mels, n_frames]

        print(f"Input features shape: {mel_input.shape}")

        with torch.no_grad():
            # Encode
            encoder_output = model.model.encoder(mel_input)
            print(f"Encoder output shape: {encoder_output.last_hidden_state.shape}")

            # Generate with greedy decoding
            generated_ids = model.generate(
                mel_input,
                max_new_tokens=224,
                do_sample=False,
                num_beams=1,
            )
            print(f"Generated token IDs: {generated_ids[0].tolist()[:20]}...")

        # Try loading tokenizer
        try:
            processor = WhisperProcessor.from_pretrained(MODEL_DIR)
            text = processor.batch_decode(generated_ids, skip_special_tokens=True)[0]
            print(f"\nTRANSCRIPTION: \"{text}\"")
        except Exception as e:
            print(f"Tokenizer error: {e}")
            # Manual decode using tokenizer.json
            import json as json2
            with open(os.path.join(MODEL_DIR, 'tokenizer.json')) as f:
                tok_data = json2.load(f)
            vocab = {v: k for k, v in tok_data.get('model', {}).get('vocab', {}).items()}
            tokens = generated_ids[0].tolist()
            # Filter special tokens
            eot = config.get('eos_token_id', 50257)
            tokens = [t for t in tokens if t < 50257 and t != eot]
            text = ''.join(vocab.get(t, f'[{t}]') for t in tokens)
            print(f"\nTRANSCRIPTION (manual decode): \"{text}\"")

    except ImportError:
        print("\n--- TRANSFORMERS NOT AVAILABLE ---")
        print("Install with: pip install transformers")
        print("Skipping model inference, mel spectrogram saved for comparison.")

    print("\n" + "=" * 60)
    print("DONE")
    print("=" * 60)


if __name__ == "__main__":
    main()
