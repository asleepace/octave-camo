"""Does the cloak leave a mark where nothing passed? (OPEN_QUESTIONS.md, "Is the fill neutral on
real backgrounds?", and the stopping test's bias.)

Real recordings (our own tuning sessions), and a pass that isn't there: one of the public corpus's
traced curve shapes (Pathak 2026, CC BY 4.0; shapes only), centred at a moment when no tracked
aircraft comes within `CLEAR_KM` for ±`CLEAR_S` s. That curve is the "truth"; its wrong answers are
the other shapes at the same moment, ±6 s, exactly as `zenodo.u` scores a corpus pass. Nothing in
the audio follows the truth any more than its wrong answers, so before cloaking its rank is a fair
draw (uniform); the cloak is then told to expect it (`--expect`) and does what it would for a pass
it was told about. Each copy is measured against a control, the same preset and seed blind to the
curve (no --expect; every other stage is blind anyway): the difference is the track step's own mark.
Above 0 a bump along the curve (e.g. a fill quieter than what it replaced lowers every wrong curve
crossing it), below 0 a hole (removal of chance matches, or a fill too loud). Read against the
control, not against "before" or 0.5: a single shape has a baseline of its own (0.33-0.59 with
nothing there), and any processing pulls a "before" that landed high or low back toward it.

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
CONTROL = "blind"       # the preset without --expect: what the track step is measured against


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
    """One placement: u (1 and 4 lines) before, and after each variant and seed. With codec chains
    (lab/codec.py) as a sixth element, also the four-line u of every copy after each chain, under
    "codec"; a copy identical to its control (nothing filled) takes the control's scores."""
    sid, centre, k, variants, seeds, *rest = args
    chains = [c for c in (rest[0] if rest else []) if c != "raw"]
    from . import codec
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

    def coded(y):
        return {c: u_at(locate.Scene(codec.reencode(y, sr, c), sr, "blank"), p, shapes, centre, zenodo.ATTACKER_LINES)
                for c in chains}
    if chains:
        out["before"]["codec"] = coded(x)
    controls = {}
    import subprocess
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "in.wav"
        sf.write(src, x, sr, subtype="FLOAT")
        exp = Path(tmp) / "e.json"
        exp.write_text(json.dumps([expected_at(p, centre, len(x) / sr)]))
        import re
        # The control: the same preset and seed without --expect (every other stage is blind to the
        # curve), so a variant's effect is its u minus the control's, free of regression to the mean
        # and of the blind stages' own shuffling.
        for name, extra in {CONTROL: None, **variants}.items():
            for seed in seeds:
                dst = Path(tmp) / "o.wav"
                track = [] if extra is None else ["--expect", str(exp), "--track-max-tones", "24", *extra]
                r = subprocess.run([str(cli), "scrub", str(src), str(dst), *PRESET_ARGS["full"], *track, "--seed", str(seed)],
                                   check=True, capture_output=True, text=True)
                y, _ = sf.read(dst)
                y = y if y.ndim == 1 else y[:, 0]
                sy = locate.Scene(y, sr, "blank")
                out[f"{name}-s{seed}"] = {L: u_at(sy, p, shapes, centre, L) for L in (1, zenodo.ATTACKER_LINES)}
                out[f"{name}-s{seed}"]["change_db"] = zenodo.level_change(x, y, sr)
                m = re.search(r"filled (\d+) tone", r.stdout + r.stderr)
                out[f"{name}-s{seed}"]["filled"] = int(m.group(1)) if m else 0
                if chains:
                    if extra is None:
                        controls[seed] = y
                    same = extra is not None and np.array_equal(y, controls[seed])
                    out[f"{name}-s{seed}"]["codec"] = (dict(out[f"{CONTROL}-s{seed}"]["codec"]) if same else coded(y))
    return out


