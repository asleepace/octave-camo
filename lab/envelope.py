"""The loudness-envelope attacker: does a recording's slow rise and fall in level follow a known
flight's predicted level (docs/EXPERIMENTS.md, "the envelope attacker")?

A jet's roar is broadband: no tone to follow, so the tone attackers can't see it, but its level
still swells and fades with distance. This attacker takes each band's quiet level (a low
percentile within each second, so taps, clicks and speech don't count), trims the ends (a
recording's first and last seconds carry its own start and stop), and correlates it with the
level the flight's track predicts there: spherical spreading (−20 log r) and air absorption at the
band's centre, heard with the sound's travel time. The best correlation over bands and a few
seconds of timing slack, against the same search with the prediction moved 20–60 s (wrong times),
gives z, as the tone attacker does. A recording whose background drifts (a TV, wind) scores against
every shifted prediction alike, which the null absorbs.
"""
from __future__ import annotations

import numpy as np
from scipy.signal import stft

from .detect import NULL_SHIFTS
from .passes import absorption_db_per_km

BANDS = ((40.0, 150.0), (150.0, 500.0), (500.0, 1500.0), (40.0, 1500.0))


def band_levels(x: np.ndarray, sr: int, bands=BANDS, step: float = 0.5, window: float = 1.0, pct: float = 20.0, trim: float = 2.5):
    """(times, {band: level dB}) every `step` s: the `pct`th percentile of the band's short-time
    level within `window` s, `trim` s cut from each end."""
    n = 4096 if sr >= 32_000 else 2048
    f, t, Z = stft(x, sr, nperseg=n, noverlap=n - n // 4)
    P = np.abs(Z) ** 2
    dur = len(x) / sr
    centres = np.arange(trim + window / 2, dur - trim - window / 2 + 1e-9, step)
    out = {}
    for lo, hi in bands:
        lv = 10 * np.log10(P[(f >= lo) & (f < hi)].mean(0) + 1e-20)
        out[(lo, hi)] = np.array([np.percentile(lv[np.abs(t - c) <= window / 2], pct) for c in centres])
    return centres, out


def predicted_level(te: np.ndarray, q: np.ndarray, c: float, band: tuple[float, float]):
    """(heard times, level dB up to a constant) for a track: spreading and absorption at the band's
    geometric centre."""
    r = np.linalg.norm(q, axis=1)
    fc = float(np.sqrt(band[0] * band[1]))
    return te + r / c, -20 * np.log10(r) - absorption_db_per_km(fc) * r / 1_000


def _corr(a: np.ndarray, b: np.ndarray) -> float:
    a, b = a - a.mean(), b - b.mean()
    d = np.sqrt((a * a).sum() * (b * b).sum())
    return float((a * b).sum() / d) if d > 0 else float("nan")


def envelope_z(times, levels: dict, track, c: float, offsets=np.arange(-6, 6.01, 0.5), shifts=NULL_SHIFTS, min_frames: int = 20,
               min_swing_db: float = 1.5, min_nulls: int = 20, min_sd: float = 0.1):
    """(z, best r, band, offset) for one flight: the best correlation of a band's level with the
    predicted level over timing offsets, against the same with the prediction moved by `shifts`.
    Only predictions that swing by `min_swing_db` over the frames count, real or wrong-time: a far
    aircraft's nearly flat prediction correlates with any drift, and a z from the few wrong times
    that do swing is noise (a first version scored 9.7 on an aircraft 14 km away). The wrong-time
    spread is floored at `min_sd`: a correlation over a few dozen effectively independent seconds
    varies by about that much on its own, and a far aircraft's predictions at different times can
    be near copies of each other (spread 0.00: z 3 from r = 0)."""
    te, q, _ = track
    curves = {band: predicted_level(te, q, c, band) for band in levels}

    def best(shift):
        top = (-np.inf, None, np.nan)
        for band, lv in levels.items():
            heard, pred = curves[band]
            for o in offsets:
                p = np.interp(times - shift - o, heard, pred, left=np.nan, right=np.nan)
                ok = np.isfinite(p)
                if ok.sum() < min_frames or np.ptp(p[ok]) < min_swing_db:     # the prediction must actually change
                    continue
                r = _corr(lv[ok], p[ok])
                if np.isfinite(r) and r > top[0]:
                    top = (r, band, float(o))
        return top

    r0, band, off = best(0.0)
    nulls = np.array([best(s)[0] for s in shifts])
    nulls = nulls[np.isfinite(nulls)]
    if not np.isfinite(r0) or len(nulls) < min_nulls:
        return float("nan"), float("nan"), band, off
    return float((r0 - nulls.mean()) / max(nulls.std(), min_sd)), r0, band, off
