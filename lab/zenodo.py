"""The public 40-flight corpus as a holdout for tone removal (docs/EXPERIMENTS.md, "The public
corpus").

Pathak, P. (2026). Aeroplane data full analysis and raw files. Zenodo, record 23424278. CC BY 4.0.
40 smartphone recordings of aircraft passing over one place (May 2026), each with the audio, a
hand-traced frequency curve of one engine harmonic (UTC times) and the ADS-B track. Downloaded into
$LAB_DATA/external/zenodo-23424278 (never the repo or CI).

The recorder's position isn't published, and this code never tries to recover it (the tracks and
the published distances could be combined to do so; that would locate a private person's
recording spot, which is the attack this project defends against). So it scores tones, not places:
the traced curve is the tone's real path, a stronger attacker than any curve predicted from tracks.

Per pass: the traced curve becomes a shape (frequency over its median), extended flat beyond its
ends (a tone holds its pitch before and after a pass); the audio's start isn't recorded either, so
the curve is placed by the dataset's own layout (OFFSET_S).
The score is the place search's own (lab/locate.py): the best mean whitened excess along the shape
over every rest frequency, near the steepest fall, against the same curve at six wrong times.
"""
from __future__ import annotations

import csv
import datetime as dt
import json
import subprocess
from pathlib import Path

import numpy as np
import soundfile as sf

from . import corpus, locate

ROOT = corpus.DATA / "external" / "zenodo-23424278"
CITATION = "Pathak, P. (2026). Aeroplane data full analysis and raw files. Zenodo, record 23424278. CC BY 4.0."


def _utc(s: str) -> float:
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def passes() -> list[dict]:
    """Every pass: case, category, audio path, traced curve (seconds from its first point, Hz)
    and the published closest slant distance and speed (for the blind check's fit)."""
    table = {r["case"]: r for r in csv.DictReader(open(ROOT / "raw" / "final_results_40_cases.csv"))}
    out = []
    for d in sorted((ROOT / "extracted").glob("*/*/*")):
        if "__MACOSX" in d.parts or not (d / "audio.wav").exists():
            continue
        rows = list(csv.DictReader(open(d / "frequency_vs_time_used.csv")))
        t = np.array([_utc(r["time_utc"]) for r in rows])
        f = np.array([float(r["frequency_hz"]) for r in rows])
        row = table.get(d.name, {})
        out.append({"case": d.name, "category": d.parent.name, "wav": str(d / "audio.wav"),
                    "t": t - t[0], "f": f,
                    "closest_m": float(row["R_ADSB_m"]) if row.get("R_ADSB_m") else None,
                    "speed_kmh": float(row["V_ADSB_at_closest_kmh"]) if row.get("V_ADSB_at_closest_kmh") else None})
    return out


def shape(p: dict) -> tuple[np.ndarray, np.ndarray, float]:
    """(times from the curve's start, factor = smoothed frequency over its median, time of the
    steepest fall)."""
    from scipy.ndimage import median_filter, uniform_filter1d
    # A traced ridge can jump to another line for a moment (one pass drops from ~300 to 61 Hz):
    # points more than 10 % from the running median over ~5 s, or outside 0.55–1.8 times the
    # curve's median (beyond any subsonic swing; a 150 m/s jet's real swing spans 1.25 kHz to
    # 512 Hz here), are dropped first.
    t, f = p["t"], p["f"]
    rel = f / np.median(f)
    keep = (np.abs(f / median_filter(f, 31, mode="nearest") - 1) <= 0.10) & (rel >= 0.55) & (rel <= 1.8)
    t, f = t[keep], f[keep]
    f = uniform_filter1d(median_filter(f, 9, mode="nearest"), 9, mode="nearest")
    fac = f / np.median(f)
    slope = np.gradient(uniform_filter1d(fac, 15, mode="nearest"), t)
    return t, fac, float(t[int(np.argmin(slope))])


def flat_interp(x, t, fac):
    """The shape at x, held at its end values beyond its ends."""
    return np.interp(x, t, fac)


# Where the traced curve starts in its audio. The files don't say, but each recording is the traced
# segment with 5 s either side: 34 of the 40 are exactly 10.0 s longer than their curve, and fitting
# each curve's absolute frequencies to its audio puts 13 within 0.1 s of 5.0 (median 4.95; the
# others' fits are broad, the traced tone being faint). Passes whose length breaks the pattern are
# left out rather than guessed.
OFFSET_S = 5.0


def half(case: str) -> str:
    """'tune' or 'holdout', fixed by the case id alone (a hash, so not by any result): about half
    of each category each way. Chosen after one look at all 35 (the only contamination)."""
    import hashlib
    return "tune" if int(hashlib.sha1(case.encode()).hexdigest(), 16) % 2 == 0 else "holdout"


def usable(p: dict) -> bool:
    """The audio is the traced segment plus 5 s either side (to within 0.5 s)."""
    return abs(sf.info(p["wav"]).duration - p["t"][-1] - 2 * OFFSET_S) <= 0.5


