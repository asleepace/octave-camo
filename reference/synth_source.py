"""Generic moving-source clip: one sound source on a straight track past the microphone.

    python3 synth_source.py out.wav --f0 600 --speed 25 --distance 120 --t0 30 \\
        [--duration 60] [--tone-db -10] [--harmonics 2] [--rumble-db -6] [--seed 1]

Covers trains (traction-inverter whine, 300 Hz–2 kHz, close, slow), buses, ships (low, slow,
far) and aircraft. --tone-db is the fundamental's level relative to the background noise RMS.
--rumble-db adds the source's broadband rumble (low-passed noise that swells with 1/r), which
is what an envelope attack would use.
"""
import argparse
import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, sosfilt
import proto


def make(f0, speed, distance, t0, duration=60.0, tone_db=-10.0, harmonics=2, rumble_db=-60.0, seed=1, sr=48000):
    rng = np.random.default_rng(seed)
    n = int(sr * duration); t = np.arange(n) / sr
    w = rng.standard_normal(n); W = np.fft.rfft(w); fr = np.fft.rfftfreq(n, 1 / sr)
    W[1:] /= np.sqrt(fr[1:]); W[0] = 0
    x = np.fft.irfft(W, n); x *= 0.01 / x.std()                     # pink ambience, 0.01 RMS
    f, r = proto.doppler(t, f0, speed, t0, distance)
    gain = distance / r                                              # 1/r spreading
    amp = 0.01 * 10 ** (tone_db / 20) * np.sqrt(2)
    for k in range(1, harmonics + 1):
        x += (amp / k) * gain * np.sin(2 * np.pi * np.cumsum(k * f) / sr)
    if rumble_db > -59:
        rumble = sosfilt(butter(4, 200, fs=sr, output='sos'), rng.standard_normal(n))
        x += 0.01 * 10 ** (rumble_db / 20) * gain * rumble / rumble.std()
    x /= np.abs(x).max() * 1.1
    return sr, np.stack([x, x], 1).astype(np.float32)


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    for name, default in [('f0', 600.0), ('speed', 25.0), ('distance', 120.0), ('t0', 30.0), ('duration', 60.0),
                          ('tone-db', -10.0), ('rumble-db', -60.0)]:
        ap.add_argument(f'--{name}', type=float, default=default)
    ap.add_argument('--harmonics', type=int, default=2)
    ap.add_argument('--seed', type=int, default=1)
    a = ap.parse_args()
    sr, x = make(a.f0, a.speed, a.distance, a.t0, a.duration, a.tone_db, a.harmonics, a.rumble_db, a.seed)
    wavfile.write(a.out, sr, x)
