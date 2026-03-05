#!/usr/bin/env python3
"""
Mel spectrogram benchmark: compare Whisperer's Swift implementation against
the reference OpenAI Whisper mel spectrogram computation.

Tests:
1. Mel filterbank comparison (computed vs reference mel_filters.npz)
2. STFT comparison (our algorithm vs torch.stft)
3. Full mel spectrogram comparison
4. End-to-end transcription comparison (if whisper available)
"""

import numpy as np
import torch
import torch.nn.functional as F
import struct
import os
import sys

# Constants matching Whisper
N_FFT = 400
HOP_LENGTH = 160
N_MELS = 128
SAMPLE_RATE = 16000
TARGET_LENGTH = 30 * SAMPLE_RATE  # 480000 samples

BENCHMARK_DIR = os.path.dirname(os.path.abspath(__file__))
MEL_FILTERS_PATH = os.path.join(BENCHMARK_DIR, "mel_filters.npz")
RECORDINGS_DIR = os.path.expanduser("~/Library/Application Support/Whisperer/Recordings/")


def load_wav_float32(path):
    """Load a WAV file with float32 PCM format (format tag 3)."""
    with open(path, 'rb') as f:
        # Read RIFF header
        riff = f.read(4)
        assert riff == b'RIFF', f"Not a RIFF file: {riff}"
        file_size = struct.unpack('<I', f.read(4))[0]
        wave = f.read(4)
        assert wave == b'WAVE', f"Not a WAVE file: {wave}"

        fmt_found = False
        data_found = False
        samples = None
        n_channels = 1
        sample_rate = 16000
        bits_per_sample = 32

        while f.tell() < file_size + 8:
            chunk_id = f.read(4)
            if len(chunk_id) < 4:
                break
            chunk_size = struct.unpack('<I', f.read(4))[0]

            if chunk_id == b'fmt ':
                format_tag = struct.unpack('<H', f.read(2))[0]
                n_channels = struct.unpack('<H', f.read(2))[0]
                sample_rate = struct.unpack('<I', f.read(4))[0]
                byte_rate = struct.unpack('<I', f.read(4))[0]
                block_align = struct.unpack('<H', f.read(2))[0]
                bits_per_sample = struct.unpack('<H', f.read(2))[0]
                # Skip any extra fmt bytes
                extra = chunk_size - 16
                if extra > 0:
                    f.read(extra)
                fmt_found = True
                print(f"  WAV format: tag={format_tag}, channels={n_channels}, "
                      f"rate={sample_rate}Hz, bits={bits_per_sample}")

            elif chunk_id == b'data':
                if bits_per_sample == 32 and format_tag == 3:
                    # Float32 PCM
                    n_samples = chunk_size // 4
                    raw = f.read(chunk_size)
                    samples = np.frombuffer(raw, dtype=np.float32)
                elif bits_per_sample == 16:
                    # Int16 PCM
                    n_samples = chunk_size // 2
                    raw = f.read(chunk_size)
                    samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
                else:
                    f.read(chunk_size)
                    print(f"  WARNING: Unsupported bits_per_sample={bits_per_sample}")
                    continue
                data_found = True
            else:
                f.read(chunk_size)

        if not fmt_found or not data_found or samples is None:
            raise ValueError(f"Invalid WAV file: fmt={fmt_found}, data={data_found}")

        # Take first channel if stereo
        if n_channels > 1:
            samples = samples[::n_channels]

        return samples, sample_rate


