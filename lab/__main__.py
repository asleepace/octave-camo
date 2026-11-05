"""octave-camo lab: python3 -m lab <command> …   (run from the repo root)

  ingest <bundle.zip | session dir> …   unpack recorder sessions into $LAB_DATA and index them
  sessions                              list sessions and their nearest aircraft passes
  label <session> key=value …           correct a session's context labels (kept locally)
  backfill <session | all>              fetch aircraft positions from before the first poll (adsb.lol)
  e2 [synth|real|all|files] [x.wav …] [--wide]
                                        the E2 detector + shape test over scenes and wav files (both cores)
  cloak <session> [preset …]            cloak with the real wasm build (full, experimental, light),
                                        into $LAB_DATA/cloaked/<session>-<preset>.wav
  attack <session> [audio …]            the known-path attacker on the session (and on other
                                        audio of it, e.g. cloaked copies, aligned automatically)
  check <session> [audio …]             the page's check (the real wasm build) on the session and
                                        on other audio of it: counts and flyby passes
  locate <session> [audio …]            the place-searching attacker: rank of the true position
                                        among a grid of candidates (distances and areas only)
  plot <session>                        spectrogram with ADS-B Doppler curves and detected paths

Data stays in $LAB_DATA (default ~/.octave-camo-lab), never in the repo. Results are saved as JSON
in $LAB_DATA/results and printed as markdown tables.
"""
from __future__ import annotations

import hashlib
import json
import sys
import time
from multiprocessing import Pool

import numpy as np

from . import corpus, detect, synth

P = detect.Params()
# Windows below this z aren't fitted (they can't be detections).
MIN_Z_TO_FIT = 3.0


def _cache_key(name: str, p: detect.Params, x: np.ndarray) -> str:
    # The audio's own bytes are part of the key: a re-cloaked file keeps its name.
    h = hashlib.sha1(f"{name}|{p}|{len(x)}".encode())
    h.update(np.ascontiguousarray(x, dtype=np.float32).tobytes())
    return h.hexdigest()[:16]


def whitened(name: str, x: np.ndarray, sr: int, p: detect.Params):
    """whiten(), cached on disk by scene name, parameters and the audio itself."""
    d = corpus.DATA / "cache"
    d.mkdir(parents=True, exist_ok=True)
    f = d / f"{_cache_key(name, p, x)}.npz"
    if f.exists():
        z = np.load(f)
        return z["f"], z["t"], z["L"]
    fr, t, L = detect.whiten(x, sr, p)
    np.savez(f, f=fr, t=t, L=L.astype(np.float32))
    return fr, t, L


def null(p: detect.Params) -> dict:
    """Mean excess and the path-score distribution on synthetic room noise (cached per params)."""
    d = corpus.DATA / "cache"
    d.mkdir(parents=True, exist_ok=True)
    f = d / f"null-{_cache_key('null', p, np.zeros(0))}.json"
    if f.exists():
        return json.load(open(f))
    x = synth.room(120, seed=101)
    fr, t, L = detect.whiten(x, synth.SR, p)
    mu = float(L.mean())
    sc = np.array([w.score for w in detect.search(fr, t, L - mu, p)])
    out = {"mu": mu, "mean": float(sc.mean()), "sd": float(sc.std())}
    json.dump(out, open(f, "w"))
    return out


def run_scene(args):
    name, kind, p = args
    if kind == "synth":
        x, _ = synth.SCENES[name]()
        sr, skip = synth.SR, ()
    elif kind == "file":                       # any wav, e.g. a cloaked session; chirps from its session if named <session>-<preset>.wav
        import soundfile as sf
        from pathlib import Path
        x, sr = sf.read(name)
        x = x[:, 0] if x.ndim > 1 else x
        sid = Path(name).stem.rsplit("-", 1)[0]
        try:
            skip = tuple(json.load(open(corpus.sessions_dir() / sid / "index.json"))["chirps_s"])
        except FileNotFoundError:
            skip = ()
    else:
        idx, x, sr = corpus.load(name)
        skip = tuple(idx["chirps_s"])
    nl = null(p)
    fr, t, L = whitened(name, x, sr, p)
    wins = detect.search(fr, t, L - nl["mu"], p, skip)
    rows = []
    for w in wins:
        if not np.isfinite(w.score):
            continue
        w.z = (w.score - nl["mean"]) / nl["sd"]
        # Only a window that stands out is worth the fit (27 multi-start least squares).
        w.fit = detect.shape_test(w.path, p.win_s) if w.z >= MIN_Z_TO_FIT else {"ok": False}
        rows.append({"start": w.start, "z": round(w.z, 2), "from_hz": round(float(w.path[0])), "to_hz": round(float(w.path[-1])), **w.fit})
    return name, kind, rows


