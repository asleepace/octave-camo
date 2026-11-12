"""Doppler curves of straight, level, constant-speed flight: what other places along a flight hear.

A listener at closest (slant) distance d from a line the aircraft flies at speed v hears the
engine's frequencies multiplied by

    factor = 1 / (1 + v·s / (r·c)),   s = v·(τ − τ0),  r = √(d² + s²)

at reception time t = τ + r / c (τ: emission time, τ0: closest approach). Every place in the
attacker's search box sees the same flight at its own d (and timing), so a library of (v, d) is a
set of wrong places that sweep like real ones, without knowing anyone's position. Used as the wrong
answers of a fair test (OPEN_QUESTIONS.md, "The engine's stopping test").
"""
from __future__ import annotations

import numpy as np

C = 343.0
SPEEDS = (60.0, 90.0, 130.0, 180.0, 230.0)              # m/s: light aircraft to jets on approach
DISTANCES = (400.0, 800.0, 1500.0, 3000.0, 5000.0)       # m: closest slant range, within audibility


def curve(v: float, d: float, half_s: float = 90.0, step_s: float = 0.1) -> tuple[np.ndarray, np.ndarray, float]:
    """(reception times, factors, time of the steepest fall), times relative to that fall."""
    tau = np.arange(-half_s - 30, half_s + 30, step_s / 4)
    s = v * tau
    r = np.hypot(d, s)
    t = tau + r / C
    fac = 1.0 / (1.0 + v * s / (r * C))
    grid = np.arange(-half_s, half_s + 1e-9, step_s)
    f = np.interp(grid + t[np.argmin(np.gradient(fac, t))], t, fac)
    tc = float(grid[np.argmin(np.gradient(f, grid))])
    return grid - tc, f, 0.0


def library(speeds=SPEEDS, distances=DISTANCES) -> list[dict]:
    """Shapes `zenodo.u` can use as wrong places: {case, t, fac, tc} (exact, so `zenodo.shape`
    passes them through uncleaned)."""
    out = []
    for v in speeds:
        for d in distances:
            t, f, _ = curve(v, d)
            out.append({"case": f"lib-v{int(v)}-d{int(d)}", "t": t + 100.0, "fac": f, "tc": 100.0})
    return out


SCALES = (0.6, 1.0, 1.6)


def scaled(p: dict, scales=SCALES) -> list[dict]:
    """Wrong places for a pass from its own flight: the curve's swing scaled in depth (a, in log
    factor) and duration (b) about its closest approach, every pair but (1, 1). The engine's rank
    target ranks against these by default (Attacker.swift, `.scaled`)."""
    from . import zenodo
    t, fac, tc = zenodo.shape(p)
    return [{"case": f"{p['case']}-scaled-{a}-{b}", "t": tc + (t - tc) * b, "fac": np.exp(a * np.log(fac)), "tc": tc}
            for a in scales for b in scales if (a, b) != (1.0, 1.0)]
