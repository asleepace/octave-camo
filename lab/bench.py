"""The curve benchmark: how faint a pass each detector finds, and how often it cries wolf.

Positives: a synthetic pass (lab/passes.py) mixed into a minute of background at a set strength.
Negatives: the backgrounds alone. Backgrounds are real plane-free recorder sessions (local only:
they carry a location, so this half never runs in CI) and the lab's synthetic scenes (music,
singing, speech, a siren, construction, a quiet room).

Detectors:
- **check:** the page's check (the Swift `FlybyAnalyzer`, via the CLI): its Doppler tracks.
- **blind:** the lab's E2 detector (path search + flyby shape test, z ≥ 10).
- **known path:** the attacker who has the flight track (z ≥ 5 against the curve at wrong times):
  not a blind detector, the ceiling a blind one can approach.

A detection counts when its time-frequency box follows one of the pass's tones (within 3 % for
half of its span, where that tone is no more than 25 dB below its loudest); anything else is a
false alarm.
"""
from __future__ import annotations

import json
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from . import corpus, detect, passes, synth

SR = 48_000
SECONDS = 60.0
REPO = Path(__file__).resolve().parent.parent
CLI = REPO / ".build/release/octave-camo"

# Recorder sessions where no aircraft was found by any detector, including the known-path
# attacker (docs/EXPERIMENTS.md): the real backgrounds.
PLANE_FREE = [
    "20261104T082022Z_f74a40", "20261104T083314Z_a2f229", "20261104T084455Z_94d99a",
    "20261104T090113Z_e9a1c3", "20261104T173439Z_1f57cd", "20261105T053504Z_f8b75a",
    "20261105T160319Z_9f5d28", "20261105T161812Z_cf7ad9", "20261105T190941Z_454d2c",
]
SYNTH_BACKGROUNDS = ["room", "music", "singing", "speech", "siren", "bangs"]

BLIND_Z = 10.0
KNOWN_Z = 5.0


@dataclass(frozen=True)
class Clip:
    """One benchmark clip, fully determined by its fields (rebuilt on demand, never stored)."""
    background: str            # "session:<id>@<offset s>" or "synth:<scene>"
    snr: float | None          # None: a negative (background only)
    seed: int

    def key(self) -> str:
        return f"{self.background}|{self.snr}|{self.seed}"


def backgrounds(real: bool = True) -> list[str]:
    out = [f"synth:{s}" for s in SYNTH_BACKGROUNDS]
    if real:
        import soundfile as sf
        for sid in PLANE_FREE:
            d = corpus.sessions_dir() / sid
            if not (d / "index.json").exists():
                continue
            meta = json.load(open(d / "meta.json"))
            info = sf.info(str(d / meta["audio"]["file"]))
            if info.samplerate != SR:
                continue
            dur = info.frames / SR
            # Non-overlapping minutes, skipping the first 5 s (calibration chirps).
            out += [f"session:{sid}@{o:.0f}" for o in np.arange(5, dur - SECONDS + 1e-9, SECONDS)]
    return out


def load_background(name: str) -> np.ndarray:
    kind, rest = name.split(":", 1)
    if kind == "synth":
        scene = {"room": lambda: synth.room(SECONDS, seed=7), "music": synth.music, "singing": synth.singing,
                 "speech": synth.speech, "siren": synth.siren, "bangs": synth.bangs}[rest]
        x = scene()
        x = x[0] if isinstance(x, tuple) else x
        return np.asarray(x[: int(SECONDS * SR)], dtype=float)
    sid, off = rest.split("@")
    _, x, sr = corpus.load(sid)
    i = int(float(off) * sr)
    return np.asarray(x[i: i + int(SECONDS * SR)], dtype=float)


def build(clip: Clip):
    """(audio, pass or None, truth curves)."""
    x = load_background(clip.background)
    if clip.snr is None:
        return x, None, []
    rng = np.random.default_rng(clip.seed)
    p = passes.draw(rng, SECONDS)
    y, truth = passes.mix(x, SR, p, clip.snr, rng)
    return y, p, truth


def matches(box: tuple[float, float, float, float], truth) -> bool:
    """Does a (t0, t1, f_lo, f_hi) box follow one of the tones?"""
    t0, t1, lo, hi = box
    if t1 <= t0:
        return False
    for g, f, lvl in truth:
        k = (g >= t0) & (g <= t1)
        if k.sum() < 10:
            continue
        on = (f[k] >= 0.97 * lo) & (f[k] <= 1.03 * hi) & (lvl[k] > -25)
        if on.mean() >= 0.5:
            return True
    return False


# --- detectors -------------------------------------------------------------------------------