def cmd_e2(which: str, wide: bool, files: list[str] = ()):
    p = detect.Params(band=(600.0, 8000.0)) if wide else P
    jobs = []
    if which in ("synth", "all"):
        jobs += [(n, "synth", p) for n in synth.SCENES]
    if which in ("real", "all"):
        jobs += [(s, "real", p) for s in corpus.all_ids()]
    jobs += [(f, "file", p) for f in files]
    null(p)                                   # once, before the pool
    t0 = time.time()
    with Pool(2) as pool:
        results = pool.map(run_scene, jobs)
    print(f"| scene | windows | max z | passing the shape test | max z passing | best passing path |\n| --- | ---: | ---: | ---: | ---: | --- |")
    for name, kind, rows in results:
        passed = [r for r in rows if r.get("ok")]
        zmax = max((r["z"] for r in rows), default=float("nan"))
        bp = max(passed, key=lambda r: r["z"]) if passed else None
        label = name if kind == "synth" else _short(name) if kind == "file" else f"{name} ({_short(name)})"
        best = f"{bp['start']:.0f} s, {bp['from_hz']}→{bp['to_hz']} Hz, {bp['speed']:.0f} m/s, {bp['distance']:.0f} m" if bp else "none"
        print(f"| {label} | {len(rows)} | {zmax:.1f} | {len(passed)} | {bp['z'] if bp else float('nan'):.1f} | {best} |")
    out = corpus.DATA / "results"
    out.mkdir(parents=True, exist_ok=True)
    f = out / f"{time.strftime('%Y%m%d-%H%M%S')}-e2{'-wide' if wide else ''}.json"
    json.dump({"params": str(p), "results": results}, open(f, "w"))
    print(f"\n{len(jobs)} scenes in {time.time() - t0:.0f} s; saved {f}")


def _short(sid: str) -> str:
    if "/" in sid:                                  # a file path
        return sid.rsplit("/", 1)[-1]
    try:
        idx = json.load(open(corpus.sessions_dir() / sid / "index.json"))
        return (idx.get("note") or "").strip()[:40] or f"{idx['duration_s']:.0f} s"
    except (FileNotFoundError, NotADirectoryError):
        return ""


def cmd_sessions():
    for sid in corpus.all_ids():
        idx = json.load(open(corpus.sessions_dir() / sid / "index.json"))
        ps = idx["passes"][:3]
        near = "; ".join(f"{q['type'] or '?'} {q['closest_in_audio_km']} km heard {q['heard_s']} s" for q in ps)
        ctx = idx.get("context") or {}
        what = idx['note'][:30] or ctx.get("note", "")[:30]
        marks = ", ".join(f"{m['label']}@{m['t_s']:.0f}s" for m in idx.get("markers", []))
        print(f"{sid}  {idx['duration_s']:6.1f} s  {str(idx['mode'])[-18:]:>18}  {what!r:32}  nearest: {near}" + (f"  | marks: {marks}" if marks else "") + (f"  | manifest {idx['manifest']}" if idx.get("manifest") not in (None, "no manifest") else ""))


def _align(ref: np.ndarray, other: np.ndarray, sr: int) -> np.ndarray:
    """`other` shifted to line up with `ref` (encoder delay), by cross-correlating 400–3000 Hz envelopes."""
    from scipy.signal import butter, correlate, sosfiltfilt
    sos = butter(4, [400, 3000], "bandpass", fs=sr, output="sos")
    a, b = sosfiltfilt(sos, ref[: sr * 30]), sosfiltfilt(sos, other[: sr * 30])
    lag = int(np.argmax(correlate(a, b, "full", method="fft"))) - (len(b) - 1)
    out = np.zeros_like(ref)
    src = other[max(0, -lag):]
    out[max(0, lag): max(0, lag) + len(src)] = src[: len(out) - max(0, lag)]
    return out


