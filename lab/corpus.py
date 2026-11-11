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
import re
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


SAFE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}")


def session_path(sid: str) -> Path:
    """The folder for a session id, which must be a plain name (letters, digits, '-' and '_'): an
    id from a bundle's meta.json never reaches outside the sessions folder ('../x', '/tmp/x')."""
    if not isinstance(sid, str) or not SAFE_ID.fullmatch(sid):
        raise ValueError(f"unsafe session id: {sid!r}")
    root = sessions_dir().resolve()
    d = (root / sid).resolve()
    if d.parent != root:
        raise ValueError(f"unsafe session id: {sid!r}")
    return d


def ingest(bundle: str | Path) -> str:
    """Unpack a recorder zip (or copy a session folder) and index it. Returns the session id.
    The id is checked before anything is touched, and an existing session with the same id is only
    replaced once the new one has been indexed (restored if indexing fails)."""
    bundle = Path(bundle)
    tmp = DATA / "incoming"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    if bundle.is_dir():
        shutil.copytree(bundle, tmp / bundle.name)
    else:
        with zipfile.ZipFile(bundle) as z:
            for m in z.infolist():
                if not (tmp / m.filename).resolve().is_relative_to(tmp.resolve()):   # no path traversal
                    raise ValueError(f"unsafe path in archive: {m.filename}")
            z.extractall(tmp)
    metas = list(tmp.rglob("meta.json"))
    if len(metas) != 1:
        raise ValueError(f"expected one meta.json in {bundle}, found {len(metas)}")
    src = metas[0].parent
    sid = json.load(open(src / "meta.json")).get("clip_id") or src.name
    dst = session_path(sid)
    old = dst.with_name(f".replaced-{sid}")
    shutil.rmtree(old, ignore_errors=True)
    if dst.exists():
        dst.rename(old)
    shutil.move(str(src), dst)
    try:
        index(sid)
    except Exception:
        shutil.rmtree(dst, ignore_errors=True)
        if old.exists():
            old.rename(dst)
        raise
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    shutil.rmtree(old, ignore_errors=True)
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


def geometry(sid: str) -> dict:
    """Each aircraft's track in the session's local frame (metres east, north, up from the
    recording position; never printed or saved), 10 Hz from first to last position, with its
    smoothed velocity. Returns {speed_of_sound, duration_s, alt0, meta, info, kind, tracks: {hex:
    (te, q, v)}}, `te` in seconds from the audio's start."""
    d = sessions_dir() / sid
    meta = json.load(open(d / "meta.json"))
    info = sf.info(str(d / meta["audio"]["file"]))
    t0 = _audio_start(meta)
    temp = (meta.get("weather", {}).get("current", {}) or {}).get("temperature_2m")
    c = 331.3 + 0.606 * (temp if temp is not None else 15.0)
    loc = meta["location_at_start"]
    la0, lo0 = loc["lat"], loc["lon"]
    alt0, alt_ref = vertical_reference(meta)

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

    bf = d / "adsb_backfill.jsonl"
    if bf.exists():                                       # positions fetched by backfill(), same frame
        for r in (json.loads(l) for l in open(bf)):
            if r["alt_ft"] is None or not _plausible(r["lat"], r["lon"], r["alt_ft"]):
                continue                                  # saved before rows were checked
            X = math.radians(r["lon"] - lo0) * 6371000 * math.cos(math.radians(la0))
            Y = math.radians(r["lat"] - la0) * 6371000
            tracks[r["hex"]].append((round(r["wall_unix"] - t0, 2), X, Y, r["alt_ft"] * 0.3048 - alt0))
            kind.setdefault(r["hex"], {"type": None, "kt": None, "fpm": None})
    tr = {}
    for h, pts in tracks.items():
        a = np.array(sorted(set(pts)))
        _, u = np.unique(a[:, 0], return_index=True)
        a = a[u]
        if len(a) < 2:
            continue
        te = np.arange(a[0, 0], a[-1, 0], 0.1)
        if len(te) < 3:                                   # two fixes a moment apart: no velocity
            continue
        q = np.stack([np.interp(te, a[:, 0], a[:, j]) for j in (1, 2, 3)], 1)
        # Positions come every ~10 s with ~tens of metres of noise, so the velocity of a linear
        # interpolation is jagged: smooth it over 20 s (a local, not whole-track, smoothing).
        from scipy.ndimage import uniform_filter1d
        v = uniform_filter1d(np.gradient(q, te, axis=0), size=201, axis=0, mode="nearest")
        tr[h] = (te, q, v)
    return {"speed_of_sound": c, "duration_s": info.frames / info.samplerate, "alt0": alt0, "alt_ref": alt_ref,
            "meta": meta, "info": info, "kind": kind, "tracks": tr}