def run_check(path: Path) -> list[tuple]:
    out = subprocess.run([str(CLI), "analyze", str(path), "--json"], capture_output=True, text=True, check=True).stdout
    tracks = json.loads(out)["tracks"]
    return [(t["start"], t["start"] + t["duration"], t["minFrequency"], t["maxFrequency"]) for t in tracks if t["kind"] == "doppler"]


_NULL = None


def run_blind(x: np.ndarray) -> list[tuple]:
    global _NULL
    from .common import null
    p = detect.Params()
    if _NULL is None:
        _NULL = null(p)
    f, t, L = detect.whiten(x, SR, p)
    out = []
    dt = float(t[1] - t[0])
    for w in detect.search(f, t, L - _NULL["mu"], p):
        if not np.isfinite(w.score):
            continue
        z = (w.score - _NULL["mean"]) / _NULL["sd"]
        if z >= BLIND_Z and detect.shape_test(w.path, p.win_s, dt=dt)["ok"]:
            out.append((w.start, w.start + p.win_s, float(w.path.min()), float(w.path.max())))
    return out


def run_known(x: np.ndarray, p: passes.Pass) -> float:
    """The known-path attacker's z for this pass's geometry (rest frequency free)."""
    kp = detect.Params(band=(80.0, 4000.0), broadband_aware=True)
    f, t, L = detect.whiten(x, SR, kp)
    factor = lambda tt: passes.geometry(p, np.asarray(tt))[0]
    win = (max(0.0, p.t_close - 25), min(SECONDS, p.t_close + 25))
    # The timing is exact here (the curve is the truth), so ±2 s of slack is plenty.
    z, _, _, _ = detect.known_path_z(f, t, L - L.mean(), factor, np.arange(100, 3500, 2.0), win, np.arange(-2, 2.01, 0.5),
                                    shifts=tuple(s * d for d in np.arange(20.0, 60.1, 5.0) for s in (-1, 1)))
    return z


def evaluate(clip: Clip) -> dict:
    import soundfile as sf
    x, p, truth = build(clip)
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "clip.wav"
        sf.write(path, x.astype(np.float32), SR, subtype="FLOAT")
        check = run_check(path)
    blind = run_blind(x)
    row = {"key": clip.key(), "background": clip.background, "snr": clip.snr, "seed": clip.seed,
           "check": [matches(b, truth) for b in check], "blind": [matches(b, truth) for b in blind]}
    if p is not None:
        row["pass"] = p.to_dict()
        row["known_z"] = run_known(x, p)
    return row


def plan(snrs=(6, 9, 12, 15, 18, 21), per_snr: int = 16, real: bool = True) -> list[Clip]:
    """Positives spread over the backgrounds, then every background alone."""
    bgs = backgrounds(real)
    clips = []
    for si, snr in enumerate(snrs):
        for i in range(per_snr):
            seed = 10_000 * si + i
            clips.append(Clip(bgs[(seed * 7 + i) % len(bgs)], float(snr), seed))
    clips += [Clip(b, None, 0) for b in bgs]
    return clips


def run(clips: list[Clip], workers: int = 2, results: Path | None = None) -> list[dict]:
    """Evaluate clips (on `workers` processes), reusing results already saved for the same key."""
    from multiprocessing import Pool
    results = results or corpus.DATA / "results" / "bench.jsonl"
    results.parent.mkdir(parents=True, exist_ok=True)
    done = {}
    if results.exists():
        for line in open(results):
            r = json.loads(line)
            done[r["key"]] = r
    todo = [c for c in clips if c.key() not in done]
    if todo:
        with Pool(workers) as pool, open(results, "a") as f:
            for r in pool.imap_unordered(evaluate, todo):
                f.write(json.dumps(r) + "\n")
                f.flush()
                done[r["key"]] = r
    return [done[c.key()] for c in clips]