def summarize(rows: list[dict], variants: dict, seeds: list[int]) -> str:
    """Each variant against the control (the same preset and seed, blind to the curve), per
    placement, averaged by session (placements in one session share its background). With nothing
    following the curve, a fair cloak's effect is 0; below is a hole, above a bump. Also the effect
    where the track step filled something and where it didn't (there it must be 0 up to noise)."""
    def by_session(vals, keep=None):
        per = {}
        for i, (r, v) in enumerate(zip(rows, vals)):
            if np.isfinite(v) and (keep is None or keep[i]):
                per.setdefault(r["sid"], []).append(v)
        m = np.array([np.mean(v) for v in per.values()])
        return (m.mean() if len(m) else np.nan), (m.std() / np.sqrt(len(m)) if len(m) > 1 else np.nan), sum(map(len, per.values()))
    lines = [f"{len(rows)} placements in {len({r['sid'] for r in rows})} sessions; a curve nothing follows; "
             f"each variant against the preset blind to it"]
    for L in (1, zenodo.ATTACKER_LINES):
        c = np.array([np.nanmean([r[f"{CONTROL}-s{s}"][L] for s in seeds]) for r in rows], float)
        b = np.array([r["before"][L] for r in rows], float)
        m, e, n = by_session(c)
        lines.append(f"  {L} line(s): untouched {np.nanmean(b):.3f}, blind preset {m:.3f} ± {e:.3f}")
        for name in variants:
            a = np.array([np.nanmean([r[f"{name}-s{s}"][L] for s in seeds]) for r in rows], float)
            filled = np.array([any(r[f"{name}-s{s}"]["filled"] > 0 for s in seeds) for r in rows])
            m, e, n = by_session(a - c)
            mf, ef, nf = by_session(a - c, filled)
            mn, en, nn = by_session(a - c, ~filled)
            every = np.array([r[f"{name}-s{s}"][L] for r in rows for s in seeds], float)
            lines.append(f"    {name}: effect {m:+.3f} ± {e:.3f}; where it filled ({nf}) {mf:+.3f} ± {ef:.3f}, "
                         f"where not ({nn}) {mn:+.3f} ± {en:.3f}; top 5 % {int(np.nansum(every >= 0.95))}, "
                         f"bottom 5 % {int(np.nansum(every <= 0.05))} of {int(np.isfinite(every).sum())}")
    chains = list(rows[0]["before"].get("codec", {})) if rows else []
    if chains:
        lines.append(f"  {zenodo.ATTACKER_LINES} lines after a codec (lab/codec.py), each against the control through the same chain:")
    for c in chains:
        cc = np.array([np.nanmean([r[f"{CONTROL}-s{s}"]["codec"][c] for s in seeds]) for r in rows], float)
        m, e, _ = by_session(cc)
        lines.append(f"    {c}: untouched {np.nanmean([r['before']['codec'][c] for r in rows]):.3f}, blind preset {m:.3f} ± {e:.3f}")
        for name in variants:
            a = np.array([np.nanmean([r[f"{name}-s{s}"]["codec"][c] for s in seeds]) for r in rows], float)
            filled = np.array([any(r[f"{name}-s{s}"]["filled"] > 0 for s in seeds) for r in rows])
            m, e, _ = by_session(a - cc)
            mf, ef, nf = by_session(a - cc, filled)
            every = np.array([r[f"{name}-s{s}"]["codec"][c] for r in rows for s in seeds], float)
            lines.append(f"      {name}: effect {m:+.3f} ± {e:.3f}; where it filled ({nf}) {mf:+.3f} ± {ef:.3f}; "
                         f"top 5 % {int(np.nansum(every >= 0.95))}, bottom 5 % {int(np.nansum(every <= 0.05))} of {int(np.isfinite(every).sum())}")
    for name in variants:
        f = [r[f"{name}-s{s}"]["filled"] for r in rows for s in seeds]
        ch = [r[f"{name}-s{s}"]["change_db"] - r[f"{CONTROL}-s{s}"]["change_db"] for r in rows for s in seeds]
        lines.append(f"  {name}: tones filled per copy {np.mean(f):.1f} (filled in {np.mean(np.array(f) > 0):.0%}); "
                     f"sound change over the blind preset {np.mean(ch):+.2f} dB")
    return "\n".join(lines)
