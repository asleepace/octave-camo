"""Detectors for docs/EXPERIMENTS.md, as composable pieces: whitening, the path search (vectorised over
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
    """Received frequency of a straight pass at receive times t: rest frequency f0, speed v,
    closest distance d, closest approach *heard* at t0. Sound heard at t left the source at τ,
    where τ + r(τ)/c = t (Newton, as FlybyGeometry does in Swift). Leaving the travel time out (τ = t)
    biases a fit: on a modelled 1,234 Hz, 141 m/s, 2 km pass it gave 1,317 Hz and 1.7 km."""
    f0, v, d, t0 = par
    te0 = t0 - d / c
    tau = t - d / c
    for _ in range(8):
        x = v * (tau - te0)
        r = np.hypot(d, x)
        tau = tau - (tau + r / c - t) / (1 + v * x / (c * r))
    x = v * (tau - te0)
    r = np.hypot(d, x)
    return f0 / (1 + v * x / (c * r))


def flyby_no_travel(par, t, c=C):
    """`flyby` without the sound's travel time (receive time taken as emission time): ~10× cheaper,
    the same family of shapes up to a warp of time, so a fine first pass for the fit."""
    f0, v, d, t0 = par
    x = v * (t - t0)
    r = np.hypot(d, x)
    return f0 / (1 + v * x / (c * r))


def shape_test(path: np.ndarray, win_s: float, c=C, max_rel_rms=0.005, dt: float | None = None) -> dict:
    """Fit a straight flyby to a path; passes with rms < 0.5 % of f0, 20–300 m/s, 50 m–30 km. `dt` is
    the path's frame spacing (default: the window over the path's length). Multi-start on the
    model without travel time, then one refinement with it (the geometry is then unbiased)."""
    if len(path) < 10:
        return {"ok": False}
    t = np.arange(len(path)) * (dt if dt else win_s / len(path))
    bounds = ([50, 5, 10, -60], [12000, 340, 50000, 70])
    best = None
    for v0 in (60, 140, 250):
        for d0 in (300, 1500, 5000):
            for t00 in (0, win_s / 2, win_s):
                r = least_squares(lambda q: flyby_no_travel(q, t, c) - path, [path.mean(), v0, d0, t00],
                                  bounds=bounds, loss="soft_l1", f_scale=5)
                rms = float(np.sqrt(np.mean(r.fun ** 2)))
                if best is None or rms < best[0]:
                    best = (rms, r.x)
    start = best[1].copy()
    start[3] = start[3] + start[2] / c                     # heard closest approach ≈ emitted + d/c
    start = np.clip(start, bounds[0], bounds[1])
    r = least_squares(lambda q: flyby(q, t, c) - path, start, bounds=bounds, loss="soft_l1", f_scale=5)
    rms_t = float(np.sqrt(np.mean(r.fun ** 2)))
    rms, (f0, v, d, t0) = (rms_t, r.x) if rms_t <= best[0] * 1.5 else best
    return {"ok": bool(rms < max_rel_rms * f0 and 20 <= v <= 300 and 50 <= d <= 30_000), "rel_rms": rms / f0,
            "f0": float(f0), "speed": float(v), "distance": float(d)}


RATIO = 1.002    # rest-frequency step (0.2 %), as the engine's TrackFill searches


def _tolerant(A, tol: int):
    """Each bin the best of ±`tol` bins (the curve is only as good as the track), once."""
    Am = A.copy()
    for o in range(1, tol + 1):
        Am[:-o] = np.maximum(Am[:-o], A[o:])
        Am[o:] = np.maximum(Am[o:], A[:-o])
    return Am


def _known_path_search(f, t, A, factor_of_t, f0s, win, taus, tol: int = 2):
    """The best mean excess along f0·factor(t − τ) over `win` for each timing τ: {τ: (mean, f0)}.

    On a log-frequency axis a rest frequency times a Doppler factor is a shift, so each frame's
    excess is resampled once onto that axis (rests `RATIO` apart over the span of `f0s`) and all
    rests are scored at once by one gather per frame. A curve that leaves the band in any frame
    scores far below anything real (the attacker counts only curves inside the band throughout)."""
    j = np.flatnonzero((t >= win[0]) & (t <= win[1]))
    out = {}
    if len(j) < 10:
        return {tau: (float("nan"), float("nan")) for tau in taus}
    lo, hi = float(np.min(f0s)), float(np.max(f0s))
    rests = lo * RATIO ** np.arange(int(np.log(hi / lo) / np.log(RATIO)) + 1)
    span = int(np.ceil(np.log(2) / np.log(RATIO))) + 1          # factors 0.5–2
    lj = np.arange(-span, len(rests) + span)
    df = f[1] - f[0]
    k = np.round((lo * RATIO ** lj - f[0]) / df).astype(int)
    valid = (k >= 0) & (k < len(f))
    Am = _tolerant(A, tol).astype(np.float32)
    rows = np.full((len(j), len(lj)), -1e9, np.float32)
    rows[:, valid] = Am[k[valid]][:, j].T
    R = len(rests)
    cols = np.arange(R)
    for tau in taus:
        fac = factor_of_t(t[j] - tau)
        ok = np.isfinite(fac) & (fac > 0)
        if ok.sum() < 10:
            out[tau] = (float("nan"), float("nan"))
            continue
        shift = np.round(np.log(fac[ok]) / np.log(RATIO)).astype(int) + span
        means = rows[np.flatnonzero(ok)[:, None], shift[:, None] + cols[None, :]].mean(0, dtype=np.float64)
        i = int(np.argmax(means))
        out[tau] = (float(means[i]), float(rests[i])) if means[i] > -1e6 else (float("nan"), float("nan"))
    return out


def known_path(f, t, A, factor_of_t, f0s, win: tuple[float, float], offsets=np.arange(-6, 6.01, 0.5), tol: int = 2):
    """The attacker with the flight track: the mean excess along f0·factor(t − offset) over `win`,
    for every candidate rest frequency f0 over the span of `f0s` (the engine's tone is unknown;
    0.2 % steps) and a small time offset (published positions lag and are coarse), best of ±`tol`
    bins. Returns (best mean, f0, offset). A mean, not a sum: a curve moved in time for a null can
    run off its track's span, and a sum over fewer frames would read as less evidence."""
    res = _known_path_search(f, t, A, factor_of_t, f0s, win, [float(o) for o in offsets], tol)
    best = (-np.inf, np.nan, np.nan)
    for o, (m, f0) in res.items():
        if np.isfinite(m) and m > best[0]:
            best = (m, f0, o)
    return best if np.isfinite(best[0]) else (float("nan"), float("nan"), float("nan"))


