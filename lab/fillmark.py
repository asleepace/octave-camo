"""The mark a fill leaves (docs/EXPERIMENTS.md, "The fill's mark").

Track removal replaces strips along a predicted curve with noise. If that noise isn't
statistically the same as the background around it, the strip itself traces the exact curve: an
attacker holding the flight logs sees it as a bump (a mean-based score) or a dip (a peak-picking
one), and a dip summed over aircraft is a hole at the true place.

This forces fills where there's nothing to remove (plane-free audio, the stop far below any z),
so all that's left of a fill is its mark, then scores it the attacker's way along the same curve,
at several analysis windows:
- the change in each filled rest frequency's excess along the true curve, minus the same at
  wrong times (in whitened dB: 0 for a clean fill, negative a dip, positive a bump);
- the attacker's z (best over every rest frequency, against six wrong times), filled minus
  unfilled.
"""
from __future__ import annotations

import json
import subprocess
import tempfile
from dataclasses import replace
from pathlib import Path

import numpy as np
import soundfile as sf

from . import detect, locate, synth

CLI = Path(__file__).resolve().parent.parent / ".build/release/octave-camo"
WINDOWS = (0.043, 0.085, 0.17, 0.34)


def factor(t: np.ndarray, tc: float, depth: float = 0.3, width: float = 4.0) -> np.ndarray:
    """A pass's Doppler factor: a smooth fall of `depth` around `tc`."""
    return 1 + depth / 2 - depth / (1 + np.exp(-(t - tc) / width))


def expected(duration: float, tc: float) -> dict:
    grid = np.arange(-60.0, duration + 60.0, 0.1)
    return {"times": np.round(grid, 3).tolist(), "factors": np.round(factor(grid, tc), 7).tolist(), "closest": tc}


def scrub(x: np.ndarray, sr: int, args: list[str]) -> np.ndarray:
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = Path(tmp) / "in.wav", Path(tmp) / "out.wav"
        sf.write(src, x, sr, subtype="FLOAT")
        r = subprocess.run([str(CLI), "scrub", str(src), str(dst), *args], capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError(r.stderr[:300])
        y, _ = sf.read(dst)
        return y if y.ndim == 1 else y[:, 0]


def per_rest(scene: locate.Scene, j: np.ndarray, fac: np.ndarray) -> np.ndarray:
    """Mean excess along f0 · fac for every rest frequency (the place search's sum, per rest):
    locate.Scene._profile, NaN everywhere when too few frames are usable."""
    prof = scene._profile(j, fac)
    return prof if prof is not None else np.full(len(locate.F0S), np.nan)


def profiles(y: np.ndarray, sr: int, tc: float, window: float, name: str):
    """(true-curve excess per rest, wrong-time mean per rest, attacker z) at one analysis window."""
    p = replace(locate.P, fft_s=window)
    scene = locate.Scene(y, sr, f"fillmark:{name}:{window}", params=p)
    j = np.flatnonzero(np.abs(scene.t - tc) <= locate.HALF_WINDOW_S)
    true = per_rest(scene, j, factor(scene.t[j], tc))
    wrong = np.array([per_rest(scene, j, factor(scene.t[j] - d, tc)) for d in locate.NULL_SHIFTS_S])
    best_true, best_wrong = np.nanmax(true), np.nanmax(wrong, axis=1)
    z = (best_true - best_wrong.mean()) / max(best_wrong.std(), 1e-3)
    return true, np.nanmean(wrong, 0), float(z)


def filled_rests(x: np.ndarray, y: np.ndarray, sr: int, tc: float) -> np.ndarray:
    """Which rest frequencies' curves the fill changed (most energy changed along them)."""
    scene = locate.Scene(y - x, sr, "fillmark:delta", params=replace(locate.P, fft_s=0.17))
    j = np.flatnonzero(np.abs(scene.t - tc) <= locate.HALF_WINDOW_S)
    d = per_rest(scene, j, factor(scene.t[j], tc))
    d = np.nan_to_num(d, nan=-np.inf)
    return np.flatnonzero(d > np.percentile(d[np.isfinite(d)], 99.5))


def measure(x: np.ndarray, sr: int, seed: int, tones: int = 6, extra: list[str] | None = None, name: str = "") -> dict:
    """One background, one seed: the fill's mark at each window."""
    duration = len(x) / sr
    tc = duration / 2
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump([expected(duration, tc)], f)
        exp = f.name
    base = ["--steps", "mono", "--seed", str(seed)]
    y = scrub(x, sr, [*base, "--expect", exp, "--track-stop", "-99", "--track-max-tones", str(tones), *(extra or [])])
    x0 = scrub(x, sr, base)                                     # the same chain, nothing filled
    rests = filled_rests(x0, y, sr, tc)
    out = {"rests": int(len(rests))}
    for w in WINDOWS:
        t0, w0, z0 = profiles(x0, sr, tc, w, f"{name}:{seed}:plain")
        t1, w1, z1 = profiles(y, sr, tc, w, f"{name}:{seed}:filled:{' '.join(extra or [])}")
        mark = ((t1 - w1) - (t0 - w0))[rests]
        out[str(w)] = {"mark": float(np.nanmean(mark)), "z_plain": round(z0, 2), "z_filled": round(z1, 2)}
    return out


def backgrounds(seconds: float = 60.0) -> dict[str, tuple[np.ndarray, int]]:
    """Plane-free sound: synthetic room noise, music and speech (no real recordings needed)."""
    n = int(seconds * synth.SR)
    rng = np.random.default_rng(7)
    out = {"room": (synth.room(seconds, seed=11)[:n], synth.SR),
           "music": (synth.music(seed=12)[0][:n], synth.SR),          # notes over room noise
           "pink": (_pink(n, rng), synth.SR)}
    return out


def _pink(n: int, rng) -> np.ndarray:
    X = np.fft.rfft(rng.normal(0, 1, n))
    f = np.fft.rfftfreq(n, 1 / synth.SR)
    X[1:] /= np.sqrt(f[1:])
    X[0] = 0
    y = np.fft.irfft(X, n)
    return y / y.std() * 0.05