def summarize(rows: list[dict]) -> str:
    """Markdown: detection rate by strength, and false alarms per hour on real and synthetic
    backgrounds."""
    pos = [r for r in rows if r["snr"] is not None]
    neg = [r for r in rows if r["snr"] is None]
    snrs = sorted({r["snr"] for r in pos})
    lines = ["| strength (dB/Hz) | clips | check | blind (E2) | known path (z ≥ 5) |", "| ---: | ---: | ---: | ---: | ---: |"]
    for s in snrs:
        rs = [r for r in pos if r["snr"] == s]
        pct = lambda k: 100 * np.mean([any(r[k]) for r in rs])
        kn = 100 * np.mean([(r.get("known_z") or -99) >= KNOWN_Z for r in rs])
        lines.append(f"| {s:.0f} | {len(rs)} | {pct('check'):.0f} % | {pct('blind'):.0f} % | {kn:.0f} % |")
    lines.append("")
    lines.append("| false alarms | audio | check | blind (E2) |")
    lines.append("| --- | ---: | ---: | ---: |")
    for label, sel in [("real plane-free backgrounds", lambda r: r["background"].startswith("session:")),
                       ("synthetic scenes", lambda r: r["background"].startswith("synth:")),
                       ("beside a pass (not on it)", None)]:
        if sel is None:
            fa = lambda k: sum(sum(1 for m in r[k] if not m) for r in pos)
            hours = len(pos) * SECONDS / 3600
            lines.append(f"| {label} | {len(pos) * SECONDS / 60:.0f} min | {fa('check') / hours:.1f} /h | {fa('blind') / hours:.1f} /h |")
            continue
        rs = [r for r in neg if sel(r)]
        if not rs:
            continue
        hours = len(rs) * SECONDS / 3600
        fa = lambda k: sum(len(r[k]) for r in rs)
        lines.append(f"| {label} | {len(rs) * SECONDS / 60:.0f} min | {fa('check')} ({fa('check') / hours:.1f} /h) | {fa('blind')} ({fa('blind') / hours:.1f} /h) |")
    return "\n".join(lines)


# --- the learned detector on the same clips ----------------------------------------------------

def ml_windows(clips: list[Clip], model: Path, results: Path | None = None) -> dict:
    """The learned detector's windows (lab/ml.py `windows`) on benchmark clips, cached by clip
    and model: {clip key: (windows, truth match per window)}. Thresholds and grouping are applied
    afterwards, so trying a rule costs nothing."""
    from . import ml
    results = results or corpus.DATA / "results" / f"bench-ml-{model.stem}.jsonl"
    done = {}
    if results.exists():
        for line in open(results):
            r = json.loads(line)
            done[r["clip"]] = r
    params = ml.load(model)
    with open(results, "a") as f:
        for c in clips:
            if c.key() not in done:
                x, _, truth = build(c)
                wins = ml.windows(params, x, SR)
                done[c.key()] = {"clip": c.key(), "windows": wins, "truth": truth and [[g.tolist()[::50], fr.tolist()[::50], lv.tolist()[::50]] for g, fr, lv in truth]}
                f.write(json.dumps(done[c.key()]) + "\n")
                f.flush()
    return done


def ml_rows(clips: list[Clip], wins: dict, threshold: float, min_windows: int = 2) -> list[dict]:
    """The learned detector's passes on each clip at a threshold, matched against the truth."""
    from . import ml
    out = []
    for c in clips:
        r = wins[c.key()]
        truth = [(np.array(g), np.array(f), np.array(l)) for g, f, l in (r["truth"] or [])]
        out.append({"clip": c.key(), "ml": [matches(tuple(p[:4]), truth) for p in ml.group([tuple(w) for w in r["windows"]], threshold, min_windows)]})
    return out


def compare(rows: list[dict], mlrows: list[dict], keep) -> str:
    """Markdown: every detector on the clips `keep` selects (e.g. the ML test backgrounds)."""
    by = {r["clip"]: r["ml"] for r in mlrows}
    rows = [dict(r, ml=by[r["key"]]) for r in rows if keep(r) and r["key"] in by]
    pos = [r for r in rows if r["snr"] is not None]
    neg = [r for r in rows if r["snr"] is None]
    lines = ["| strength (dB/Hz) | clips | check | blind (E2) | learned | known path |", "| ---: | ---: | ---: | ---: | ---: | ---: |"]
    for s in sorted({r["snr"] for r in pos}):
        rs = [r for r in pos if r["snr"] == s]
        pct = lambda k: 100 * np.mean([any(r[k]) for r in rs])
        kn = 100 * np.mean([(r.get("known_z") or -99) >= KNOWN_Z for r in rs])
        lines.append(f"| {s:.0f} | {len(rs)} | {pct('check'):.0f} % | {pct('blind'):.0f} % | {pct('ml'):.0f} % | {kn:.0f} % |")
    hours_neg = len(neg) * SECONDS / 3600
    hours_pos = len(pos) * SECONDS / 3600
    fa_neg = lambda k: sum(len(r[k]) for r in neg)
    fa_pos = lambda k: sum(sum(1 for m in r[k] if not m) for r in pos)
    lines += ["", "| false alarms | check | blind (E2) | learned |", "| --- | ---: | ---: | ---: |",
              f"| backgrounds alone ({len(neg)} min) | " + " | ".join(f"{fa_neg(k)} ({fa_neg(k) / max(hours_neg, 1e-9):.1f} /h)" for k in ("check", "blind", "ml")) + " |",
              f"| beside a pass ({len(pos)} min) | " + " | ".join(f"{fa_pos(k) / max(hours_pos, 1e-9):.1f} /h" for k in ("check", "blind", "ml")) + " |"]
    return "\n".join(lines)