def pressure_altitude_m(kpa: float) -> float:
    """Altitude in the standard atmosphere for a pressure, m (ICAO; 101.325 kPa at 0 m)."""
    return 44_330.8 * (1 - (kpa / 101.325) ** 0.190263)


def vertical_reference(meta: dict) -> tuple[float, str]:
    """The recording's height on the scale ADS-B reports aircraft on. ADS-B altitude is barometric
    (pressure altitude, 1013.25 hPa), so the phone's own pressure, read the same way, cancels the
    day's sea-level pressure; GPS height (often ±10–80 m vertically) is the fallback."""
    p = (meta.get("pressure_at_start") or {}).get("pressure_kpa")
    if p:
        return pressure_altitude_m(p), "pressure"
    return (meta["location_at_start"].get("alt_m") or 0.0), "gps"


def index(sid: str) -> dict:
    d = sessions_dir() / sid
    g = geometry(sid)
    meta, info, kind, alt0, c = g["meta"], g["info"], g["kind"], g["alt0"], g["speed_of_sound"]
    t0 = _audio_start(meta)
    dur = info.frames / info.samplerate
    grid = np.arange(-120.0, dur + 120.0, 0.1)          # wide enough for curves moved 60 s for nulls
    passes, curves = [], {}
    for h, (te, q, v) in g["tracks"].items():
        r = np.linalg.norm(q, axis=1)
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
        "mode": meta["audio_session"].get("mode"), "chirps_s": _chirps(meta), "altitude_reference": g["alt_ref"],
        "note": (meta.get("label") or {}).get("note", ""), "speed_of_sound": round(c, 1),
        "markers": _markers(d, t0), "manifest": verify(d), "context": {**meta.get("context", {}), **_corrections(d).get("context", {})}, "passes": passes,
    }
    json.dump(idx, open(d / "index.json", "w"), indent=1)
    np.savez_compressed(d / "passes.npz", grid=grid, **{h: v for h, v in curves.items()})
    return idx


def _corrections(d: Path) -> dict:
    """Local fixes to a session's labels (corrections.json, set with `python3 -m lab label`)."""
    f = d / "corrections.json"
    return json.load(open(f)) if f.exists() else {}


def correct(sid: str, **context) -> dict:
    """Override context fields (environment=outdoor, note=…) for one session, kept beside it."""
    d = sessions_dir() / sid
    c = _corrections(d)
    c.setdefault("context", {}).update(context)
    json.dump(c, open(d / "corrections.json", "w"), indent=1)
    return index(sid)


ADSB = "https://adsb.lol"
HEADERS = {"User-Agent": "octave-camo-lab (research; https://github.com/asleepace/octave-camo)"}


def _get(url: str, cache: Path, keep: bool = True) -> bytes | None:
    """GET with an on-disk cache; None on 404 or network failure. Written to a temporary name and
    renamed, so a second job never reads a half-written file (two at once read a truncated
    archive once). `keep=False` fetches without caching (data that isn't final yet)."""
    import os
    import urllib.error
    import urllib.request
    if cache.exists():
        return cache.read_bytes()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=60) as r:
            data = r.read()
    except (urllib.error.URLError, TimeoutError):
        return None
    if keep:
        cache.parent.mkdir(parents=True, exist_ok=True)
        part = cache.with_name(f"{cache.name}.{os.getpid()}.part")
        part.write_bytes(data)
        os.replace(part, cache)
    return data