NULL_SHIFTS = tuple(s * d for d in np.arange(20.0, 60.1, 2.5) for s in (-1, 1))


def known_path_z(f, t, A, factor_of_t, f0s, win: tuple[float, float], offsets=np.arange(-6, 6.01, 0.5), shifts=NULL_SHIFTS):
    """The known-path attacker's score as (z, effect in dB, f0, offset): its best mean excess
    against the same search with the curve moved 20–60 s (34 wrong times, so the spread is
    stable: with eight, removing a tone the wrong-time curves happened to cross could shrink it and
    inflate z with less evidence left). The effect is best minus the null mean, per frame.
    Offsets and shifts that add up to the same timing are searched once."""
    offsets = [float(o) for o in offsets]
    taus = sorted({round(s + o, 6) for s in (0.0, *shifts) for o in offsets})
    res = _known_path_search(f, t, A, factor_of_t, f0s, win, taus)

    def best(shift):
        top = (-np.inf, np.nan, np.nan)
        for o in offsets:
            m, f0 = res[round(shift + o, 6)]
            if np.isfinite(m) and m > top[0]:
                top = (m, f0, o)
        return top

    b, f0, off = best(0.0)
    nulls = np.array([best(s)[0] for s in shifts])
    nulls = nulls[np.isfinite(nulls)]
    if not np.isfinite(b) or len(nulls) < 10:
        return float("nan"), float("nan"), f0, off
    return float((b - nulls.mean()) / nulls.std()), float(b - nulls.mean()), f0, off
