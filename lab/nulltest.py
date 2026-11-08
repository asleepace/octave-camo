"""Does track removal leave the true curve looking like any other? (docs/EXPERIMENTS.md, "What
leaves the dip".) On plane-free audio (synthetic room noise, music, pink noise; nothing real), one
predicted pass at a random time; the clip cloaked with track removal (fixed stop, or the null
target) and left alone. Scored the attacker's way: the best mean excess along the true curve over
every rest frequency, as a percentile among the same curve at 40 wrong times. With no plane there
is nothing to find, so a clean cloak leaves that percentile uniform (mean 0.5): lower is the dip
(a hole, summed over aircraft), higher a bump.

    python3 -m lab.nulltest [runs per background]
"""
from __future__ import annotations

import json
import sys
import tempfile

import numpy as np

from . import fillmark, locate, synth

SHIFTS = np.concatenate([-np.arange(10, 40.1, 1.5), np.arange(10, 40.1, 1.5)])


def percentile(y: np.ndarray, sr: int, tc: float, depth: float, name: str) -> float:
    sc = locate.Scene(y, sr, name)
    j = np.flatnonzero(np.abs(sc.t - tc) <= locate.HALF_WINDOW_S)
    best = lambda d: np.nanmax(fillmark.per_rest(sc, j, fillmark.factor(sc.t[j] - d, tc, depth)))
    s0, nulls = best(0.0), np.array([best(d) for d in SHIFTS])
    return float(np.mean(nulls < s0) + 0.5 * np.mean(nulls == s0))


def background(kind: str, seed: int, seconds: float = 60.0) -> np.ndarray:
    n = int(seconds * synth.SR)
    if kind == "room":
        return synth.room(seconds, seed=seed)[:n]
    if kind == "music":
        x = synth.music(seed=seed)[0]
        return np.pad(x, (0, max(0, n - len(x))))[:n]
    return fillmark._pink(n, np.random.default_rng(seed + 5000))    # not room's white noise


def run(runs: int = 12) -> dict:
    rng = np.random.default_rng(1)
    variants = {"untouched": None, "fixed": [], "null": ["--track-target", "null"]}
    out = {}
    for kind in ("room", "music", "pink"):
        res = {v: [] for v in variants}
        for r in range(runs):
            x = background(kind, 100 + r)
            tc, depth = float(rng.uniform(25, 35)), float(rng.uniform(0.15, 0.35))
            grid = np.arange(-60.0, 120.0, 0.1)
            exp = [{"times": np.round(grid, 3).tolist(), "factors": np.round(fillmark.factor(grid, tc, depth), 7).tolist(), "closest": tc}]
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
                json.dump(exp, f)
            for v, extra in variants.items():
                base = ["--steps", "mono", "--seed", str(r + 1)]
                y = fillmark.scrub(x, synth.SR, base if extra is None else [*base, "--expect", f.name, *extra])
                res[v].append(percentile(y, synth.SR, tc, depth, f"nulltest:{kind}:{r}:{v}"))
            print(kind, r, {v: round(p[-1], 2) for v, p in res.items()}, flush=True)
        out[kind] = {v: (float(np.mean(p)), float(np.std(p) / np.sqrt(len(p)))) for v, p in res.items()}
        print(kind, {v: f"{m:.2f} ± {e:.2f}" for v, (m, e) in out[kind].items()}, flush=True)
    return out


if __name__ == "__main__":
    run(int(sys.argv[1]) if len(sys.argv) > 1 else 12)
