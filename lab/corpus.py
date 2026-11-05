"""The corpus: recorder sessions, each with the ground truth its own ADS-B log implies.

`ingest` unpacks a recorder bundle (zip) into the data folder and writes `index.json` next to it:
duration, mode, chirp onsets, labels, the speed of sound, and every airborne aircraft as a *pass*
(closest slant distance, when its sound arrives, speed, altitude, climb rate, type) plus its
predicted Doppler factor over the audio's time (`passes.npz`). Positions are turned into these
relative quantities and nothing else: the index holds no coordinates.

The data folder is outside the repo (`LAB_DATA`, default ~/.octave-camo-lab). Recordings carry a
precise location; they never go into the repo or CI.
"""
from __future__ import annotations

import json
import math
import os
import shutil
import zipfile
from collections import defaultdict
from pathlib import Path

import numpy as np
import soundfile as sf

DATA = Path(os.environ.get("LAB_DATA", Path.home() / ".octave-camo-lab"))


def sessions_dir() -> Path:
    d = DATA / "sessions"
    d.mkdir(parents=True, exist_ok=True)
    return d


def ingest(bundle: str | Path) -> str:
    """Unpack a recorder zip (or copy a session folder) and index it. Returns the session id."""
    bundle = Path(bundle)
    tmp = DATA / "incoming"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    if bundle.is_dir():
        shutil.copytree(bundle, tmp / bundle.name)
    else:
        with zipfile.ZipFile(bundle) as z:
            for m in z.infolist():
                target = (tmp / m.filename).resolve()
                if not str(target).startswith(str(tmp.resolve())):      # no path traversal
                    raise ValueError(f"unsafe path in archive: {m.filename}")
            z.extractall(tmp)
    metas = list(tmp.rglob("meta.json"))
    if len(metas) != 1:
        raise ValueError(f"expected one meta.json in {bundle}, found {len(metas)}")
    src = metas[0].parent
    sid = json.load(open(src / "meta.json")).get("clip_id") or src.name
    dst = sessions_dir() / sid
    shutil.rmtree(dst, ignore_errors=True)
    shutil.move(str(src), dst)
    shutil.rmtree(tmp, ignore_errors=True)
    index(sid)
    return sid


def _audio_start(meta: dict) -> float:
    t = meta["time"]
    if "audio_start_wall_unix" in t:
        return t["audio_start_wall_unix"]
    a = t["clock_anchor_start"]                     # older bundles: derive it from the anchors
    return a["wall_unix"] + meta["audio"]["first_buffer_mono_s"] - a["mono_s"]


def _chirps(meta: dict) -> list[float]:
    c = meta.get("chirp", {})
    if "events" in c:
        return [e["expected_onset_s_in_audio"] for e in c["events"]]
    return [c["expected_onset_s_in_audio"]] if "expected_onset_s_in_audio" in c else []


def _polls(path: Path) -> list[dict]:
    if path.suffix == ".jsonl":
        return [p for p in (json.loads(l) for l in open(path)) if "received_wall_unix" in p]
    p = json.load(open(path))
    return [p] if "received_wall_unix" in p else []


