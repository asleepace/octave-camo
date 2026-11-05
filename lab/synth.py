"""Synthetic scenes for E2 round two, all 48 kHz, 60 s, over the same quiet pink-ish room noise.
Each returns (x, truth) where truth is a function t -> frequency of the plane tone, or None."""
import numpy as np

SR = 48_000

def room(seconds=60, seed=0):
    rng = np.random.default_rng(seed); n = int(seconds * SR)
    w = rng.normal(0, 1, n); X = np.fft.rfft(w); f = np.fft.rfftfreq(n, 1 / SR)
    X /= np.sqrt(np.maximum(f, 20) / 20)                           # pink-ish
    x = np.fft.irfft(X, n); return x / x.std() * 0.01

def amp(snr_db):  # tone amplitude for snr_db over a 1 Hz band of the room noise near 1 kHz
    n = room(10, 99); X = np.abs(np.fft.rfft(n)) ** 2 / (len(n) * SR / 2); f = np.fft.rfftfreq(len(n), 1 / SR)
    psd = np.median(X[(f > 900) & (f < 1100)])                    # power per Hz
    return np.sqrt(2 * psd * 10 ** (snr_db / 10))

def fan_path(f0=1234.0, v=141.0, d=2000.0, tc=27.0, c=343.0):
    te = np.linspace(tc - 300, tc + 300, 200001); xx = v * (te - tc); r = np.hypot(d, xx)
    return lambda t: np.interp(t, te + r / c, f0 / (1 + v * xx / (c * r))), lambda t: np.interp(t, te + r / c, d / r)

def tone(freq_of_t, level_of_t, seconds=60):
    t = np.arange(int(seconds * SR)) / SR; f = freq_of_t(t)
    return level_of_t(t) * np.sin(2 * np.pi * np.cumsum(f) / SR)

def fan(snr_db, seed=1):
    p, lvl = fan_path(); x = room(seed=seed) + tone(p, lambda t: amp(snr_db) * lvl(t)); return x, p

def notes(seq, seconds=60, harmonics=(1, 0.5, 0.3, 0.2), vibrato=0.0, glide=0.0, seed=2):
    """Melody: list of (start, dur, hz). vibrato: depth as a fraction at 5.5 Hz; glide: portamento s."""
    t = np.arange(int(seconds * SR)) / SR; x = np.zeros_like(t)
    for i, (s, d, hz) in enumerate(seq):
        k = (t >= s) & (t < s + d); tt = t[k] - s
        prev = seq[i - 1][2] if i and glide else hz
        f = hz + (prev - hz) * np.exp(-tt / glide) if glide else np.full(tt.shape, hz)
        f = f * (1 + vibrato * np.sin(2 * np.pi * 5.5 * tt))
        env = np.minimum(1, tt / 0.03) * np.exp(-tt / (d * 1.5))
        ph = 2 * np.pi * np.cumsum(f) / SR
        for h, a in enumerate(harmonics, 1): x[k] += a * env * np.sin(h * ph)
    return x

def music(seed=3):
    rng = np.random.default_rng(seed); seq = []; s = 0.0
    scale = 440 * 2 ** (np.array([0, 2, 4, 5, 7, 9, 11, 12]) / 12)
    while s < 58:
        d = rng.choice([0.25, 0.5, 0.5, 1.0]); seq.append((s, d, rng.choice(scale) * rng.choice([0.5, 1, 2]))); s += d
    x = notes(seq); return room(seed=seed) + 0.05 * x / np.abs(x).max(), None

def descending_scales(seed=4):
    seq = []; s = 0.0
    while s < 58:
        for k in range(12, -1, -1): seq.append((s, 0.2, 880 * 2 ** (k / 12))); s += 0.2
    x = notes(seq); return room(seed=seed) + 0.05 * x / np.abs(x).max(), None

def singing(seed=5):
    """Held notes with vibrato and portamento (glides between notes), mostly falling phrases."""
    rng = np.random.default_rng(seed); seq = []; s = 0.0
    while s < 58:
        start = rng.uniform(300, 600)
        for k in range(5): d = rng.uniform(0.6, 1.6); seq.append((s, d, start * 2 ** (-k * 2 / 12))); s += d
    x = notes(seq, vibrato=0.012, glide=0.12, harmonics=(1, 0.6, 0.4, 0.3, 0.2, 0.1))
    return room(seed=seed) + 0.05 * x / np.abs(x).max(), None

def siren(seed=6):
    """A wail: 650 → 1500 → 650 Hz every 8 s (rise 4 s, fall 4 s), with harmonics."""
    t = np.arange(60 * SR) / SR; u = (t % 8) / 8; f = 650 + 850 * np.where(u < 0.5, 2 * u, 2 - 2 * u)
    ph = 2 * np.pi * np.cumsum(f) / SR; x = sum(a * np.sin(h * ph) for h, a in enumerate((1, 0.4, 0.2), 1))
    return room(seed=seed) + 0.02 * x, None

def speech(seed=7):
    """Syllables 0.15–0.35 s, pitch 100–220 Hz with falling intonation per phrase, 12 harmonics."""
    rng = np.random.default_rng(seed); t = np.arange(60 * SR) / SR; x = np.zeros_like(t); s = 0.0
    while s < 58:
        base = rng.uniform(110, 200); n = rng.integers(4, 9)
        for k in range(n):
            d = rng.uniform(0.15, 0.35); kk = (t >= s) & (t < s + d); tt = t[kk] - s
            f = base * (1 - 0.15 * k / n) * (1 - 0.1 * tt / d)
            env = np.sin(np.pi * tt / d); ph = 2 * np.pi * np.cumsum(f) / SR
            x[kk] += env * sum((0.8 ** h) * np.sin(h * ph) for h in range(1, 13)); s += d + rng.uniform(0.03, 0.1)
        s += rng.uniform(0.3, 0.8)
    return room(seed=seed) + 0.05 * x / np.abs(x).max(), None

def bangs(seed=8):
    """Construction: broadband hits 3–8 per 10 s, plus noise."""
    rng = np.random.default_rng(seed); x = room(seed=seed)
    for s in rng.uniform(0, 59, 30):
        i = int(s * SR); L = int(0.08 * SR); x[i:i + L] += rng.normal(0, 0.3, L) * np.exp(-np.arange(L) / (0.02 * SR))
    return x, None

SCENES = {"room noise": lambda: (room(seed=11), None), "music": music, "descending scales": descending_scales,
          "singing": singing, "siren": siren, "speech": speech, "construction bangs": bangs}
