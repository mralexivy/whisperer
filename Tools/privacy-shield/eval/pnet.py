"""Causal predictive perturbation network for Privacy Shield (clean-room; design follows the public
Neural Voice Camouflage idea: predict the perturbation for the next block from the past only).

Runs at 16 kHz on 10 ms blocks (160 samples). For block t it only sees samples before 160*t, so the
perturbation for the block being spoken is ready before that block arrives: zero added latency on the
voice path. Small on purpose (about 1M parameters) so the app can run it in plain C++ with Accelerate,
one convolution + one GRU step per block, without Core ML in the audio callback.

Streaming and batch forms are numerically identical (tested in test_pnet.py); export_weights writes the
flat float32 file the native processor loads.
"""
import json, struct
import numpy as np
import torch
import torch.nn as nn

HOP = 160          # 10 ms at 16 kHz
WIN = 400          # 25 ms analysis window, ending at the block boundary


class PerturbNet(nn.Module):
    def __init__(self, channels=96, hidden=256, layers=2, max_amp=0.05):
        super().__init__()
        self.channels, self.hidden, self.layers, self.max_amp = channels, hidden, layers, max_amp
        self.frontend = nn.Conv1d(1, channels, WIN, stride=HOP, bias=True)
        self.norm = nn.LayerNorm(channels)
        self.gru = nn.GRU(channels + 1, hidden, num_layers=layers, batch_first=True)
        self.head = nn.Linear(hidden, HOP + 1)   # 160 waveform samples + one gain logit

    def forward(self, x):
        """x: [B, T] 16 kHz (T multiple of HOP). Returns delta [B, T], strictly causal per block."""
        B, T = x.shape
        n = T // HOP
        # Frame t sees x[160t-400 : 160t]: left-pad by WIN so frame 0 sees only silence.
        xp = torch.nn.functional.pad(x, (WIN, 0))[:, : n * HOP + WIN - HOP]
        f = self.frontend(xp.unsqueeze(1)).transpose(1, 2)            # [B, n, C]
        f = self.norm(torch.tanh(f))
        # Loudness of the same past window, log-compressed, as an explicit input (scale awareness).
        frames = xp.unfold(1, WIN, HOP)[:, :n]                        # [B, n, WIN]
        loud = torch.log10(frames.pow(2).mean(-1, keepdim=True) + 1e-6)
        h, _ = self.gru(torch.cat([f, loud], -1))
        out = self.head(h)                                            # [B, n, HOP+1]
        wave = torch.tanh(out[..., :HOP])
        gain = torch.sigmoid(out[..., HOP:]) * self.max_amp
        # Scale by the past window's RMS so the perturbation follows the voice (silent in silence).
        rms = frames.pow(2).mean(-1, keepdim=True).sqrt()
        delta = wave * gain * (rms / (rms + 0.01))
        return delta.reshape(B, n * HOP)

    @torch.no_grad()
    def stream(self, x):
        """Reference streaming implementation: one block at a time with explicit state (what the C++
        processor does). x: [T] 16 kHz."""
        n = len(x) // HOP
        hist = torch.zeros(WIN)
        state = torch.zeros(self.layers, 1, self.hidden)
        out = []
        for t in range(n):
            f = torch.tanh(self.frontend(hist.view(1, 1, WIN))).view(1, 1, -1)
            f = self.norm(f)
            loud = torch.log10(hist.pow(2).mean() + 1e-6).view(1, 1, 1)
            h, state = self.gru(torch.cat([f, loud], -1), state)
            o = self.head(h).view(-1)
            wave = torch.tanh(o[:HOP]); gain = torch.sigmoid(o[HOP:]) * self.max_amp
            rms = hist.pow(2).mean().sqrt()
            out.append(wave * gain * (rms / (rms + 0.01)))
            hist = torch.cat([hist[HOP:], x[t * HOP:(t + 1) * HOP]])
        return torch.cat(out)


def export_weights(model, path):
    """Flat little-endian float32 blob + JSON header for the native processor.
    Order: frontend.w [C,WIN], frontend.b [C], norm.w [C], norm.b [C], then per GRU layer
    w_ih [3H, in], w_hh [3H, H], b_ih [3H], b_hh [3H] (PyTorch gate order r,z,n), head.w [HOP+1, H], head.b."""
    m = model.eval()
    tensors = [m.frontend.weight.view(m.channels, WIN), m.frontend.bias, m.norm.weight, m.norm.bias]
    for l in range(m.layers):
        tensors += [getattr(m.gru, f"weight_ih_l{l}"), getattr(m.gru, f"weight_hh_l{l}"),
                    getattr(m.gru, f"bias_ih_l{l}"), getattr(m.gru, f"bias_hh_l{l}")]
    tensors += [m.head.weight, m.head.bias]
    header = {"format": "whisperer-shield-pnet", "version": 1, "rate": 16000, "hop": HOP, "win": WIN,
              "channels": m.channels, "hidden": m.hidden, "layers": m.layers, "max_amp": m.max_amp,
              "norm_eps": m.norm.eps, "count": int(sum(t.numel() for t in tensors))}
    blob = np.concatenate([t.detach().cpu().float().numpy().ravel() for t in tensors]).astype("<f4")
    h = json.dumps(header).encode()
    with open(path, "wb") as f:
        f.write(b"WSPN"); f.write(struct.pack("<I", len(h))); f.write(h); f.write(blob.tobytes())
    return header
