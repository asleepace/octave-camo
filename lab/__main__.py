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
  trackfill <session> [preset …] [--archive]
                                        cloak with flight-track removal (the CLI's --expect, curves
                                        predicted at the true position), into
                                        $LAB_DATA/cloaked/<session>-<preset>-tracks.wav; with
                                        --archive, the page's path instead: the engine predicts the
                                        curves from adsb.lol's half-hour archive (…-archive.wav)
  bench [--synth-only] [--per N]       the curve benchmark (N clips per strength, default 16): synthetic passes in real and synthetic
                                        backgrounds; detection by strength, false alarms per hour
  ml data|train|report                  the learned curve detector: make the training set (synthetic
                                        passes in training backgrounds), train, and report it against
                                        the other detectors on the benchmark and the real recordings
  plot <session>                        spectrogram with ADS-B Doppler curves and detected paths

Data stays in $LAB_DATA (default ~/.octave-camo-lab), never in the repo. Results are saved as JSON
in $LAB_DATA/results and printed as markdown tables.
"""
from __future__ import annotations

import json
import sys
import time
from multiprocessing import Pool

import numpy as np

from . import corpus, detect, synth
from .common import null, save_result, whitened, with_copies

P = detect.Params()
# Windows below this z aren't fitted (they can't be detections).
MIN_Z_TO_FIT = 3.0


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
        w.fit = detect.shape_test(w.path, p.win_s, dt=float(t[1] - t[0])) if w.z >= MIN_Z_TO_FIT else {"ok": False}
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
    print("| scene | windows | max z | passing the shape test | max z passing | best passing path |\n| --- | ---: | ---: | ---: | ---: | --- |")
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


def cmd_attack(sid: str, others: list[str]):
    idx = json.load(open(corpus.sessions_dir() / sid / "index.json"))
    p = detect.Params(band=(80.0, 4000.0), broadband_aware=True)
    audios, sr = with_copies(sid, others)
    f0s = np.arange(100, 3500, 2.0)
    print("| aircraft | closest | heard | " + " | ".join(f"z, dB ({n})" for n, _ in audios) + " |\n| --- | ---: | ---: |" + " ---: |" * len(audios))
    rows = []
    for q in idx["passes"][:6]:
        grid, fac, _ = corpus.curve(sid, q["hex"])
        factor = lambda tt, g=grid, fc=fac: np.interp(tt, g, fc, left=np.nan, right=np.nan)
        win = (max(q["heard_span_s"][0], q["heard_s"] - 25), min(q["heard_span_s"][1], q["heard_s"] + 25))
        zs = []
        for name, a in audios:
            fr, t, L = whitened(f"{sid}:{name}:attack", a, sr, p)
            zs.append(detect.known_path_z(fr, t, L - L.mean(), factor, f0s, win))
        rows.append({"hex": q["hex"], "results": dict(zip([n for n, _ in audios], zs))})
        print(f"| {q['type'] or '?'} {q['hex']} | {q['closest_in_audio_km']} km | {q['heard_s']} s | "
              + " | ".join(f"{z:.1f}, {e:+.2f} ({f0:.0f} Hz, {off:+.1f} s)" for z, e, f0, off in zs) + " |")
    save_result(f"attack-{sid}", rows)


def cmd_envelope(sid: str, others: list[str]):
    """The loudness-envelope attacker on the session's original and any cloaked copies."""
    from . import envelope
    idx = json.load(open(corpus.sessions_dir() / sid / "index.json"))
    g = corpus.geometry(sid)
    audios, sr = with_copies(sid, others)
    levels = {name: envelope.band_levels(a, sr) for name, a in audios}
    print("| aircraft | closest | heard | " + " | ".join(f"z, R² ({n})" for n, _ in audios) + " |\n| --- | ---: | ---: |" + " ---: |" * len(audios))
    rows = []
    for q in idx["passes"][:6]:
        track = g["tracks"].get(q["hex"])
        if track is None:
            continue
        res = {name: envelope.envelope_z(*levels[name], track, g["speed_of_sound"]) for name, _ in audios}
        rows.append({"hex": q["hex"], "results": {n: list(v[:2]) + [list(v[2]) if v[2] else None, v[3]] for n, v in res.items()}})
        print(f"| {q['type'] or '?'} {q['hex']} | {q['closest_in_audio_km']} km | {q['heard_s']} s | "
              + " | ".join(f"{z:.1f}, {r:.2f} ({int(b[0]) if b else '?'}–{int(b[1]) if b else '?'} Hz, {o:+.1f} s)" for z, r, b, o in res.values()) + " |")
    save_result(f"envelope-{sid}", rows)


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
    from pathlib import Path
    repo = Path(__file__).resolve().parent.parent
    audios, sr = with_copies(sid, others)
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
    save_result(f"check-{sid}", rows)


def cmd_locate(sid: str, others: list[str]):
    """The place-searching attacker (lab/locate.py) on the session and on copies of it."""
    from . import locate
    audios, sr = with_copies(sid, others)
    t = time.time()
    rows = locate.locate(sid, audios, sr)
    print("| audio | aircraft | true point's rank (of grid) | best guess off by | fine best off by | area within 3 / 6 of best | truth z by aircraft |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | --- |")
    for r in rows:
        z = ", ".join(f"{v}" for v in r["truth_z_by_aircraft"].values() if v is not None)
        print(f"| {r['name']} | {r['aircraft']} | {r['truth_rank']} of {r['points']} ({r['truth_percentile']} %) | "
              f"{r['best_error_m']} m | {r['fine_best_error_m']} m | {r['area_within_3_km2']} / {r['area_within_6_km2']} km² | {z} |")
    print(f"\n{time.time() - t:.0f} s")
    save_result(f"locate-{sid}", rows)