def _plausible(lat: float, lon: float, alt_ft: float | None) -> bool:
    return abs(lat) <= 90 and abs(lon) <= 180 and (alt_ft is None or -2_000 <= alt_ft <= 60_000)


def _heatmap(day: str, half_hour: int) -> list[tuple]:
    """Every aircraft position in adsb.lol's archive for one half hour (UTC), every 10 s:
    (unix s, hex, lat, lon, alt ft or None on the ground). Records are four int32: id, lat·1e6,
    lon·1e6, altitude (25 ft units, −123 = ground) | ground speed·10 << 16, with a marker row
    (id 0xe7f7c9d) giving the time in ms before each 10 s block."""
    import gzip
    y, m, dd = day.split("-")
    raw = _get(f"{ADSB}/globe_history/{y}/{m}/{dd}/heatmap/{half_hour:02d}.bin.ttf", DATA / "adsb" / "heatmap" / f"{day}-{half_hour:02d}.bin")
    if raw is None:
        return []
    a = np.frombuffer(gzip.decompress(raw) if raw[:2] == b"\x1f\x8b" else raw, dtype="<i4")
    a = a[: len(a) // 4 * 4].reshape(-1, 4)
    marks = np.flatnonzero(a[:, 0] == 0xE7F7C9D)
    out = []
    for i, m0 in enumerate(marks):
        ts = ((int(a[m0, 1]) << 32) + (int(a[m0, 2]) & 0xFFFFFFFF)) / 1000.0
        rows = a[m0 + 1: marks[i + 1] if i + 1 < len(marks) else len(a)]
        rows = rows[(rows[:, 0] >= 0) & (rows[:, 0] < (1 << 24))]
        for h, la, lo, packed in rows:
            alt = int(np.int16(packed & 0xFFFF))
            if not _plausible(la / 1e6, lo / 1e6, None if alt == -123 else alt * 25):
                continue                                  # not a position row (e.g. a callsign)
            out.append((ts, f"{int(h):06x}", la / 1e6, lo / 1e6, None if alt == -123 else alt * 25))
    return out


def half_hours(t_lo: float, t_hi: float) -> list[tuple["datetime.datetime", int]]:
    """Every UTC half hour that [t_lo, t_hi] touches, as (that half hour's UTC midnight, index
    0-47), each with its own date: a recording across midnight gets yesterday's 47 and today's 0,
    a long one every half hour in between."""
    import datetime
    out = []
    for k in range(int(t_lo // 1800), int(t_hi // 1800) + 1):
        start = datetime.datetime.fromtimestamp(k * 1800, datetime.timezone.utc)
        midnight = start.replace(hour=0, minute=0, second=0, microsecond=0)
        out.append((midnight, (start.hour * 60 + start.minute) // 30))
    return out


def archive_files(sid: str, margin_s: float = 240) -> tuple[list[Path], str, float]:
    """The half-hour archive files covering a session (fetched and cached), and the CLI's
    --at (lat,lon,alt on the pressure scale) and --start for it. Never printed."""
    import datetime
    d = sessions_dir() / sid
    meta = json.load(open(d / "meta.json"))
    t0 = _audio_start(meta)
    t1 = t0 + sf.info(str(d / meta["audio"]["file"])).duration
    loc = meta["location_at_start"]
    alt0, _ = vertical_reference(meta)
    files = []
    for day, hh in half_hours(t0 - margin_s, t1 + margin_s):
        t = day.timestamp() + hh * 1800
        f = DATA / "adsb" / "heatmap" / f"{day:%Y-%m-%d}-{hh:02d}.bin"
        # A half hour fetched before it ended (plus ten minutes for adsb.lol to write it) is
        # incomplete: use it, but don't keep it in the cache as if it were final.
        final = datetime.datetime.now(datetime.timezone.utc).timestamp() > (t // 1800 + 1) * 1800 + 600
        url = f"{ADSB}/globe_history/{day:%Y/%m/%d}/heatmap/{hh:02d}.bin.ttf"
        tmp = DATA / "adsb" / "heatmap" / "unfinished" / f.name
        if f in files or tmp in files:
            continue
        if f.exists() or (final and _get(url, f) is not None):
            files.append(f)
        elif not final and (data := _get(url, f, keep=False)) is not None:
            tmp.parent.mkdir(parents=True, exist_ok=True)
            tmp.write_bytes(data)
            files.append(tmp)
    return files, f"{loc['lat']},{loc['lon']},{alt0:.1f}", t0


def backfill(sid: str, before_s: float = 240, after_s: float = 240, radius_km: float = 40) -> int:
    """Fetch positions from before the first poll (and after the last) for every aircraft the
    session's own polls saw within `radius_km`: today's full-resolution traces when the session is
    from today (UTC), else the 10 s archive. Saved beside the session (adsb_backfill.jsonl) and
    merged into the index. Returns how many positions were added."""
    import datetime
    import time as _time
    d = sessions_dir() / sid
    meta = json.load(open(d / "meta.json"))
    t0 = _audio_start(meta)
    t1 = t0 + sf.info(str(d / meta["audio"]["file"])).duration
    loc = meta["location_at_start"]
    la0, lo0 = loc["lat"], loc["lon"]
    hexes = set()
    for p in _polls(d / meta["aircraft"]["file"]):
        for e in p.get("aircraft") or []:
            if e.get("on_ground") or e.get("lat") is None:
                continue
            dx = math.radians(e["lon"] - lo0) * 6371 * math.cos(math.radians(la0))
            dy = math.radians(e["lat"] - la0) * 6371
            if math.hypot(dx, dy) <= radius_km:
                hexes.add(e["hex"])
    lo_t, hi_t = t0 - before_s, t1 + after_s
    rows = []
    day = datetime.datetime.fromtimestamp(t0, datetime.timezone.utc)
    today = datetime.datetime.now(datetime.timezone.utc).date() == day.date()
    if today:
        for h in sorted(hexes):
            raw = _get(f"{ADSB}/data/traces/{h[-2:]}/trace_full_{h}.json", DATA / "adsb" / "traces" / day.strftime("%Y-%m-%d") / f"{h}.json")
            _time.sleep(0.3)
            if raw is None:
                continue
            import gzip
            tr = json.loads(gzip.decompress(raw) if raw[:2] == b"\x1f\x8b" else raw)
            for e in tr.get("trace", []):
                ts = tr["timestamp"] + e[0]
                if lo_t <= ts <= hi_t and e[3] not in ("ground", None):
                    rows.append({"hex": h, "wall_unix": ts, "lat": e[1], "lon": e[2], "alt_ft": e[3]})
    if not rows:                                         # older sessions (or traces unavailable): the archive
        for hday, hh in half_hours(lo_t, hi_t):
            for ts, h, la, lo, alt in _heatmap(hday.strftime("%Y-%m-%d"), hh):
                if h in hexes and lo_t <= ts <= hi_t and alt is not None:
                    rows.append({"hex": h, "wall_unix": ts, "lat": la, "lon": lo, "alt_ft": alt})
    with open(d / "adsb_backfill.jsonl", "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    index(sid)
    return len(rows)


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


# Held out (by id suffix): never used to choose a threshold, a parameter or a stopping rule, only
# scored once a change is settled (docs/EXPERIMENTS.md, "The holdout"). Two of the seven sessions
# whose original gives the place away, chosen 2026-11-06 after one look at their place-search
# results (that look is the only contamination). The public corpus joins when it's ingested.
HOLDOUT = ("af39e1", "f8b75a")


def is_holdout(sid: str) -> bool:
    return sid.endswith(HOLDOUT)


def all_ids(holdout: bool = False) -> list[str]:
    """Every session's id; the holdout only when asked for."""
    ids = sorted(p.name for p in sessions_dir().iterdir() if (p / "index.json").exists())
    return ids if holdout else [s for s in ids if not is_holdout(s)]
