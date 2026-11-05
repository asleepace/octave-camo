"""Detectors for EXPERIMENTS.md, as composable pieces: whitening, the path search (vectorised over
all windows at once), the flyby shape test, and the known-path attacker."""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
from scipy.ndimage import median_filter
from scipy.optimize import least_squares
from scipy.signal import stft


@dataclass(frozen=True)
class Params:
    band: tuple[float, float] = (600.0, 2500.0)
    fft_s: float = 0.17              # window length
    ref_s: float = 15.0              # running-median reference span (0 = whole-clip median)
    broadband_aware: bool = True     # subtract each frame's median excess
    clip: tuple[float, float] = (-3.0, 12.0)
    win_s: float = 10.0              # path search window
    step_s: float = 2.5
    slopes: tuple[int, ...] = (0, 1, 2)   # bins per frame, downward (falling pitch)
    penalty: float = 2.0             # per slope change
    min_drop: float = 0.02           # fraction of the start frequency over a window
    falling: bool = True             # False: any direction (slopes mirrored)


def whiten(x: np.ndarray, sr: int, p: Params):
    """(frequencies, times, clipped excess in dB) over the band."""
    n = int(2 ** round(np.log2(p.fft_s * sr)))
    f, t, Z = stft(x, sr, nperseg=n, noverlap=n - n // 4)
    k = (f >= p.band[0]) & (f <= p.band[1])
    P = np.abs(Z[k]) ** 2
    dt = t[1] - t[0]
    if p.ref_s > 0:
        ref = median_filter(P, size=(1, int(round(p.ref_s / dt)) | 1), mode="nearest")
    else:
        ref = np.median(P, 1, keepdims=True)
    L = 10 * np.log10(P / (ref + 1e-30) + 1e-12)
    if p.broadband_aware:
        L = L - np.median(L, 0, keepdims=True)
    return f[k], t, np.clip(L, *p.clip)


@dataclass
class Window:
    start: float
    score: float
    path: np.ndarray            # frequency per frame
    z: float = float("nan")
    fit: dict = field(default_factory=dict)


def search(f, t, A, p: Params, skip: tuple[float, ...] = ()) -> list[Window]:
    """Best smooth falling path in every window, all windows at once. A = centred excess."""
    dt = t[1] - t[0]
    W = int(round(p.win_s / dt))
    step = int(round(p.step_s / dt))
    starts = [s for s in range(0, A.shape[1] - W + 1, step)
              if not any(t[s] - 2 < c < t[s] + p.win_s + 1 for c in skip)]
    if not starts:
        return []
    nb, ns, nw = A.shape[0], len(p.slopes), len(starts)
    moves = p.slopes if p.falling else tuple(sorted({-m for m in p.slopes} | set(p.slopes)))
    ns = len(moves)
    cols = np.array(starts)
    V = np.repeat(A[:, cols].T[:, None, :], ns, axis=1)            # (nw, ns, nb)
    back = np.zeros((W, nw, ns, nb), np.int8)
    neg = -1e9
    for j in range(1, W):
        frame = A[:, cols + j].T                                    # (nw, nb)
        newV = np.empty_like(V)
        for mi, m in enumerate(moves):
            # previous bin = k + m (falling pitch: the previous frame was m bins higher)
            if m > 0:
                shifted = np.concatenate([V[:, :, m:], np.full((nw, ns, m), neg)], axis=2)
            elif m < 0:
                shifted = np.concatenate([np.full((nw, ns, -m), neg), V[:, :, :m]], axis=2)
            else:
                shifted = V
            cand = shifted - p.penalty * (np.arange(ns) != mi)[None, :, None]
            arg = np.argmax(cand, axis=1)                           # (nw, nb)
            newV[:, mi] = np.take_along_axis(cand, arg[:, None, :], 1)[:, 0] + frame
            back[j, :, mi] = arg
        V = newV
    out = []
    for w in range(nw):
        order = np.argsort(-V[w], axis=None)[:300]
        chosen = None
        for idx in order:
            mi, k = divmod(int(idx), nb)
            path = [k]
            for j in range(W - 1, 0, -1):
                m = moves[mi]
                mi = int(back[j, w, mi, k])
                k = k + m
                path.append(k)
            pf = f[np.clip(np.array(path[::-1]), 0, nb - 1)]
            if pf[0] - pf[-1] >= p.min_drop * pf[0] or not p.falling:
                chosen = Window(float(t[starts[w]]), float(V[w].flat[idx]), pf)
                break
        out.append(chosen or Window(float(t[starts[w]]), float("nan"), np.array([])))
    return out


C = 343.0


def flyby(par, t, c=C):
    f0, v, d, t0 = par
    x = v * (t - t0)
    r = np.hypot(d, x)
    return f0 / (1 + v * x / (c * r))


def shape_test(path: np.ndarray, win_s: float, c=C, max_rel_rms=0.005) -> dict:
    """Fit a straight flyby to a path; passes with rms < 0.5 % of f0, 20–300 m/s, ≥ 50 m."""
    if len(path) < 10:
        return {"ok": False}
    t = np.arange(len(path)) * (win_s / len(path))
    best = None
    for v0 in (60, 140, 250):
        for d0 in (300, 1500, 5000):
            for t00 in (0, win_s / 2, win_s):
                r = least_squares(lambda q: flyby(q, t, c) - path, [path.mean(), v0, d0, t00],
                                  bounds=([50, 5, 10, -60], [12000, 340, 50000, 70]), loss="soft_l1", f_scale=5)
                rms = float(np.sqrt(np.mean(r.fun ** 2)))
                if best is None or rms < best[0]:
                    best = (rms, r.x)
    rms, (f0, v, d, t0) = best
    return {"ok": bool(rms < max_rel_rms * f0 and 20 <= v <= 300 and d >= 50), "rel_rms": rms / f0,
            "f0": float(f0), "speed": float(v), "distance": float(d)}


def known_path(f, t, A, factor_of_t, f0s, win: tuple[float, float]) -> tuple[float, float]:
    """The attacker with the flight track: sum the excess along f0·factor(t) over `win`, for every
    candidate rest frequency f0 (the engine's tone is unknown), best of ±1 bin. Returns (best sum,
    the f0 it was found at)."""
    j = np.flatnonzero((t >= win[0]) & (t <= win[1]))
    fac = factor_of_t(t[j])
    ok = np.isfinite(fac)
    j, fac = j[ok], fac[ok]
    if len(j) < 10:
        return float("nan"), float("nan")
    df = f[1] - f[0]
    best = (-np.inf, np.nan)
    for f0 in f0s:
        k = np.round((f0 * fac - f[0]) / df).astype(int)
        if k.min() < 1 or k.max() >= len(f) - 1:
            continue
        s = np.max(np.stack([A[k + o, j] for o in (-1, 0, 1)]), 0).sum()
        if s > best[0]:
            best = (float(s), float(f0))
    return best
