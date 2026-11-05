"""Shared lab plumbing: the on-disk spectrogram cache, the path-search null, aligning a cloaked
copy with its original, and saving results."""
from __future__ import annotations

import hashlib
import json

import numpy as np

from . import corpus, detect, synth


def cache_key(name: str, p: detect.Params, x: np.ndarray) -> str:
    # The audio's own bytes are part of the key: a re-cloaked file keeps its name.
    h = hashlib.sha1(f"{name}|{p}|{len(x)}".encode())
    h.update(np.ascontiguousarray(x, dtype=np.float32).tobytes())
    return h.hexdigest()[:16]


def whitened(name: str, x: np.ndarray, sr: int, p: detect.Params):
    """whiten(), cached on disk by scene name, parameters and the audio itself."""
    d = corpus.DATA / "cache"
    d.mkdir(parents=True, exist_ok=True)
    f = d / f"{cache_key(name, p, x)}.npz"
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
    f = d / f"null-{cache_key('null', p, np.zeros(0))}.json"
    if f.exists():
        return json.load(open(f))
    x = synth.room(120, seed=101)
    fr, t, L = detect.whiten(x, synth.SR, p)
    mu = float(L.mean())
    sc = np.array([w.score for w in detect.search(fr, t, L - mu, p)])
    out = {"mu": mu, "mean": float(sc.mean()), "sd": float(sc.std())}
    json.dump(out, open(f, "w"))
    return out


def align(ref: np.ndarray, other: np.ndarray, sr: int) -> np.ndarray:
    """`other` shifted to line up with `ref` (encoder delay), by cross-correlating 400–3000 Hz envelopes."""
    from scipy.signal import butter, correlate, sosfiltfilt
    sos = butter(4, [400, 3000], "bandpass", fs=sr, output="sos")
    a, b = sosfiltfilt(sos, ref[: sr * 30]), sosfiltfilt(sos, other[: sr * 30])
    lag = int(np.argmax(correlate(a, b, "full", method="fft"))) - (len(b) - 1)
    out = np.zeros_like(ref)
    src = other[max(0, -lag):]
    out[max(0, lag): max(0, lag) + len(src)] = src[: len(out) - max(0, lag)]
    return out


def with_copies(sid: str, others: list[str]) -> tuple[list[tuple[str, np.ndarray]], int]:
    """The session's audio and each other file of it (e.g. cloaked copies), aligned to it:
    ([(name, audio)], sample rate)."""
    import soundfile as sf
    _, x, sr = corpus.load(sid)
    audios = [("original", x)]
    for o in others:
        y, ysr = sf.read(o)
        y = y[:, 0] if y.ndim > 1 else y
        if ysr != sr:
            raise SystemExit(f"{o}: sample rate {ysr}, expected {sr}")
        audios.append((o.rsplit("/", 1)[-1], align(x, y, sr)))
    return audios, sr


def save_result(name: str, obj) -> None:
    """Into $LAB_DATA/results/<name>.json."""
    d = corpus.DATA / "results"
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{name}.json").write_text(json.dumps(obj, indent=1))