def cmd_attack(sid: str, others: list[str]):
    import soundfile as sf
    idx, x, sr = corpus.load(sid)
    p = detect.Params(band=(80.0, 4000.0), broadband_aware=True)
    audios = [("original", x)]
    for o in others:
        y, ysr = sf.read(o)
        y = y[:, 0] if y.ndim > 1 else y
        if ysr != sr:
            raise SystemExit(f"{o}: sample rate {ysr}, expected {sr}")
        audios.append((o.rsplit("/", 1)[-1], _align(x, y, sr)))
    f0s = np.arange(100, 3500, 2.0)
    print(f"| aircraft | closest | heard | " + " | ".join(f"z ({n})" for n, _ in audios) + " |\n| --- | ---: | ---: |" + " ---: |" * len(audios))
    for q in idx["passes"][:6]:
        grid, fac, _ = corpus.curve(sid, q["hex"])
        factor = lambda tt, g=grid, fc=fac: np.interp(tt, g, fc, left=np.nan, right=np.nan)
        win = (max(q["heard_span_s"][0], q["heard_s"] - 25), min(q["heard_span_s"][1], q["heard_s"] + 25))
        zs = []
        for name, a in audios:
            fr, t, L = whitened(f"{sid}:{name}:attack", a, sr, p)
            A = L - L.mean()
            best, bf0, boff = detect.known_path(fr, t, A, factor, f0s, win)
            # null: the same search on the track shifted well beyond the offset range
            nulls = [detect.known_path(fr, t, A, (lambda tt, s=s: factor(tt - s)), f0s, win)[0] for s in (-45, -38, -31, -24, 24, 31, 38, 45)]
            nulls = np.array([n for n in nulls if np.isfinite(n)])
            zs.append(((best - nulls.mean()) / nulls.std() if len(nulls) > 2 and np.isfinite(best) else float("nan"), bf0, boff))
        print(f"| {q['type'] or '?'} {q['hex']} | {q['closest_in_audio_km']} km | {q['heard_s']} s | " + " | ".join(f"{z:.1f} ({f0:.0f} Hz, {off:+.1f} s)" for z, f0, off in zs) + " |")


def cmd_cloak(sid: str, presets: list[str]) -> list[str]:
    """Run web/scripts/cloak-raw.ts (the real wasm, as the page would) on the session's audio."""
    import subprocess, tempfile
    import soundfile as sf
    from pathlib import Path
    idx, x, sr = corpus.load(sid)
    out_dir = corpus.DATA / "cloaked"
    out_dir.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parent.parent
    outs = []
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "in.f32"
        x.astype(np.float32).tofile(src)
        for preset in presets or ["full", "experimental"]:
            dst = Path(tmp) / f"{preset}.f32"
            subprocess.run(["bun", str(repo / "web/scripts/cloak-raw.ts"), str(src), str(dst), str(sr), preset], check=True, cwd=repo / "web")
            y = np.fromfile(dst, dtype=np.float32)
            f = out_dir / f"{sid}-{preset}.wav"
            sf.write(f, y, sr, subtype="FLOAT")
            outs.append(str(f))
            print(f)
    return outs


def cmd_plot(sid: str):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    idx, x, sr = corpus.load(sid)
    p = detect.Params(band=(80.0, 4000.0), broadband_aware=False, ref_s=0)
    fr, t, L = detect.whiten(x, sr, p)
    fig, ax = plt.subplots(figsize=(13, 6))
    ax.pcolormesh(t, fr, L, vmin=-2, vmax=12, cmap="magma", shading="auto")
    ax.set_yscale("log")
    for q in idx["passes"][:4]:
        g, fac, _ = corpus.curve(sid, q["hex"])
        for f0 in (500, 1000, 2000):
            ax.plot(g, f0 * fac, lw=0.6, alpha=0.5, label=f"{q['type']} {q['closest_in_audio_km']} km" if f0 == 1000 else None)
    for c in idx["chirps_s"]:
        ax.axvspan(c, c + 1, color="w", alpha=0.15)
    ax.set_xlim(0, idx["duration_s"]); ax.set_ylim(*p.band); ax.legend(fontsize=7, loc="upper right")
    out = corpus.DATA / "plots"
    out.mkdir(parents=True, exist_ok=True)
    f = out / f"{sid}.png"
    plt.tight_layout(); plt.savefig(f, dpi=70)
    print(f)