def index(sid: str) -> dict:
    d = sessions_dir() / sid
    meta = json.load(open(d / "meta.json"))
    info = sf.info(str(d / meta["audio"]["file"]))
    t0 = _audio_start(meta)
    temp = (meta.get("weather", {}).get("current", {}) or {}).get("temperature_2m")
    c = 331.3 + 0.606 * (temp if temp is not None else 15.0)
    loc = meta["location_at_start"]
    la0, lo0, alt0 = loc["lat"], loc["lon"], loc.get("alt_m") or 0.0

    tracks: dict[str, list] = defaultdict(list)
    kind: dict[str, dict] = {}
    for p in _polls(d / meta["aircraft"]["file"]):
        for e in p.get("aircraft") or []:
            if e.get("on_ground") or e.get("lat") is None or e.get("alt_ft") is None:
                continue
            X = math.radians(e["lon"] - lo0) * 6371000 * math.cos(math.radians(la0))
            Y = math.radians(e["lat"] - la0) * 6371000
            Z = e["alt_ft"] * 0.3048 - alt0
            ts = p["received_wall_unix"] - (e.get("seen_pos_s") or 0) - t0
            tracks[e["hex"]].append((round(ts, 2), X, Y, Z))
            kind[e["hex"]] = {"type": e.get("type"), "kt": e.get("ground_speed_kt"), "fpm": e.get("vertical_rate_fpm")}

    dur = info.frames / info.samplerate
    grid = np.arange(-30.0, dur + 30.0, 0.1)
    passes, curves = [], {}
    for h, pts in tracks.items():
        a = np.array(sorted(set(pts)))
        _, u = np.unique(a[:, 0], return_index=True)
        a = a[u]
        if len(a) < 2:
            continue
        te = np.arange(a[0, 0], a[-1, 0], 0.1)
        q = np.stack([np.interp(te, a[:, 0], a[:, j]) for j in (1, 2, 3)], 1)
        r = np.linalg.norm(q, axis=1)
        # Positions come every ~10 s with ~tens of metres of noise, so the velocity of a linear
        # interpolation is jagged: smooth it over 20 s (a local, not whole-track, smoothing).
        from scipy.ndimage import uniform_filter1d
        v = uniform_filter1d(np.gradient(q, te, axis=0), size=201, axis=0, mode="nearest")
        vr = (q * v).sum(1) / r                           # + receding
        heard = te + r / c
        factor = 1 / (1 + vr / c)                         # received / emitted frequency
        level = -20 * np.log10(r)
        i = int(np.argmin(r))
        inside = (heard >= 0) & (heard <= dur)
        if not inside.any():
            continue
        passes.append({
            "hex": h, **kind[h], "closest_km": round(float(r[i]) / 1000, 2), "heard_s": round(float(heard[i]), 1),
            "alt_ft": round(float(q[i, 2] + alt0) / 0.3048), "elevation_deg": round(math.degrees(math.asin(q[i, 2] / r[i])), 1),
            "speed_mps": round(float(np.linalg.norm(v[i])), 1), "heard_span_s": [round(float(heard[inside].min()), 1), round(float(heard[inside].max()), 1)],
            "closest_in_audio_km": round(float(r[inside].min()) / 1000, 2),
        })
        curves[h] = np.stack([np.interp(grid, heard, factor, left=np.nan, right=np.nan),
                              np.interp(grid, heard, level, left=np.nan, right=np.nan)])
    passes.sort(key=lambda p: p["closest_in_audio_km"])
    idx = {
        "id": sid, "schema": meta.get("schema_version") or meta.get("format_version"),
        "duration_s": round(dur, 2), "sample_rate": info.samplerate, "channels": info.channels,
        "mode": meta["audio_session"].get("mode"), "chirps_s": _chirps(meta),
        "note": (meta.get("label") or {}).get("note", ""), "speed_of_sound": round(c, 1),
        "markers": _markers(d, t0), "manifest": verify(d), "context": meta.get("context", {}), "passes": passes,
    }
    json.dump(idx, open(d / "index.json", "w"), indent=1)
    np.savez_compressed(d / "passes.npz", grid=grid, **{h: v for h, v in curves.items()})
    return idx


def _markers(d: Path, t0: float) -> list:
    """Tap-to-mark labels on the audio's own timeline (seconds from its first sample)."""
    f = d / "markers.jsonl"
    if not f.exists():
        return []
    return [{"label": m.get("label"), "t_s": round(m["wall_unix"] - t0, 2)} for m in (json.loads(l) for l in open(f)) if "wall_unix" in m]


def verify(d: Path) -> str:
    """Check manifest.json's SHA-256s, when the bundle has one: 'ok', 'no manifest', or what's wrong."""
    import hashlib
    f = d / "manifest.json"
    if not f.exists():
        return "no manifest"
    m = json.load(open(f))
    bad = []
    for e in m.get("files", []):
        p = d / e["path"]
        if not p.exists():
            bad.append(f"missing {e['path']}")
        elif hashlib.sha256(p.read_bytes()).hexdigest() != e["sha256"]:
            bad.append(f"hash mismatch {e['path']}")
    return "ok" if not bad else "; ".join(bad)


def load(sid: str) -> tuple[dict, np.ndarray, int]:
    """(index, mono audio: the omni channel of a multichannel file, sample rate)."""
    d = sessions_dir() / sid
    idx = json.load(open(d / "index.json"))
    meta = json.load(open(d / "meta.json"))
    x, sr = sf.read(str(d / meta["audio"]["file"]))
    return idx, (x[:, 0] if x.ndim > 1 else x), sr


def curve(sid: str, hexid: str):
    """(time grid, Doppler factor, relative level in dB) for one aircraft, NaN outside its span."""
    z = np.load(sessions_dir() / sid / "passes.npz")
    return z["grid"], z[hexid][0], z[hexid][1]


def all_ids() -> list[str]:
    return sorted(p.name for p in sessions_dir().iterdir() if (p / "index.json").exists())
