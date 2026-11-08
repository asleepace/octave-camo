"""Run: python3 -c "import lab.orderstat" (docs/EXPERIMENTS.md, "What leaves the dip").
Ideal fill in the attacker's own domain: replace the whitened spectrogram along chosen rests'
true curves with the same bins at another time (coherent shift). Top-scoring rests vs random ones."""

import numpy as np
from . import fillmark, locate
from .common import whitened

def scene_from(f, t, L):
    s = object.__new__(locate.Scene); s.f, s.t = f, t
    A = L - L.mean(); Am = A.copy()
    for o in range(1, locate.TOL_BINS + 1):
        Am[:-o] = np.maximum(Am[:-o], A[o:]); Am[o:] = np.maximum(Am[o:], A[:-o])
    s.A = Am; s.df = f[1] - f[0]
    rows = np.log(locate.F0S[0]) + (np.arange(len(locate.F0S) + 2 * locate.FAC_ROWS) - locate.FAC_ROWS) * locate.STEP
    b = np.rint((np.exp(rows) - f[0]) / s.df).astype(np.int64); inside = (b >= 0) & (b < len(f))
    G = np.full((len(rows), Am.shape[1]), np.nan); G[inside] = Am[b[inside]]
    s.C = np.concatenate([np.zeros((1, len(rows))), np.cumsum(G.T, axis=0)], axis=0)
    return s

def stats(sc, tc):
    j = np.flatnonzero(np.abs(sc.t - tc) <= locate.HALF_WINDOW_S)
    true = fillmark.per_rest(sc, j, fillmark.factor(sc.t[j], tc))
    wrong = np.array([fillmark.per_rest(sc, j, fillmark.factor(sc.t[j] - d, tc)) for d in locate.NULL_SHIFTS_S])
    bw = np.nanmax(wrong, 1)
    return true, np.nanmean(wrong, 0), (np.nanmax(true) - bw.mean()) / bw.std()

rng = np.random.default_rng(0)
for name, (x, sr) in fillmark.backgrounds().items():
    f, t, L = whitened(f"os:{name}", x, sr, locate.P)
    tc = t[-1] / 2; dt = t[1] - t[0]
    sc0 = scene_from(f, t, L); t0, w0, z0 = stats(sc0, tc)
    j = np.flatnonzero(np.abs(t - tc) <= locate.HALF_WINDOW_S)
    finite = np.flatnonzero(np.isfinite(t0))
    for pick in ("top", "random"):
        marks, dzs = [], []
        for rep in range(5):
            rests = finite[np.argsort(t0[finite])[-6:]] if pick == "top" else rng.choice(finite, 6, replace=False)
            L1 = L.copy()
            for r in rests:
                d = int(rng.integers(int(2 / dt), int(8 / dt))) * rng.choice([-1, 1])
                fr = locate.F0S[r] * fillmark.factor(t[j], tc)
                for jj, ff in zip(j, fr):
                    b = int(round((ff - f[0]) / (f[1] - f[0])))
                    src = jj + d
                    if 0 <= src < len(t):
                        L1[max(0, b - 3):b + 4, jj] = L[max(0, b - 3):b + 4, src]
            t1, w1, z1 = stats(scene_from(f, t, L1), tc)
            marks.append(np.nanmean(((t1 - w1) - (t0 - w0))[rests])); dzs.append(z1 - z0)
            if pick == "top": break   # deterministic choice
        print(f"{name:6s} {pick:6s} mark {np.mean(marks):+.3f}  dz {np.mean(dzs):+.2f}")
