"""The loudness-envelope attacker: does a recording's slow rise and fall in level follow a known
flight's predicted level (docs/EXPERIMENTS.md, "the envelope attacker")?

A jet's roar is broadband: no tone to follow, so the tone attackers can't see it, but its level
still swells and fades with distance. This attacker takes each band's quiet level (a low
percentile within each second, so taps, clicks and speech don't count), trims the ends (a
recording's first and last seconds carry its own start and stop), and fits it with the level the
flight's track predicts there: spherical spreading (−20 log r) and air absorption at the band's
centre, heard with the sound's travel time, added as power to a steady background. The plane's
level and the background's are free; the shape and its size in dB are not (a plane twice as far is
6 dB quieter). The score is the fraction of the level's variance that fit explains (R²); its best
over bands and a few seconds of timing slack, against the same search with the prediction moved
20–60 s (wrong times), gives z, as the tone attacker does.

Why a fit and not a correlation (the first version): a flyby's level changes slowly, so the same
prediction 20 s off still correlates well, and a perfect match scored only z ≈ 3.4 (r = 1.00)
against such wrong times. A correlation also accepts any size of change, so a 1 dB drift matches a
predicted 6 dB fade. Holding the size to the physics, the same synthetic pass scores z 7–13.
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
        sel = (f >= lo) & (f < hi)
        if not sel.any() or hi > sr / 2:          # a band past Nyquist would be empty or partial
            continue
        lv = 10 * np.log10(P[sel].mean(0) + 1e-20)
        out[(lo, hi)] = np.array([np.percentile(lv[np.abs(t - c) <= window / 2], pct) for c in centres])
    return centres, out


def predicted_level(te: np.ndarray, q: np.ndarray, c: float, band: tuple[float, float]):
    """(heard times, level dB up to a constant) for a track: spreading and absorption at the band's
    geometric centre. Heard times strictly increase (np.interp needs it): a subsonic aircraft's
    always do, so a sample that would go back in time is a position glitch and is dropped."""
    r = np.maximum(np.linalg.norm(q, axis=1), 1.0)
    fc = float(np.sqrt(band[0] * band[1]))
    heard = te + r / c
    keep = np.concatenate([[True], heard[1:] > np.maximum.accumulate(heard)[:-1]])
    return heard[keep], (-20 * np.log10(r) - absorption_db_per_km(fc) * r / 1_000)[keep]


def fit_r2(level: np.ndarray, pred: np.ndarray, step: float = 0.5) -> float:
    """R² of level ≈ 10 log10(10^(b/10) + 10^((pred + k)/10)), a steady background b and the plane
    at pred + k, against a constant: b and k searched (grids relative to the levels, so a gain on
    the audio changes nothing), the shape and its size in dB fixed. 0 when the plane explains
    nothing (k far below the background)."""
    sse0 = float(((level - level.mean()) ** 2).sum())
    if not sse0 > 0:
        return float("nan")
    bs = np.unique(np.r_[np.linspace(level.min() - 30, level.max(), 34), level.mean()])
    ks = np.arange(level.min() - pred.max() - 20, level.max() - pred.min() + 3, step)
    plane = 10 ** ((pred[None, :] + ks[:, None]) / 10)
    best = 0.0
    for b in bs:
        model = 10 * np.log10(10 ** (b / 10) + plane)
        best = max(best, 1 - float(((model - level[None, :]) ** 2).sum(1).min()) / sse0)
    return best


def envelope_z(times, levels: dict, track, c: float, offsets=np.arange(-6, 6.01, 0.5), shifts=NULL_SHIFTS, min_frames: int = 20,
               min_swing_db: float = 1.5, min_nulls: int = 20, min_sd: float = 0.05):
    """(z, best R², band, offset) for one flight: the best fit of a band's level by the predicted
    level over timing offsets, against the same with the prediction moved by `shifts`. Only
    predictions that swing by `min_swing_db` over the frames count, real or wrong-time: a far
    aircraft's nearly flat prediction fits any drift, and a z from the few wrong times that do
    swing is noise (the first version scored 9.7 on an aircraft 14 km away). The wrong-time spread
    is floored at `min_sd`: a far aircraft's predictions at different times can be near copies of
    each other (spread 0.00 gave z 3 from nothing)."""
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
                r = fit_r2(lv[ok], p[ok])
                if np.isfinite(r) and r > top[0]:
                    top = (r, band, float(o))
        return top

    r0, band, off = best(0.0)
    nulls = np.array([best(s)[0] for s in shifts])
    nulls = nulls[np.isfinite(nulls)]
    if not np.isfinite(r0) or len(nulls) < min_nulls:
        return float("nan"), float("nan"), band, off
    return float((r0 - nulls.mean()) / max(nulls.std(), min_sd)), r0, band, off