def compute_mel_filterbank_slaney(n_mels, n_fft, sample_rate):
    """Compute mel filterbank using Slaney normalization (our Swift algorithm ported to Python)."""
    num_bins = n_fft // 2 + 1
    f_max = sample_rate / 2.0

    def hz_to_mel(hz):
        return 2595.0 * np.log10(1.0 + hz / 700.0)

    def mel_to_hz(mel):
        return 700.0 * (10.0 ** (mel / 2595.0) - 1.0)

    mel_min = hz_to_mel(0)
    mel_max = hz_to_mel(f_max)

    mel_points = np.linspace(mel_min, mel_max, n_mels + 2)
    bin_step = sample_rate / n_fft
    bin_freqs = mel_to_hz(mel_points) / bin_step

    filterbank = np.zeros((n_mels, num_bins), dtype=np.float32)

    for m in range(n_mels):
        left = bin_freqs[m]
        center = bin_freqs[m + 1]
        right = bin_freqs[m + 2]

        for k in range(num_bins):
            freq = float(k)
            if freq >= left and freq <= center and center > left:
                filterbank[m, k] = (freq - left) / (center - left)
            elif freq > center and freq <= right and right > center:
                filterbank[m, k] = (right - freq) / (right - center)

        # Slaney normalization
        enorm = 2.0 / (mel_to_hz(mel_points[m + 2]) - mel_to_hz(mel_points[m]))
        filterbank[m] *= enorm

    return filterbank


def compute_mel_our_algorithm(audio_np, mel_filters_ref):
    """Compute mel spectrogram using OUR algorithm (port of Swift code) for comparison."""
    # Pad to 30 seconds
    if len(audio_np) >= TARGET_LENGTH:
        audio = audio_np[:TARGET_LENGTH].copy()
    else:
        audio = np.zeros(TARGET_LENGTH, dtype=np.float32)
        audio[:len(audio_np)] = audio_np

    n_frames = (len(audio) - N_FFT) // HOP_LENGTH + 1
    num_bins = N_FFT // 2 + 1  # 201

    # Periodic Hanning window (matching our Swift code)
    window = np.array([0.5 - 0.5 * np.cos(2.0 * np.pi * i / N_FFT) for i in range(N_FFT)], dtype=np.float32)

    # STFT via complex DFT at exactly N_FFT points (no zero-padding, no centering)
    magnitudes = np.zeros((n_frames, num_bins), dtype=np.float32)

    for frame in range(n_frames):
        start = frame * HOP_LENGTH
        windowed = audio[start:start + N_FFT] * window

        # Complex FFT at N_FFT points
        spectrum = np.fft.fft(windowed, n=N_FFT)

        # Magnitude squared for bins 0..N_FFT/2
        for k in range(num_bins):
            magnitudes[frame, k] = np.abs(spectrum[k]) ** 2

    # Apply mel filterbank
    mel_spec = mel_filters_ref @ magnitudes.T  # (128, n_frames)

    # Log scale
    mel_spec = np.log10(np.maximum(mel_spec, 1e-10))

    # Normalize
    max_val = mel_spec.max()
    mel_spec = np.maximum(mel_spec, max_val - 8.0)
    mel_spec = (mel_spec + 4.0) / 4.0

    return mel_spec


def compute_mel_reference(audio_np, mel_filters_ref):
    """Compute mel spectrogram using the REFERENCE Whisper algorithm (torch.stft, center=True)."""
    audio_tensor = torch.from_numpy(audio_np).float()

    # Pad to 30 seconds
    if len(audio_tensor) < TARGET_LENGTH:
        audio_tensor = F.pad(audio_tensor, (0, TARGET_LENGTH - len(audio_tensor)))
    else:
        audio_tensor = audio_tensor[:TARGET_LENGTH]

    # Periodic Hanning window (PyTorch default)
    window = torch.hann_window(N_FFT)

    # STFT with center=True (default) — pads N_FFT//2 on each side
    stft = torch.stft(audio_tensor, N_FFT, HOP_LENGTH, window=window, return_complex=True)
    # stft shape: (201, n_frames)

    # Drop last frame, magnitude squared
    magnitudes = stft[..., :-1].abs() ** 2
    # magnitudes shape: (201, 3000) for 30s audio

    # Apply mel filterbank
    filters = torch.from_numpy(mel_filters_ref).float()
    mel_spec = filters @ magnitudes

    # Log scale
    log_spec = torch.clamp(mel_spec, min=1e-10).log10()
    log_spec = torch.maximum(log_spec, log_spec.max() - 8.0)
    log_spec = (log_spec + 4.0) / 4.0

    return log_spec.numpy()


