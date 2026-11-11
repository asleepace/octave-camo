"""Does the cloak leave a mark where nothing passed? (OPEN_QUESTIONS.md, "Is the fill neutral on
real backgrounds?", and the stopping test's bias.)

Real recordings (our own tuning sessions), and a pass that isn't there: one of the public corpus's
traced curve shapes (Pathak 2026, CC BY 4.0; shapes only), centred at a moment when no tracked
aircraft comes within `CLEAR_KM` for ±`CLEAR_S` s. That curve is the "truth"; its wrong answers are
the other shapes at the same moment, ±6 s, exactly as `zenodo.u` scores a corpus pass. Nothing in
the audio follows the truth any more than its wrong answers, so before cloaking its rank is a fair
draw (uniform); the cloak is then told to expect it (`--expect`) and does what it would for a pass
it was told about. Afterwards the rank should still be a fair draw: a mean above 0.5 means the cloak
leaves a bump along the curve (e.g. a fill quieter than what it replaced lowers every wrong curve
crossing it), below 0.5 a hole (removal of chance matches, or a fill too loud).

Prints aggregates only: no positions, no times of day. Real aircraft without ADS-B aren't in the
tracks, so "no tracked aircraft" isn't "silent"; it only has to be unrelated to the test curve.

    python3 -m lab blank [--seeds 7,8] [--variant name=args ...]   (default variants: fixed)
"""
from __future__ import annotations

import json
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

from . import corpus, locate, zenodo

CLEAR_KM = 4.0
CLEAR_S = 20.0
EDGE_S = 31.0          # the engine's fill reaches ±31 s (25 s window + 6 s timing)
SPACING_S = 30.0       # placements in one session at least this far apart
PER_SESSION = 3


def placements(sid: str) -> list[float]:
    """Centres (s from the audio's start) where no tracked aircraft is within CLEAR_KM for ±CLEAR_S."""
    g = corpus.geometry(sid)
    dur = g["duration_s"]
    grid = np.arange(0, dur, 0.5)
    near = np.zeros(len(grid), bool)
    for te, q, _ in g["tracks"].values():
        r = np.linalg.norm(q, axis=1) / 1000
        near |= np.interp(grid, te, r, left=np.inf, right=np.inf) < CLEAR_KM
    out = []
    for c in np.arange(EDGE_S, dur - EDGE_S, 2.5):
        if near[np.abs(grid - c) <= CLEAR_S].any() or any(abs(c - o) < SPACING_S for o in out):
            continue
        out.append(float(c))
        if len(out) == PER_SESSION:
            break
    return out


def expected_at(p: dict, centre: float, duration: float) -> dict:
    """The corpus pass's shape as an ExpectedPass with its closest approach at `centre`."""
    t, fac, tc = zenodo.shape(p)
    grid = np.arange(-60.0, duration + 60.0, 0.1)
    return {"times": np.round(grid, 3).tolist(),
            "factors": np.round(zenodo.flat_interp(grid - (centre - tc), t, fac), 7).tolist(),
            "closest": round(centre, 3)}


def u_at(scene: locate.Scene, p: dict, others: list[dict], centre: float, lines: int) -> float:
    """zenodo.u for a shape whose closest approach is at `centre` (s from the audio's start)."""
    _, _, tc = zenodo.shape(p)
    return zenodo.u(scene, p, others, offset=centre - tc, lines=lines)[0]


def trial(args: tuple) -> dict:
    """One placement: u (1 and 4 lines) before, and after each variant and seed."""
    sid, centre, k, variants, seeds = args
    from . import detect
    locate.whitened = lambda name, x, sr, prm: detect.whiten(x, sr, prm)   # scored once: no disk cache
    from .__main__ import PRESET_ARGS
    shapes = [p for p in zenodo.passes() if zenodo.usable(p) and zenodo.half(p["case"]) == "tune"]
    p = shapes[k % len(shapes)]
    _, x, sr = corpus.load(sid)
    cli = Path(__file__).resolve().parent.parent / ".build/release/octave-camo"
    out = {"sid": sid[-6:], "shape": p["case"], "before": {}}
    sc = locate.Scene(x, sr, "blank")
    for L in (1, zenodo.ATTACKER_LINES):
        out["before"][L] = u_at(sc, p, shapes, centre, L)
    import subprocess
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "in.wav"
        sf.write(src, x, sr, subtype="FLOAT")
        exp = Path(tmp) / "e.json"
        exp.write_text(json.dumps([expected_at(p, centre, len(x) / sr)]))
        for name, extra in variants.items():
            for seed in seeds:
                dst = Path(tmp) / "o.wav"
                subprocess.run([str(cli), "scrub", str(src), str(dst), *PRESET_ARGS["full"], "--expect", str(exp),
                                "--track-max-tones", "24", *extra, "--seed", str(seed)], check=True, capture_output=True)
                y, _ = sf.read(dst)
                y = y if y.ndim == 1 else y[:, 0]
                sy = locate.Scene(y, sr, "blank")
                out[f"{name}-s{seed}"] = {L: u_at(sy, p, shapes, centre, L) for L in (1, zenodo.ATTACKER_LINES)}
                out[f"{name}-s{seed}"]["change_db"] = zenodo.level_change(x, y, sr)
    return out


def summarize(rows: list[dict], variants: dict, seeds: list[int]) -> str:
    lines = [f"{len(rows)} placements in {len({r['sid'] for r in rows})} sessions; u of a curve nothing follows"]
    for L in (1, zenodo.ATTACKER_LINES):
        b = np.array([r["before"][L] for r in rows], float)
        lines.append(f"  {L} line(s): before mean {np.nanmean(b):.2f}, top 5 % {int(np.nansum(b >= 0.95))}, "
                     f"bottom 5 % {int(np.nansum(b <= 0.05))} of {int(np.isfinite(b).sum())}")
        for name in variants:
            a = np.array([[r[f"{name}-s{s}"][L] for s in seeds] for r in rows], float)
            d = np.nanmean(a, 1) - b
            n = np.isfinite(d).sum()
            lines.append(f"    {name}: after mean {np.nanmean(a):.2f}, paired change {np.nanmean(d):+.3f} ± "
                         f"{np.nanstd(d) / np.sqrt(max(n, 1)):.3f}, top 5 % {int(np.nansum(a >= 0.95))}, "
                         f"bottom 5 % {int(np.nansum(a <= 0.05))} of {int(np.isfinite(a).sum())}")
    for name in variants:
        c = [r[f"{name}-s{s}"]["change_db"] for r in rows for s in seeds]
        lines.append(f"  {name}: sound change above 300 Hz {np.mean(c):.2f} dB (max {np.max(c):.2f})")
    return "\n".join(lines)
