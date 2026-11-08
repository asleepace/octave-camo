"""Does track removal leave the true curve looking like any other? (docs/EXPERIMENTS.md, "What
leaves the dip".) On plane-free audio (synthetic room noise, music, pink noise; nothing real), one
predicted pass at a random time; the clip cloaked with track removal (fixed stop, or the null
target) and left alone. Scored the attacker's way: the best mean excess along the true curve over
every rest frequency, as a percentile among the same curve centred at 28 other times, each scored
on its own stretch (50-85 s away, clear of anything removal touched). The same shape at another
time, as a wrong place's curve would be; not the curve moved within one stretch, which puts its fall
outside it and leaves a flat curve that scores differently in noise and higher on held notes. With
no plane there is nothing to find, so a clean cloak leaves that percentile uniform (mean 0.5):
lower is the dip (a hole, summed over aircraft), higher a bump.

    python3 -m lab.nulltest [runs per background]
"""
from __future__ import annotations

import json
import sys
import tempfile

import numpy as np

from . import fillmark, locate, synth

SECONDS = 200.0
SHIFTS = np.concatenate([-np.arange(50, 85, 2.5), np.arange(50, 85, 2.5)])
HALF = 15.0


def percentile(y: np.ndarray, sr: int, tc: float, depth: float, name: str) -> float:
    sc = locate.Scene(y, sr, name)
    def best(c):
        j = np.flatnonzero(np.abs(sc.t - c) <= HALF)
        return np.nanmax(fillmark.per_rest(sc, j, fillmark.factor(sc.t[j], c, depth)))
    s0, nulls = best(tc), np.array([best(tc + d) for d in SHIFTS])
    return float(np.mean(nulls < s0) + 0.5 * np.mean(nulls == s0))


def background(kind: str, seed: int, seconds: float = SECONDS) -> np.ndarray:
    n = int(seconds * synth.SR)
    if kind == "room":
        return synth.room(seconds, seed=seed)[:n]
    if kind == "music":
        parts, k = [], 0
        while sum(map(len, parts)) < n:                       # 58 s pieces, each its own tune
            parts.append(synth.music(seed=seed + 1000 * k)[0]); k += 1
        return np.concatenate(parts)[:n]
    return fillmark._pink(n, np.random.default_rng(seed + 5000))    # not room's white noise


def run(runs: int = 12) -> dict:
    rng = np.random.default_rng(1)
    variants = {"untouched": None, "fixed": [], "null": ["--track-target", "null"]}
    out = {}
    for kind in ("room", "music", "pink"):
        res = {v: [] for v in variants}
        for r in range(runs):
            x = background(kind, 100 + r)
            tc, depth = float(rng.uniform(95, 105)), float(rng.uniform(0.15, 0.35))
            grid = np.arange(-60.0, SECONDS + 60.0, 0.1)
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
