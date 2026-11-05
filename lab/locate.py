"""The place-searching attacker: where was this recorded?

After the method in [YT-UytYrhYLOKI] (SOURCES.md): for every candidate point on a grid, predict the
Doppler curve each logged aircraft would produce there (its real track, sound travel time
included), score the audio's whitened spectrogram along each curve with the engine's rest
frequency free, and add the aircraft up (the events are scored together on one timeline). The
recording's time is given exactly, which makes this attacker stronger than one who only knows when
the clip was posted.

Each aircraft's score at a point is a z against the same predicted curve moved to wrong times
(±24–40 s) over the same frames: a far point predicts an almost flat curve, which matches any steady sound equally well
at any time, so only curves whose timing fits score high. Aircraft beyond 10 km of a point count 0.
Not yet modelled: silence (a point that predicts a loud pass the audio doesn't have is only not
rewarded, not penalised).

Privacy: candidate points are offsets from the true position and only distances, ranks and areas
are printed or saved, never a position.
"""
from __future__ import annotations

import numpy as np

from . import corpus, detect

P = detect.Params(band=(80.0, 4000.0), broadband_aware=True)
# Rest frequencies searched: 100 Hz–3.5 kHz in 0.2 % steps (fine enough for a Doppler factor).
F0S = np.exp(np.arange(np.log(100.0), np.log(3500.0), 0.002))
HALF_WINDOW_S = 25.0          # scored around each aircraft's predicted closest approach
FRAME_STRIDE = 2              # every other spectrogram frame
TOL_BINS = 2                  # best of ±2 bins (published positions are coarse)
NULL_SHIFTS_S = (-40.0, -32.0, -24.0, 24.0, 32.0, 40.0)   # the same curve at wrong times
MAX_RANGE_KM = 10.0           # a point farther than this from an aircraft doesn't hear it


class Scene:
    """One audio's spectrogram, prepared for scoring curves."""

    def __init__(self, x: np.ndarray, sr: int, name: str):
        from .__main__ import whitened
        self.f, self.t, L = whitened(f"{name}:locate", x, sr, P)
        A = L - L.mean()
        Am = A.copy()
        for o in range(1, TOL_BINS + 1):
            Am[:-o] = np.maximum(Am[:-o], A[o:])
            Am[o:] = np.maximum(Am[o:], A[:-o])
        self.A = Am.astype(np.float32)
        self.df = self.f[1] - self.f[0]

    def scores(self, heard: np.ndarray, factor: np.ndarray, t_close: float) -> tuple[float, float, float]:
        """(score, null mean, null spread): the curve's score near its closest approach, and the
        same curve moved to wrong times over the same frames. A far point predicts an almost flat
        curve, which matches a steady sound as well at any time, so only timing that fits stands
        out from its null."""
        t = self.t
        j = np.flatnonzero((t >= t_close - HALF_WINDOW_S) & (t <= t_close + HALF_WINDOW_S))[::FRAME_STRIDE]
        if len(j) < 40:
            return np.nan, np.nan, np.nan
        s0 = self._best(j, np.interp(t[j], heard, factor, left=np.nan, right=np.nan))
        nulls = np.array([self._best(j, np.interp(t[j] - d, heard, factor, left=np.nan, right=np.nan)) for d in NULL_SHIFTS_S])
        nulls = nulls[np.isfinite(nulls)]
        if not np.isfinite(s0) or len(nulls) < 3:
            return np.nan, np.nan, np.nan
        return s0, float(nulls.mean()), float(nulls.std())

    def _best(self, j: np.ndarray, fac: np.ndarray) -> float:
        """Best mean excess along f0·fac over all rest frequencies (frames where fac is known)."""
        ok = np.isfinite(fac)
        if ok.sum() < 40:
            return np.nan
        j, fac = j[ok], fac[ok]
        K = np.rint((F0S[:, None] * fac[None, :] - self.f[0]) / self.df).astype(np.int32)
        inside = (K.min(1) >= 0) & (K.max(1) < len(self.f))
        if not inside.any():
            return np.nan
        return float(self.A[K[inside], j[None, :]].mean(1).max())


def curves(geo: dict, p: np.ndarray):
    """For a candidate point p (metres east, north; same height), each aircraft's heard time,
    Doppler factor and predicted closest-approach time in the audio, and its closest distance."""
    c = geo["speed_of_sound"]
    out = {}
    for h, (te, q, v) in geo["tracks"].items():
        d = q - np.array([p[0], p[1], 0.0])
        r = np.linalg.norm(d, axis=1)
        vr = (d * v).sum(1) / r
        heard = te + r / c
        i = int(np.argmin(r))
        out[h] = (heard, 1 / (1 + vr / c), float(heard[i]), float(r[i]))
    return out