def z(scene: locate.Scene, p: dict, offset: float) -> tuple[float, float]:
    """(z, excess over the wrong-time mean) of the traced shape placed at `offset`. Wrong times
    use the flat extension, so a shift never leaves the curve undefined."""
    t, fac, tc = shape(p)
    times, tcl = t + offset, tc + offset
    j = np.flatnonzero(np.abs(scene.t - tcl) <= locate.HALF_WINDOW_S)
    s0 = scene._best(j, flat_interp(scene.t[j], times, fac))
    nulls = np.array([scene._best(j, flat_interp(scene.t[j] - d, times, fac)) for d in locate.NULL_SHIFTS_S])
    nulls = nulls[np.isfinite(nulls)]
    return float((s0 - nulls.mean()) / max(nulls.std(), 1e-3)), float(s0 - nulls.mean())


def expected_pass(p: dict, offset: float, duration: float) -> dict:
    """The traced shape as the engine's ExpectedPass (audio times, factors 0.5-2, closest
    approach), flat beyond its ends to cover the audio: removal with a perfect curve."""
    t, fac, tc = shape(p)
    grid = np.arange(-60.0, duration + 60.0, 0.1)
    return {"times": np.round(grid, 3).tolist(), "factors": np.round(flat_interp(grid - offset, t, fac), 7).tolist(),
            "closest": round(tc + offset, 3)}


def blind(path: str) -> dict:
    """The engine's blind check on a file: did it fit a flyby (a Doppler track), and its distance."""
    cli = Path(__file__).resolve().parent.parent / ".build/release/octave-camo"
    r = subprocess.run([str(cli), "analyze", path, "--json"], capture_output=True, text=True)
    try:
        d = json.loads(r.stdout)
    except json.JSONDecodeError:
        return {"doppler": None, "distance": None}
    dop = [tr for tr in d.get("tracks", []) if tr.get("kind") == "doppler"]
    return {"doppler": len(dop), "distance": (d.get("consensus") or {}).get("distance")}


def level_change(x: np.ndarray, y: np.ndarray, sr: int, lo: float = 300.0, hi: float = 4_000.0) -> float:
    """Mean absolute third-octave level change between two aligned audios, lo–hi Hz, dB."""
    from scipy.signal import stft
    n = min(len(x), len(y))
    edges = lo * 2 ** (np.arange(0, 12, 1 / 3)); edges = edges[edges <= hi]
    def levels(a):
        f, _, Z = stft(a[:n], sr, nperseg=4096, noverlap=3072)
        P = np.abs(Z) ** 2
        return np.array([10 * np.log10(P[(f >= a0) & (f < b0)].mean(0) + 1e-20) for a0, b0 in zip(edges[:-1], edges[1:])])
    return float(np.abs(levels(x) - levels(y)).mean())


def run_pass(p: dict, preset_args: dict, extra: list[str] | None = None) -> dict:
    """One pass: the original, Full, Experimental and Full with the traced curve as its expected
    pass (removal with a perfect curve), each scored along the traced curve; the blind check on the
    original and on Full; sound change above 300 Hz against the original."""
    import tempfile
    cli = Path(__file__).resolve().parent.parent / ".build/release/octave-camo"
    x, sr = sf.read(p["wav"])
    x = x if x.ndim == 1 else x[:, 0]
    out = {"case": p["case"], "category": p["category"], "closest_m": p["closest_m"], "speed_kmh": p["speed_kmh"],
           "median_hz": float(np.median(p["f"]))}
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "in.wav"
        sf.write(src, x, sr, subtype="FLOAT")
        exp = Path(tmp) / "expect.json"
        exp.write_text(json.dumps([expected_pass(p, OFFSET_S, len(x) / sr)]))
        variants = {"full": [*preset_args["full"]], "experimental": [*preset_args["experimental"]],
                    "full+tracks": [*preset_args["full"], "--expect", str(exp), *(extra or [])]}
        if extra:                                   # a sweep of removal settings: only that copy
            variants = {"full+tracks": variants["full+tracks"]}
        audios = {"original": (x, str(src))}
        for name, args in variants.items():
            dst = Path(tmp) / f"{name}.wav"
            r = subprocess.run([str(cli), "scrub", str(src), str(dst), *args, "--seed", "7"], capture_output=True, text=True)
            if r.returncode:
                out[f"{name}_error"] = (r.stderr or r.stdout)[:200]
                continue
            if name == "full+tracks":
                out["tracks_log"] = next((l.strip() for l in r.stderr.splitlines() if "tracks:" in l), "")
            y, _ = sf.read(dst)
            audios[name] = (y if y.ndim == 1 else y[:, 0], str(dst))
        for name, (y, path) in audios.items():
            sc = locate.Scene(y, sr, f"zenodo:{p['case']}:{name}")
            zz, eff = z(sc, p, OFFSET_S)
            out[name] = {"z": round(zz, 2), "excess": round(eff, 3)}
            if name != "original":
                out[name]["change_db"] = round(level_change(x, y, sr), 2)
            if name in ("original", "full") and not extra:
                out[name]["blind"] = blind(path)
    return out