def cmd_check(sid: str, others: list[str]):
    """The page's check, via web/scripts/check-raw.ts, on the session's audio and on copies of it."""
    import subprocess, tempfile
    import soundfile as sf
    from pathlib import Path
    idx, x, sr = corpus.load(sid)
    repo = Path(__file__).resolve().parent.parent
    audios = [("original", x)]
    for o in others:
        y, ysr = sf.read(o)
        y = y[:, 0] if y.ndim > 1 else y
        if ysr != sr:
            raise SystemExit(f"{o}: sample rate {ysr}, expected {sr}")
        audios.append((o.rsplit("/", 1)[-1], _align(x, y, sr)))
    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        for name, a in audios:
            src = Path(tmp) / "in.f32"
            a.astype(np.float32).tofile(src)
            out = subprocess.run(["bun", str(repo / "web/scripts/check-raw.ts"), str(src), str(sr)], check=True,
                                 cwd=repo / "web", capture_output=True, text=True).stdout
            r = json.loads(out.strip().splitlines()[-1])
            r["name"] = name
            rows.append(r)
    print("| audio | tones | doppler | flybys | hum | passes (time, Hz) | took |\n| --- | ---: | ---: | ---: | ---: | --- | ---: |")
    for r in rows:
        passes = ", ".join(f"{p['start']:.0f}–{p['end']:.0f} s {p['hi']:.0f}→{p['lo']:.0f}" for p in r["passes"]) or "—"
        print(f"| {r['name']} | {r['tones']} | {r['doppler']} | {r['flybys']} | {r['hum']} | {passes} | {r['took']:.1f} s |")
    res = corpus.DATA / "results"
    res.mkdir(parents=True, exist_ok=True)
    (res / f"check-{sid}.json").write_text(json.dumps(rows, indent=1))


def cmd_locate(sid: str, others: list[str]):
    """The place-searching attacker (lab/locate.py) on the session and on copies of it."""
    import soundfile as sf
    from . import locate
    idx, x, sr = corpus.load(sid)
    audios = [("original", x)]
    for o in others:
        y, ysr = sf.read(o)
        y = y[:, 0] if y.ndim > 1 else y
        if ysr != sr:
            raise SystemExit(f"{o}: sample rate {ysr}, expected {sr}")
        audios.append((o.rsplit("/", 1)[-1], _align(x, y, sr)))
    t = time.time()
    rows = locate.locate(sid, audios, sr)
    print("| audio | aircraft | true point's rank (of grid) | best guess off by | fine best off by | area within 3 / 6 of best | truth z by aircraft |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | --- |")
    for r in rows:
        z = ", ".join(f"{v}" for v in r["truth_z_by_aircraft"].values() if v is not None)
        print(f"| {r['name']} | {r['aircraft']} | {r['truth_rank']} of {r['points']} ({r['truth_percentile']} %) | "
              f"{r['best_error_m']} m | {r['fine_best_error_m']} m | {r['area_within_3_km2']} / {r['area_within_6_km2']} km² | {z} |")
    print(f"\n{time.time() - t:.0f} s")
    res = corpus.DATA / "results"
    res.mkdir(parents=True, exist_ok=True)
    (res / f"locate-{sid}.json").write_text(json.dumps(rows, indent=1))


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return
    cmd, rest = argv[0], argv[1:]
    if cmd == "ingest":
        for b in rest:
            print("ingested", corpus.ingest(b))
    elif cmd == "backfill":
        for sid in (corpus.all_ids() if rest[:1] == ["all"] else rest):
            print(sid, "+", corpus.backfill(sid), "positions")
    elif cmd == "label":
        idx = corpus.correct(rest[0], **dict(kv.split("=", 1) for kv in rest[1:]))
        print(idx["context"])
    elif cmd == "sessions":
        cmd_sessions()
    elif cmd == "e2":
        words = [a for a in rest if not a.startswith("--")]
        which = words[0] if words and words[0] in ("synth", "real", "all", "files") else "files"
        cmd_e2(which, "--wide" in rest, [w for w in words if w.endswith(".wav")])
    elif cmd == "cloak":
        cmd_cloak(rest[0], rest[1:])
    elif cmd == "attack":
        cmd_attack(rest[0], rest[1:])
    elif cmd == "locate":
        cmd_locate(rest[0], rest[1:])
    elif cmd == "check":
        cmd_check(rest[0], rest[1:])
    elif cmd == "plot":
        cmd_plot(rest[0])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