def compute_mel_our_with_centering(audio_np, mel_filters_ref):
    """Our algorithm but WITH center padding (to test if centering is the key difference)."""
    # Pad to 30 seconds first
    if len(audio_np) >= TARGET_LENGTH:
        audio = audio_np[:TARGET_LENGTH].copy()
    else:
        audio = np.zeros(TARGET_LENGTH, dtype=np.float32)
        audio[:len(audio_np)] = audio_np

    # Center padding: add N_FFT//2 zeros on each side
    pad = N_FFT // 2
    audio_padded = np.pad(audio, (pad, pad), mode='constant')

    n_frames = (len(audio_padded) - N_FFT) // HOP_LENGTH + 1
    num_bins = N_FFT // 2 + 1

    # Periodic Hanning window
    window = np.array([0.5 - 0.5 * np.cos(2.0 * np.pi * i / N_FFT) for i in range(N_FFT)], dtype=np.float32)

    magnitudes = np.zeros((n_frames, num_bins), dtype=np.float32)

    for frame in range(n_frames):
        start = frame * HOP_LENGTH
        windowed = audio_padded[start:start + N_FFT] * window
        spectrum = np.fft.fft(windowed, n=N_FFT)
        for k in range(num_bins):
            magnitudes[frame, k] = np.abs(spectrum[k]) ** 2

    # Drop last frame to match reference (3001 -> 3000)
    magnitudes = magnitudes[:-1]

    mel_spec = mel_filters_ref @ magnitudes.T
    mel_spec = np.log10(np.maximum(mel_spec, 1e-10))
    max_val = mel_spec.max()
    mel_spec = np.maximum(mel_spec, max_val - 8.0)
    mel_spec = (mel_spec + 4.0) / 4.0

    return mel_spec


def compare_arrays(name, a, b):
    """Compare two arrays and report statistics."""
    if a.shape != b.shape:
        print(f"  {name}: SHAPE MISMATCH! {a.shape} vs {b.shape}")
        # Trim to common shape for partial comparison
        min_shape = tuple(min(s1, s2) for s1, s2 in zip(a.shape, b.shape))
        a = a[:min_shape[0], :min_shape[1]] if len(min_shape) > 1 else a[:min_shape[0]]
        b = b[:min_shape[0], :min_shape[1]] if len(min_shape) > 1 else b[:min_shape[0]]

    diff = np.abs(a - b)
    max_diff = diff.max()
    mean_diff = diff.mean()
    rel_diff = diff / (np.abs(b) + 1e-10)
    max_rel_diff = rel_diff.max()
    mean_rel_diff = rel_diff.mean()

    # Correlation
    a_flat = a.flatten()
    b_flat = b.flatten()
    if np.std(a_flat) > 0 and np.std(b_flat) > 0:
        corr = np.corrcoef(a_flat, b_flat)[0, 1]
    else:
        corr = 0.0

    match_pct = (diff < 0.01).mean() * 100

    status = "PASS" if max_diff < 0.05 else ("CLOSE" if max_diff < 0.5 else "FAIL")
    print(f"  {name}: {status}")
    print(f"    max_diff={max_diff:.6f}, mean_diff={mean_diff:.6f}")
    print(f"    max_rel_diff={max_rel_diff:.4f}, mean_rel_diff={mean_rel_diff:.4f}")
    print(f"    correlation={corr:.6f}, match_within_0.01={match_pct:.1f}%")
    print(f"    a: min={a.min():.4f}, max={a.max():.4f}, mean={a.mean():.4f}, std={a.std():.4f}")
    print(f"    b: min={b.min():.4f}, max={b.max():.4f}, mean={b.mean():.4f}, std={b.std():.4f}")

    return max_diff, corr