def audible(geo: dict, extent_m: float, max_km: float = 12.0) -> list[str]:
    """Aircraft that pass within `max_km` of some point of the search area while the audio runs."""
    dur, keep = geo["duration_s"], []
    for h, (te, q, v) in geo["tracks"].items():
        heard = te + np.linalg.norm(q, axis=1) / geo["speed_of_sound"]
        inside = (heard >= -HALF_WINDOW_S) & (heard <= dur + HALF_WINDOW_S)
        if not inside.any():
            continue
        horizontal = np.maximum(0, np.abs(q[inside, :2]) - extent_m)     # distance to the area's box
        if np.min(np.hypot(np.hypot(*horizontal.T), q[inside, 2])) <= max_km * 1000:
            keep.append(h)
    return keep


def search(scene: Scene, geo: dict, hexes: list[str], points: np.ndarray) -> np.ndarray:
    """(score, null mean, null spread), points × aircraft × 3 (NaN: outside the audio's time or
    out of earshot)."""
    dur = geo["duration_s"]
    S = np.full((len(points), len(hexes), 3), np.nan)
    for i, p in enumerate(points):
        cv = curves(geo, p)
        for k, h in enumerate(hexes):
            heard, fac, tc, rmin = cv[h]
            if -HALF_WINDOW_S < tc < dur + HALF_WINDOW_S and rmin <= MAX_RANGE_KM * 1000:
                S[i, k] = scene.scores(heard, fac, tc)
    return S


def zscores(S: np.ndarray, floor: np.ndarray | None = None) -> tuple[np.ndarray, np.ndarray]:
    """Per point and aircraft, z = (score − null mean) / null spread, the spread floored at the
    aircraft's median spread over the grid (six nulls make a noisy spread). Returns (z, floor)."""
    if floor is None:
        floor = np.array([np.nanmedian(S[:, k, 2]) if np.isfinite(S[:, k, 2]).any() else 1.0 for k in range(S.shape[1])])
    Z = (S[:, :, 0] - S[:, :, 1]) / np.maximum(S[:, :, 2], floor[None, :])
    return Z, floor


def combine(Z: np.ndarray) -> np.ndarray:
    """All aircraft on one timeline: their z summed (a point that doesn't hear one gets 0 for it)."""
    return np.nan_to_num(Z, nan=0.0).sum(1)


def grid(extent_m: float, step_m: float, center=(0.0, 0.0)) -> np.ndarray:
    a = np.arange(-extent_m, extent_m + step_m / 2, step_m)
    X, Y = np.meshgrid(a + center[0], a + center[1])
    return np.stack([X.ravel(), Y.ravel()], 1)


def locate(sid: str, audios: list[tuple[str, np.ndarray]], sr: int, extent_m: float = 8_000,
           coarse_m: float = 500, fine_m: float = 100, fine_extent_m: float = 1_000) -> list[dict]:
    """Search a coarse grid around the true position, then a fine one around the coarse best and
    around the truth (so the truth is always scored on the fine grid's terms). Summaries only."""
    geo = corpus.geometry(sid)
    hexes = audible(geo, extent_m)
    coarse = grid(extent_m, coarse_m)
    results = []
    for name, x in audios:
        scene = Scene(x, sr, f"{sid}:{name}")
        S = search(scene, geo, hexes, coarse)
        Zc, floor = zscores(S)
        total = combine(Zc)
        truth_i = int(np.argmin(np.hypot(*coarse.T)))
        best_i = int(np.nanargmax(total))
        # Fine grids around the best coarse point and around the truth.
        fine = np.unique(np.concatenate([grid(fine_extent_m, fine_m, coarse[best_i]), grid(fine_extent_m, fine_m)]), axis=0)
        Zf = combine(zscores(search(scene, geo, hexes, fine), floor)[0])
        fb = int(np.nanargmax(Zf))
        ft = int(np.argmin(np.hypot(*fine.T)))
        rank = int((total > total[truth_i]).sum()) + 1
        within = lambda d: float((total >= total[best_i] - d).sum() * (coarse_m / 1000) ** 2)
        per_aircraft = {h: round(float(Zc[truth_i, k]), 1) for k, h in enumerate(hexes) if np.isfinite(Zc[truth_i, k])}
        results.append({
            "name": name, "aircraft": len(hexes), "points": len(coarse),
            "truth_rank": rank, "truth_percentile": round(100 * (1 - (rank - 1) / len(coarse)), 2),
            "best_error_m": round(float(np.hypot(*coarse[best_i]))), "fine_best_error_m": round(float(np.hypot(*fine[fb]))),
            "best_score": round(float(total[best_i]), 1), "truth_score": round(float(total[truth_i]), 1),
            "fine_truth_score": round(float(Zf[ft]), 1), "fine_best_score": round(float(Zf[fb]), 1),
            "area_within_3_km2": round(within(3.0), 2), "area_within_6_km2": round(within(6.0), 2),
            "truth_z_by_aircraft": per_aircraft,
        })
    return results
