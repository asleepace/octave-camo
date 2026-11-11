"""Does track removal leave the true curve looking like any other? (docs/EXPERIMENTS.md, "What
leaves the dip".) On plane-free audio (synthetic room noise, music, pink noise; nothing real), one
predicted pass at a random time; the clip cloaked with track removal (fixed stop, or the null
target) and left alone. Scored the attacker's way: the best mean excess along the true curve over
every rest frequency, as a percentile among the same curve centred at 28 other times, each scored
on its own stretch (50-85 s away, clear of anything removal touched; the 28 stretches overlap each
other, so they're fewer than 28 independent draws). The same shape at another
time, as a wrong place's curve would be; not the curve moved within one stretch, which puts its fall
outside it and leaves a flat curve that scores differently in noise and higher on held notes. With
no plane there is nothing to find, so a clean cloak leaves that percentile uniform (mean 0.5):
lower is the dip (a hole, summed over aircraft), higher a bump.

    python3 -m lab.nulltest [runs per background] [--plane | --plane=harmonic] [--kinds=room,music,pink] [--untouched --fixed --null --null0]
(--plane: an engine along the curve first; then a clean removal leaves 0.5 too, a residual more, a
hole less. The engine is the corpus's kind by default (docs/EXPERIMENTS.md, "What real engines
carry"): a main line and a few others at unrelated frequencies and similar levels; --plane=harmonic
is the earlier tone with ×2 and ×3.) Scored by two attackers: the best single line (L1) and the
best four lines added up (L4, THREAT_MODEL.md).
"""
from __future__ import annotations

import json
import sys
import tempfile

import numpy as np

from . import detect, fillmark, locate, synth

# Every scene here is scored once: no disk cache (200 s scenes, a few hundred of them, fill it).
locate.whitened = lambda name, x, sr, p: detect.whiten(x, sr, p)

SECONDS = 200.0
SHIFTS = np.concatenate([-np.arange(50, 85, 2.5), np.arange(50, 85, 2.5)])
HALF = 15.0
LINES = (1, 4)


def percentile(y: np.ndarray, sr: int, tc: float, depth: float, name: str) -> dict[int, float]:
    """{lines: the truth's percentile} for each attacker in LINES."""
    sc = locate.Scene(y, sr, name)
    def prof(c):
        j = np.flatnonzero(np.abs(sc.t - c) <= HALF)
        return fillmark.per_rest(sc, j, fillmark.factor(sc.t[j], c, depth))
    p0, ps = prof(tc), [prof(tc + d) for d in SHIFTS]
    out = {}
    for k in LINES:
        s0, nulls = sc.lines_of(p0, k), np.array([sc.lines_of(p, k) for p in ps])
        nulls = nulls[np.isfinite(nulls)]
        out[k] = locate.rank(s0, nulls)
    return out


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


def engine(rng, kind: str = "corpus") -> list[tuple[float, float]]:
    """An engine's lines as (rest frequency, amplitude relative to the main line). "corpus": what
    the public corpus's passes show above chance (docs/EXPERIMENTS.md, "What real engines carry"):
    a main line, Poisson(2) others (at most 5) log-uniform over 150 Hz–2.5 kHz and 5 % apart, each
    −6 to +3 dB of the main line, and a third of the time one of them at twice or half the main
    line. "harmonic": the earlier tone with ×2 (0.6) and ×3 (0.4)."""
    f0 = float(np.exp(rng.uniform(np.log(200), np.log(1200))))
    if kind == "harmonic":
        f0 = float(rng.uniform(400, 1200))
        return [(f0, 1.0), (2 * f0, 0.6), (3 * f0, 0.4)]
    lines = [(f0, 1.0)]
    n = min(int(rng.poisson(2.0)), 5)
    while len(lines) < n + 1:
        if len(lines) == 1 and rng.random() < 1 / 3:
            f = f0 * (2.0 if rng.random() < 0.5 else 0.5)
        else:
            f = float(np.exp(rng.uniform(np.log(150), np.log(2500))))
        if all(abs(f / g - 1) > 0.05 for g, _ in lines):
            lines.append((f, float(10 ** (rng.uniform(-6, 3) / 20))))
    return lines


