"""Synthetic aircraft passes for the curve benchmark (docs/EXPERIMENTS.md, "the curve benchmark").

A pass is drawn at random and rendered into a background at a chosen strength. What it models,
beyond the straight-line Doppler curve the detectors are built around:

- **Geometry:** speed 60–240 m/s, altitude 300–3,500 m, ground offset 0–3 km (closest slant
  0.5–6 km), closest approach heard somewhere in the clip; sound travel time included.
- **An engine, not a tone:** a fundamental with up to four harmonics, and often a second,
  unrelated family (fan and shaft), each with its own level.
- **Propagation:** spherical spreading, air absorption rising with frequency, a directivity lobe
  (louder ahead or behind), and the ground reflection: the direct sound and its echo off the ground
  interfere, and as the elevation changes the interference sweeps through the tones (Lloyd's mirror).
- **What makes real curves messy:** the engine's speed wanders (a slow random walk in frequency,
  0.05–0.3 %), turbulence scintillates the level (2–5 dB over about a second), and indoors the
  sound comes through a window (high frequencies rolled off).

Strength is the strongest tone's level at closest approach over the background's noise at that
frequency, in dB per Hz: the convention of the Swift detection scenes and the lab's E2.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass, field

import numpy as np

C = 343.0
BAND = (80.0, 4000.0)


@dataclass
class Pass:
    speed: float
    altitude: float
    offset: float               # ground distance at closest approach, m
    t_close: float              # closest approach as heard, s into the clip
    tones: list = field(default_factory=list)     # [(rest Hz, relative dB, directivity a)]
    listener_height: float = 3.0
    reflection: float = 0.6
    wander: float = 0.001       # engine-speed wander, fraction (1 sd)
    scintillation_db: float = 3.0
    indoor: bool = False

    @property
    def distance(self) -> float:
        return float(np.hypot(self.altitude, self.offset))

    def to_dict(self) -> dict:
        d = asdict(self)
        d["distance"] = self.distance
        return d


def draw(rng: np.random.Generator, seconds: float) -> Pass:
    """A random pass whose closest approach is heard within the clip's middle 70 %."""
    while True:
        p = Pass(speed=rng.uniform(60, 240), altitude=rng.uniform(300, 3_500), offset=rng.uniform(0, 3_000),
                 t_close=rng.uniform(0.15, 0.85) * seconds, listener_height=rng.uniform(1, 10),
                 reflection=rng.uniform(0.3, 0.9), wander=10 ** rng.uniform(np.log10(0.0005), np.log10(0.003)),
                 scintillation_db=rng.uniform(2, 5), indoor=bool(rng.random() < 0.5))
        if 500 <= p.distance <= 6_000:
            break
    # Keep every tone inside the band across the whole Doppler swing (factor 1/(1 ± v/c)).
    lo, hi = BAND[0] * (1 + p.speed / C) * 1.05, BAND[1] * (1 - p.speed / C) / 1.05
    families = [(rng.uniform(np.log(lo), np.log(min(hi, 1_500))), 1 + int(rng.integers(0, 5)))]
    if rng.random() < 0.5:
        families.append((rng.uniform(np.log(max(lo, 300)), np.log(hi)), 1 + int(rng.integers(0, 3))))
    tones = []
    for fi, (log_f, n) in enumerate(families):
        base_db = 0.0 if fi == 0 else rng.uniform(-8, 0)
        a = rng.uniform(-0.6, 0.6)
        for h in range(1, n + 1):
            f = float(np.exp(log_f) * h)
            if f > hi:
                break
            tones.append((f, base_db - (0 if h == 1 else rng.uniform(3, 15)), a))
    p.tones = tones
    return p


def geometry(p: Pass, t: np.ndarray):
    """At receive times t: (Doppler factor, slant range, cos of the angle between the flight
    direction and the line to the listener, elevation sine)."""
    te0 = p.t_close - p.distance / C
    tau = t - p.distance / C
    for _ in range(10):
        x = p.speed * (tau - te0)
        r = np.hypot(p.distance, x)
        tau = tau - (tau + r / C - t) / (1 + p.speed * x / (C * r))
    x = p.speed * (tau - te0)
    r = np.hypot(p.distance, x)
    factor = 1 / (1 + p.speed * x / (C * r))
    cos_theta = -x / r                       # +1 straight ahead (approaching), −1 behind
    return factor, r, cos_theta, p.altitude / r