def clean_curve(heard: np.ndarray, fac: np.ndarray, closest: float) -> dict:
    """A predicted curve as the engine takes it (`ExpectedPass`): physical factors only (0.5–2;
    a velocity glitch where two position sources disagree can exceed that), and times strictly
    increasing after rounding (the same glitch, a jump in range, moves the heard time back)."""
    ok = np.isfinite(heard) & np.isfinite(fac) & (fac > 0.5) & (fac < 2)
    t, f = np.round(heard[ok], 3), np.round(fac[ok], 7)
    up = t > np.maximum.accumulate(np.concatenate([[-np.inf], t[:-1]]))
    return {"times": t[up].tolist(), "factors": f[up].tolist(), "closest": round(float(closest), 3)}


def expected_passes(sid: str, max_km: float = 15.0) -> list[dict]:
    """Each aircraft's predicted Doppler factor over the audio at the recording position (audio
    times and factors only), for aircraft within `max_km` while the audio runs, two minutes either
    side of it (the engine's test moves curves up to a minute)."""
    from . import locate
    geo = corpus.geometry(sid)
    dur, out = geo["duration_s"], []
    for h, (heard, fac, tc, rmin) in locate.curves(geo, np.zeros(2)).items():
        keep = (heard >= -120) & (heard <= dur + 120)
        if rmin > max_km * 1000 or keep.sum() < 20 or not (-30 < tc < dur + 30):
            continue
        c = clean_curve(heard[keep], fac[keep], tc)
        if len(c["times"]) >= 20:
            out.append(c)
    return out


PRESET_ARGS = {
    "full": ["--steps", "mono,hum,subtract,scurve,lowband"],
    "experimental": ["--steps", "mono,hum,subtract,scurve,lowband,lines", "--flatten", "5"],
}


def cmd_trackfill(sid: str, presets: list[str]):
    """The CLI's scrub with --expect: flight-track removal on top of a preset."""
    import subprocess, tempfile
    import soundfile as sf
    from pathlib import Path
    idx, x, sr = corpus.load(sid)
    repo = Path(__file__).resolve().parent.parent
    cli = repo / ".build/release/octave-camo"
    if not cli.exists():
        raise SystemExit("build the CLI first: swift build -c release --product octave-camo")
    newest = max(f.stat().st_mtime for f in (repo / "Sources").rglob("*.swift"))
    if newest > cli.stat().st_mtime:
        print("warning: the CLI is older than Sources/ (swift build -c release --product octave-camo)", file=sys.stderr)
    out_dir = corpus.DATA / "cloaked"
    out_dir.mkdir(parents=True, exist_ok=True)
    archive = "--archive" in presets
    presets = [p for p in presets if p != "--archive"]
    with tempfile.TemporaryDirectory() as tmp:
        src, exp = Path(tmp) / "in.wav", Path(tmp) / "expect.json"
        sf.write(src, x, sr, subtype="FLOAT")
        if archive:
            # The page's path: adsb.lol's half-hour archive only, curves predicted by the engine.
            files, at, start = corpus.archive_files(sid)
            track_args = ["--archive", ",".join(str(f) for f in files), "--at", at, "--start", str(start)]
            temp = (corpus.geometry(sid)["meta"].get("weather", {}).get("current", {}) or {}).get("temperature_2m")
            if temp is not None:
                track_args += ["--temp", str(temp)]
            print(f"archive: {len(files)} half-hour file(s)")
        else:
            passes = expected_passes(sid)
            print(f"{len(passes)} expected pass(es)")
            exp.write_text(json.dumps(passes))
            track_args = ["--expect", str(exp)]
        for preset in presets or ["experimental"]:
            dst = out_dir / f"{sid}-{preset}-{'archive' if archive else 'tracks'}.wav"
            r = subprocess.run([str(cli), "scrub", str(src), str(dst), *PRESET_ARGS[preset], "--seed", "7", *track_args],
                               capture_output=True, text=True)
            if r.returncode != 0:
                raise SystemExit(f"octave-camo scrub failed:\n{r.stderr.strip().splitlines()[0] if r.stderr.strip() else r.stdout[:500]}")
            for line in (r.stdout + r.stderr).splitlines():
                if "tracks:" in line or line.startswith("archive:"):
                    print(" ", line.strip())
            print(dst)


def cmd_bench(args: list[str]):
    from . import bench
    per = int(args[args.index("--per") + 1]) if "--per" in args else 16
    clips = bench.plan(per_snr=per, real="--synth-only" not in args)
    t = time.time()
    rows = bench.run(clips)
    print(bench.summarize(rows))
    print(f"\n{len(clips)} clips ({time.time() - t:.0f} s); per-clip results in $LAB_DATA/results/bench.jsonl")


def cmd_ml(args: list[str]):
    from pathlib import Path
    from . import ml
    d = corpus.DATA / "ml"
    d.mkdir(parents=True, exist_ok=True)
    model = d / "model-v1.npz"
    if args[:1] == ["data"]:
        ml.make_dataset(d / "train.npz", ml.TRAIN_SESSIONS, 2_400, 1, workers=1)
    elif args[:1] == ["train"]:
        ml.train(d / "train.npz", model, steps=1_500, crop=96, lr=3e-3)
    elif args[:1] == ["report"]:
        ml.prepare_report(Path(model))
        print(ml.report(Path(model)))
    else:
        raise SystemExit("python3 -m lab ml data|train|report")


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
    elif cmd == "envelope":
        cmd_envelope(rest[0], rest[1:])
    elif cmd == "ml":
        cmd_ml(rest)
    elif cmd == "bench":
        cmd_bench(rest)
    elif cmd == "trackfill":
        cmd_trackfill(rest[0], rest[1:])
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