def plane(x: np.ndarray, tc: float, depth: float, rng, snr_db: float = 14.0, kind: str = "corpus") -> np.ndarray:
    """An engine (`engine`) along the pass's curve, swelling over ~25 s around the closest
    approach, the main line `snr_db` over a hertz of the background near it (its median)."""
    sr = synth.SR
    X = np.abs(np.fft.rfft(x)) ** 2 / (len(x) * sr / 2)
    f = np.fft.rfftfreq(len(x), 1 / sr)
    t = np.arange(len(x)) / sr
    env = np.exp(-0.5 * ((t - tc) / 12.0) ** 2)
    phase = 2 * np.pi * np.cumsum(fillmark.factor(t, tc, depth)) / sr
    y = x.copy()
    for fl, lv in engine(rng, kind):
        if fl * (1 + depth) >= sr / 2:
            continue
        psd = np.median(X[(f > 0.9 * fl) & (f < 1.1 * fl)])
        y += lv * np.sqrt(2 * psd * 10 ** (snr_db / 10)) * env * np.sin(fl * phase + rng.uniform(0, 2 * np.pi))
    return y


def run(runs: int = 12, with_plane: bool | str = False, variants: dict | None = None,
        kinds: tuple[str, ...] = ("room", "music", "pink")) -> dict:
    """with_plane: False, True (the corpus's kind of engine) or an `engine` kind."""
    rng = np.random.default_rng(1)
    variants = variants or {"untouched": None, "fixed": [], "null": ["--track-target", "null"]}
    out = {}
    tmpdir = tempfile.mkdtemp()
    for kind in kinds:
        res = {v: [] for v in variants}
        for r in range(runs):
            x = background(kind, 100 + r)
            tc, depth = float(rng.uniform(95, 105)), float(rng.uniform(0.15, 0.35))
            if with_plane:
                x = plane(x, tc, depth, rng, kind="corpus" if with_plane is True else with_plane)
            grid = np.arange(-60.0, SECONDS + 60.0, 0.1)
            exp = [{"times": np.round(grid, 3).tolist(), "factors": np.round(fillmark.factor(grid, tc, depth), 7).tolist(), "closest": tc}]
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, dir=tmpdir) as f:
                json.dump(exp, f)
            for v, extra in variants.items():
                base = ["--steps", "mono", "--seed", str(r + 1)]
                y = fillmark.scrub(x, synth.SR, base if extra is None else [*base, "--expect", f.name, *extra])
                res[v].append(percentile(y, synth.SR, tc, depth, f"nulltest:{kind}:{r}:{v}:{'plane' if with_plane else 'free'}"))
            print(kind, r, {v: {k: round(u, 2) for k, u in p[-1].items()} for v, p in res.items()}, flush=True)
        out[kind] = {v: {k: (float(np.mean([u[k] for u in p])), float(np.std([u[k] for u in p]) / np.sqrt(len(p))))
                         for k in LINES} for v, p in res.items()}
        print(kind, {v: {f"L{k}": f"{m:.2f} ± {e:.2f}" for k, (m, e) in d.items()} for v, d in out[kind].items()}, flush=True)
    return out


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    only = [a[2:] for a in sys.argv[1:] if a.startswith("--") and not a.startswith(("--plane", "--kinds"))]
    kinds = next((tuple(a.split("=", 1)[1].split(",")) for a in sys.argv[1:] if a.startswith("--kinds=")), ("room", "music", "pink"))
    planes = [a.split("=", 1)[1] if "=" in a else True for a in sys.argv[1:] if a.startswith("--plane")]
    allv = {"untouched": None, "fixed": [], "null": ["--track-target", "null"],
            "null0": ["--track-target", "null", "--track-max-raises", "0"],
            "lines4": ["--track-lines", "4", "--track-max-tones", "48"]}
    run(int(args[0]) if args else 12, planes[0] if planes else False, {k: v for k, v in allv.items() if not only or k in only}, kinds)
