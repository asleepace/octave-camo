"""Quiet ambient clip with a distant aircraft buried in the background.

    python3 synth_background.py out.wav [--tone-db -40] [--seed 1] [--speech 45]

90 s of pink noise and random thumps (doors, steps), plus a distant jet: 95 Hz engine tone with
2 harmonics, closest approach 5831 m (5 km offset, 3 km up) at t = 45 s, 150 m/s. --tone-db is
the fundamental's level relative to the noise RMS; around -30 dB the blind tracker stops seeing it.
"""
import argparse
import numpy as np
from scipy.io import wavfile
import proto

GEOMETRY = dict(f0=95.0, v=150.0, d=float(np.hypot(5000, 3000)), t0=45.0)


def syllables(n, sr, rng, until_s, level=0.03):
    """Speech-like syllables (100-220 Hz pitch with bends, 24 harmonics) until `until_s`."""
    sp = np.zeros(n); t = 0.5
    while t < until_s:
        L = rng.uniform(0.15, 0.4); m = int(L * sr); i0 = int(t * sr)
        p = rng.uniform(100, 220) * (1 + 0.1 * np.linspace(-1, 1, m) * rng.uniform(-1, 1))
        ph = 2 * np.pi * np.cumsum(p) / sr; env = np.sin(np.pi * np.arange(m) / m) ** 2
        sp[i0:i0 + m] += level * env * sum((0.6 / k) * np.sin(k * ph) for k in range(1, 25))
        t += L + rng.uniform(0.05, 0.6)
    return sp


def make(tone_db=-40.0, seed=1, sr=48000, dur=90.0, speech_until=0.0):
    rng = np.random.default_rng(seed)
    n = int(sr * dur); t = np.arange(n) / sr
    w = rng.standard_normal(n); W = np.fft.rfft(w); fr = np.fft.rfftfreq(n, 1 / sr)
    W[1:] /= np.sqrt(fr[1:]); W[0] = 0
    noise = np.fft.irfft(W, n); noise *= 0.01 / noise.std()
    x = noise.copy()
    for _ in range(25):                                   # thumps: short low-frequency bursts
        i0 = int(rng.uniform(0, dur - 0.3) * sr); m = int(0.15 * sr)
        x[i0:i0 + m] += 0.05 * rng.uniform(0.3, 1) * np.sin(2 * np.pi * rng.uniform(40, 120) * t[:m]) * np.exp(-t[:m] / 0.04)
    f, r = proto.doppler(t, GEOMETRY['f0'], GEOMETRY['v'], GEOMETRY['t0'], GEOMETRY['d'])
    amp = 0.01 * 10 ** (tone_db / 20) * np.sqrt(2) * (GEOMETRY['d'] / r)
    for k, a in [(1, 1.0), (2, 0.5), (3, 0.3)]:
        x += a * amp * np.sin(2 * np.pi * np.cumsum(k * f) / sr)
    speech = syllables(n, sr, rng, speech_until) if speech_until > 0 else np.zeros(n)
    x += speech
    g = 1 / (np.abs(x).max() * 1.1)
    return sr, np.stack([x * g, x * g], 1).astype(np.float32), (speech * g).astype(np.float32)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(); ap.add_argument('out'); ap.add_argument('--tone-db', type=float, default=-40)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--speech', type=float, default=0, help='add speech-like syllables for the first N seconds')
    a = ap.parse_args()
    sr, x, speech = make(a.tone_db, a.seed, speech_until=a.speech); wavfile.write(a.out, sr, x)
    if a.speech > 0: wavfile.write(a.out.replace('.wav', '.speech.wav'), sr, speech)