def main():
    print("=" * 70)
    print("WHISPER MEL SPECTROGRAM BENCHMARK")
    print("=" * 70)

    # ---- Test 1: Mel Filterbank Comparison ----
    print("\n--- TEST 1: Mel Filterbank Comparison ---")

    # Load reference filters
    ref_data = np.load(MEL_FILTERS_PATH)
    mel_ref = ref_data['mel_128']
    print(f"Reference mel_128: shape={mel_ref.shape}, dtype={mel_ref.dtype}")

    # Compute our filters
    mel_ours = compute_mel_filterbank_slaney(N_MELS, N_FFT, SAMPLE_RATE)
    print(f"Our mel filters:   shape={mel_ours.shape}, dtype={mel_ours.dtype}")

    filter_diff, filter_corr = compare_arrays("Filterbank", mel_ours, mel_ref)

    if filter_diff > 0.001:
        print("\n  First 5 filter diffs (filter 0, bins 0-20):")
        for k in range(min(20, mel_ref.shape[1])):
            if abs(mel_ours[0, k] - mel_ref[0, k]) > 1e-6:
                print(f"    bin {k}: ours={mel_ours[0, k]:.6f}, ref={mel_ref[0, k]:.6f}, "
                      f"diff={abs(mel_ours[0, k] - mel_ref[0, k]):.6f}")

        # Check filter 64 (middle)
        print("  Filter 64 diffs (bins with values):")
        for k in range(mel_ref.shape[1]):
            if mel_ref[64, k] > 1e-6 or mel_ours[64, k] > 1e-6:
                if abs(mel_ours[64, k] - mel_ref[64, k]) > 1e-6:
                    print(f"    bin {k}: ours={mel_ours[64, k]:.6f}, ref={mel_ref[64, k]:.6f}")

    # ---- Test 2: Load Audio ----
    print("\n--- TEST 2: Load Audio ---")

    # Find a recording with speech
    audio_file = None
    for fname in os.listdir(RECORDINGS_DIR):
        if fname.endswith('.wav') and 'Hello' in fname:
            audio_file = os.path.join(RECORDINGS_DIR, fname)
            break

    if audio_file is None:
        # Just pick the first wav
        for fname in sorted(os.listdir(RECORDINGS_DIR)):
            if fname.endswith('.wav') and 'BLANK' not in fname:
                audio_file = os.path.join(RECORDINGS_DIR, fname)
                break

    if audio_file is None:
        print("ERROR: No recordings found. Generating synthetic test audio.")
        # Generate 3 seconds of speech-like audio (formant frequencies)
        t = np.linspace(0, 3.0, int(3.0 * SAMPLE_RATE), dtype=np.float32)
        audio_samples = (0.3 * np.sin(2 * np.pi * 150 * t) +  # F0
                         0.2 * np.sin(2 * np.pi * 500 * t) +  # F1
                         0.15 * np.sin(2 * np.pi * 1500 * t) + # F2
                         0.1 * np.sin(2 * np.pi * 2500 * t))   # F3
        audio_samples = audio_samples.astype(np.float32)
    else:
        print(f"Loading: {os.path.basename(audio_file)}")
        audio_samples, sr = load_wav_float32(audio_file)
        print(f"  Samples: {len(audio_samples)}, Duration: {len(audio_samples)/sr:.2f}s")
        print(f"  RMS: {np.sqrt(np.mean(audio_samples**2)):.4f}")
        print(f"  Range: [{audio_samples.min():.4f}, {audio_samples.max():.4f}]")

    # ---- Test 3: STFT Comparison ----
    print("\n--- TEST 3: Full Mel Spectrogram Comparison ---")

    # Use reference mel filters for all comparisons
    print("\nA) Our algorithm (no centering) vs Reference (torch.stft, center=True):")
    mel_ours_nopad = compute_mel_our_algorithm(audio_samples, mel_ref)
    mel_reference = compute_mel_reference(audio_samples, mel_ref)
    print(f"  Our shape: {mel_ours_nopad.shape}, Reference shape: {mel_reference.shape}")
    compare_arrays("No-center vs Reference", mel_ours_nopad, mel_reference)

    print("\nB) Our algorithm WITH centering vs Reference:")
    mel_ours_centered = compute_mel_our_with_centering(audio_samples, mel_ref)
    print(f"  Our centered shape: {mel_ours_centered.shape}, Reference shape: {mel_reference.shape}")
    compare_arrays("Centered vs Reference", mel_ours_centered, mel_reference)

    print("\nC) Our algorithm (no centering) + OUR filterbank vs Reference:")
    mel_ours_full = compute_mel_our_algorithm(audio_samples, mel_ours)
    compare_arrays("Our-full vs Reference", mel_ours_full, mel_reference)

    # ---- Test 4: Identify Critical Differences ----
    print("\n--- TEST 4: Critical Differences Analysis ---")

    # Check if window function matters
    window_periodic = np.array([0.5 - 0.5 * np.cos(2.0 * np.pi * i / N_FFT) for i in range(N_FFT)], dtype=np.float32)
    window_torch = torch.hann_window(N_FFT).numpy()
    window_diff = np.abs(window_periodic - window_torch).max()
    print(f"\nWindow: periodic vs torch.hann_window max diff = {window_diff:.8f}")

    # Symmetric window for comparison
    window_symmetric = np.array([0.5 - 0.5 * np.cos(2.0 * np.pi * i / (N_FFT - 1)) for i in range(N_FFT)], dtype=np.float32)
    window_sym_diff = np.abs(window_symmetric - window_torch).max()
    print(f"Window: symmetric vs torch.hann_window max diff = {window_sym_diff:.8f}")

    # Check centering effect on first few frames
    print(f"\nFrame count: no-centering={mel_ours_nopad.shape[1]}, reference={mel_reference.shape[1]}")
    if mel_ours_nopad.shape[1] != mel_reference.shape[1]:
        print(f"  FRAME COUNT MISMATCH: {mel_ours_nopad.shape[1]} vs {mel_reference.shape[1]}")

    # ---- Test 5: Save diagnostics ----
    print("\n--- TEST 5: Save Diagnostic Data ---")

    diag_path = os.path.join(BENCHMARK_DIR, "mel_diagnostics.npz")
    np.savez(diag_path,
             mel_reference=mel_reference,
             mel_ours_nopad=mel_ours_nopad,
             mel_ours_centered=mel_ours_centered,
             mel_filters_ref=mel_ref,
             mel_filters_ours=mel_ours,
             audio_samples_first_1s=audio_samples[:SAMPLE_RATE])
    print(f"Diagnostics saved to {diag_path}")

    # ---- Summary ----
    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)

    if filter_diff < 0.001:
        print("  Mel filterbank: MATCH (< 0.001 max diff)")
    else:
        print(f"  Mel filterbank: MISMATCH (max diff = {filter_diff:.6f})")
        print("  >> FIX: Load reference mel_filters.npz instead of computing")

    if mel_ours_nopad.shape != mel_reference.shape:
        print(f"  Frame count: MISMATCH ({mel_ours_nopad.shape[1]} vs {mel_reference.shape[1]})")
        print("  >> FIX: Add center padding (N_FFT//2 zeros on each side)")

    # Check which approach is closest to reference
    if mel_ours_centered.shape == mel_reference.shape:
        centered_diff = np.abs(mel_ours_centered - mel_reference).mean()
        print(f"  Centered approach mean diff: {centered_diff:.6f}")
        if centered_diff < 0.01:
            print("  >> SOLUTION: Add center padding to Swift implementation")
        else:
            print("  >> Center padding alone is NOT sufficient")

    print()


if __name__ == "__main__":
    main()