def absorption_db_per_km(f):
    """Air absorption, rough fit to ISO 9613-1 at 15 °C and 70 % humidity: ~2 dB/km at 500 Hz,
    ~5 at 1 kHz, ~11 at 2 kHz, ~27 at 4 kHz."""
    return 4.6 * (np.asarray(f) / 1_000) ** 1.3


def smooth_noise(rng: np.random.Generator, n: int, corr: int) -> np.ndarray:
    """Unit-variance Gaussian noise smoothed over `corr` samples (a slow random process)."""
    from scipy.ndimage import gaussian_filter1d
    w = gaussian_filter1d(rng.normal(0, 1, n + 4 * corr), corr)[2 * corr: 2 * corr + n]
    return w / (w.std() + 1e-12)


def render(p: Pass, seconds: float, sr: int, rng: np.random.Generator):
    """The pass alone, with the strongest tone at amplitude 1 at closest approach (scaled by the
    caller for strength), and its ground truth: (audio, [tone curves: (t grid, Hz along it,
    relative level dB)])."""
    n = int(seconds * sr)
    grid = np.arange(0, seconds + 0.01, 0.01)                      # 100 Hz control rate
    factor, r, cos_t, elev = geometry(p, grid)
    wander = np.exp(p.wander * smooth_noise(rng, len(grid), 150))  # engine speed, ~1.5 s correlation
    scint = 10 ** (p.scintillation_db * smooth_noise(rng, len(grid), 50) / 20)
    t = np.arange(n) / sr
    out = np.zeros(n)
    truth = []
    # Reference: the strongest tone's level at closest approach, so the caller can set strength.
    levels = []
    for f0, rel_db, a in p.tones:
        f_t = f0 * factor * wander
        spread = p.distance / r
        absorb = 10 ** (-absorption_db_per_km(f_t) * (r - p.distance) / 1_000 / 20)
        direct = 1 + a * cos_t
        # Ground reflection: path difference ≈ 2·h·sin(elevation); the echo's phase at this tone.
        delta = 2 * p.listener_height * elev
        mirror = np.abs(1 + p.reflection * np.exp(-2j * np.pi * f_t * delta / C)) / (1 + p.reflection)
        window = 1 / np.sqrt(1 + (f_t / 1_000) ** 2) if p.indoor else 1.0     # −6 dB/octave above 1 kHz
        amp = 10 ** (rel_db / 20) * spread * absorb * direct * mirror * window * scint
        i0 = int(np.argmin(np.abs(grid - p.t_close)))
        levels.append(amp[i0])
        truth.append((grid, f_t, 20 * np.log10(amp + 1e-12)))
        phase = 2 * np.pi * np.cumsum(np.interp(t, grid, f_t)) / sr + rng.uniform(0, 2 * np.pi)
        out += np.interp(t, grid, amp) * np.sin(phase)
    ref = max(levels)
    truth = [(g, f, lvl - 20 * np.log10(ref)) for g, f, lvl in truth]
    return out / ref, truth


def noise_psd(x: np.ndarray, sr: int, f: float, t: float, span_s: float = 10.0) -> float:
    """The background's one-sided power per Hz near frequency f around time t (median over
    ±10 % of f, over a span around t): what the strength is measured against."""
    from scipy.signal import welch
    i0, i1 = max(0, int((t - span_s / 2) * sr)), min(len(x), int((t + span_s / 2) * sr))
    fr, P = welch(x[i0:i1], sr, nperseg=4_096)
    k = (fr > 0.9 * f) & (fr < 1.1 * f)
    return float(np.median(P[k]))


def mix(background: np.ndarray, sr: int, p: Pass, snr_db_hz: float, rng: np.random.Generator):
    """Background plus the pass at `snr_db_hz` (strongest tone at closest approach). Returns
    (audio, truth)."""
    seconds = len(background) / sr
    tone, truth = render(p, seconds, sr, rng)
    # The strongest tone at closest approach, and the noise there.
    g0 = truth[0][0]
    i0 = int(np.argmin(np.abs(g0 - p.t_close)))
    k = int(np.argmax([lvl[i0] for _, _, lvl in truth]))
    f_close = truth[k][1][i0]
    psd = noise_psd(background, sr, f_close, p.t_close)
    a = np.sqrt(2 * psd * 10 ** (snr_db_hz / 10))
    return background + a * tone, truth
