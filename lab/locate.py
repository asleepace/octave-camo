"""The place-searching attacker: where was this recorded?

After the method in [YT-UytYrhYLOKI] (docs/SOURCES.md): for every candidate point on a grid, predict the
Doppler curve each logged aircraft would produce there (its real track, sound travel time
included), score the audio's whitened spectrogram along each curve with the engine's rest
frequency free, and add the aircraft up (the events are scored together on one timeline). The
recording's time is given exactly, which makes this attacker stronger than one who only knows when
the clip was posted.

Each aircraft's score at a point is a z against the same predicted curve moved to wrong times
(±24–40 s) over the same frames: a far point predicts an almost flat curve, which matches any
steady sound equally well at any time, so only curves whose timing fits score high. Aircraft
beyond 10 km of a point count 0.
Not yet modelled: silence (a point that predicts a loud pass the audio doesn't have is only not
rewarded, not penalised).

Privacy: candidate points are offsets from the true position and only distances, ranks and areas
are printed or saved, never a position.
"""
from __future__ import annotations

import numpy as np

from . import corpus, detect
from .common import whitened

P = detect.Params(band=(80.0, 4000.0), broadband_aware=True)
# Rest frequencies searched: 100 Hz–3.5 kHz in 0.2 % steps (fine enough for a Doppler factor).
STEP = 0.002
F0S = np.exp(np.arange(np.log(100.0), np.log(3500.0), STEP))
FAC_ROWS = int(np.ceil(np.log(2.0) / STEP))   # log-axis rows for Doppler factors 0.5–2 either side
HALF_WINDOW_S = 25.0          # scored around each aircraft's predicted closest approach
MIN_FRAMES = 80                # frames a curve must cover near its closest approach (~1.7 s)
TOL_BINS = 2                  # best of ±2 bins (published positions are coarse)
NULL_SHIFTS_S = (-40.0, -32.0, -24.0, 24.0, 32.0, 40.0)   # the same curve at wrong times
MAX_RANGE_KM = 10.0           # a point farther than this from an aircraft doesn't hear it


class Scene:
    """One audio's spectrogram, prepared for scoring curves."""

    def __init__(self, x: np.ndarray, sr: int, name: str, params: detect.Params | None = None):
        self.f, self.t, L = whitened(f"{name}:locate", x, sr, params or P)
        A = L - L.mean()
        Am = A.copy()
        for o in range(1, TOL_BINS + 1):
            Am[:-o] = np.maximum(Am[:-o], A[o:])
            Am[o:] = np.maximum(Am[o:], A[:-o])
        self.A = Am.astype(np.float32)
        self.df = self.f[1] - self.f[0]
        # The same spectrogram on a log-frequency axis, in the rest-frequency grid's steps: a curve
        # f0·fac is then one row shift per frame (log fac / STEP), the same for every f0, and a run
        # of frames with the same shift is a difference of running sums. Rows outside the band are
        # NaN, so a rest frequency whose curve leaves it scores NaN (as the direct search skips it).
        rows = np.log(F0S[0]) + (np.arange(len(F0S) + 2 * FAC_ROWS) - FAC_ROWS) * STEP
        b = np.rint((np.exp(rows) - self.f[0]) / self.df).astype(np.int64)
        inside = (b >= 0) & (b < len(self.f))
        G = np.full((len(rows), self.A.shape[1]), np.nan)
        G[inside] = Am[b[inside]]
        # Running sums over frames, frames × rows (a run's sum is two contiguous rows).
        self.C = np.ascontiguousarray(np.concatenate([np.zeros((1, len(rows))), np.cumsum(G.T, axis=0)], axis=0))

    def scores(self, heard: np.ndarray, factor: np.ndarray, t_close: float) -> tuple[float, float, float]:
        """(score, null mean, null spread): the curve's score near its closest approach, and the
        same curve moved to wrong times over the same frames. A far point predicts an almost flat
        curve, which matches a steady sound as well at any time, so only timing that fits stands
        out from its null."""
        t = self.t
        j = np.flatnonzero((t >= t_close - HALF_WINDOW_S) & (t <= t_close + HALF_WINDOW_S))
        if len(j) < MIN_FRAMES:
            return np.nan, np.nan, np.nan
        s0 = self._best(j, np.interp(t[j], heard, factor, left=np.nan, right=np.nan))
        nulls = np.array([self._best(j, np.interp(t[j] - d, heard, factor, left=np.nan, right=np.nan)) for d in NULL_SHIFTS_S])
        nulls = nulls[np.isfinite(nulls)]
        if not np.isfinite(s0) or len(nulls) < 3:
            return np.nan, np.nan, np.nan
        return s0, float(nulls.mean()), float(nulls.std())

    def _best(self, j: np.ndarray, fac: np.ndarray) -> float:
        """Best mean excess along f0·fac over all rest frequencies (frames where fac is known), on
        the log axis: the factor rounded to 0.2 %, a fraction of a bin below 5 kHz. `j` must be
        consecutive frames (a gap just starts a new run)."""
        ok = np.isfinite(fac) & (fac > 0.5) & (fac < 2)
        if ok.sum() < MIN_FRAMES:
            return np.nan
        j = j[ok]
        s = np.rint(np.log(fac[ok]) / STEP).astype(np.int64)
        cut = np.flatnonzero((np.diff(s) != 0) | (np.diff(j) != 1)) + 1
        a, e = np.r_[0, cut], np.r_[cut, len(j)]
        runs = self.C[j[e - 1] + 1] - self.C[j[a]]                          # runs × rows
        total = np.zeros(len(F0S))
        for k, o in enumerate(FAC_ROWS + s[a]):                              # each run, shifted
            total += runs[k, o:o + len(F0S)]
        total /= len(j)
        return float(np.nanmax(total)) if np.isfinite(total).any() else np.nan

    def _best_direct(self, j: np.ndarray, fac: np.ndarray) -> float:
        """The direct search _best replaces (kept to test it): every rest frequency's bins."""
        ok = np.isfinite(fac)
        if ok.sum() < MIN_FRAMES:
            return np.nan
        j, fac = j[ok], fac[ok]
        K = np.rint((F0S[:, None] * fac[None, :] - self.f[0]) / self.df).astype(np.int32)
        inside = (K.min(1) >= 0) & (K.max(1) < len(self.f))
        if not inside.any():
            return np.nan
        return float(self.A[K[inside], j[None, :]].mean(1).max())


class EnvelopeScene:
    """One audio's band levels (the loudness attacker's, lab/envelope.py), for scoring each
    point's predicted swell: a jet's roar has no tone for the curves above, but its level still
    rises and falls with distance. Same timing, window and wrong times as the tone score."""

    def __init__(self, x: np.ndarray, sr: int):
        from .envelope import band_levels
        self.t, self.levels = band_levels(x, sr)

    def scores(self, heard: np.ndarray, r: np.ndarray, t_close: float) -> tuple[float, float, float]:
        """(score, null mean, null spread): the best R² over bands of the predicted level (spreading
        and absorption at each band's centre) over the whole clip, and the same at the envelope
        attacker's 34 wrong times (20–60 s: a swell is slow, so nearer ones fit nearly as well). A
        prediction that barely swings fits any drift, so curves swinging under 1.5 dB don't count.
        `t_close` is unused (the swell is scored everywhere it's predicted)."""
        from .envelope import fit_r2_many
        from .passes import absorption_db_per_km
        j = np.arange(0, len(self.t), 2)              # every second (levels are 1 s windows, 0.5 s apart)
        if len(j) < 20:
            return np.nan, np.nan, np.nan
        shifts = (0.0,) + tuple(detect.NULL_SHIFTS)
        best = np.full(len(shifts), np.nan)
        rr = np.maximum(r, 1.0)
        for (lo, hi), lv in self.levels.items():
            fc = np.sqrt(lo * hi)
            pred = -20 * np.log10(rr) - absorption_db_per_km(fc) * rr / 1_000
            P = np.array([np.interp(self.t[j] - d, heard, pred, left=np.nan, right=np.nan) for d in shifts])
            ok = np.isfinite(P).all(0)
            if ok.sum() < 20:
                continue
            P, L = P[:, ok], lv[j][ok]
            swing = np.ptp(P, axis=1) >= 1.5
            if not swing[0]:
                continue
            r2 = np.full(len(shifts), np.nan)
            r2[swing] = fit_r2_many(L, P[swing], step=1.5, nb=12)
            best = np.fmax(best, r2)
        nulls = best[1:][np.isfinite(best[1:])]
        if not np.isfinite(best[0]) or len(nulls) < 20:
            return np.nan, np.nan, np.nan
        return float(best[0]), float(nulls.mean()), float(nulls.std())


def curves(geo: dict, p: np.ndarray):
    """For a candidate point p (metres east, north; same height), each aircraft's heard time,
    Doppler factor and predicted closest-approach time in the audio, and its closest distance."""
    c = geo["speed_of_sound"]
    out = {}
    for h, (te, q, v) in geo["tracks"].items():
        d = q - np.array([p[0], p[1], 0.0])
        r = np.linalg.norm(d, axis=1)
        vr = (d * v).sum(1) / r
        heard = te + r / c
        i = int(np.argmin(r))
        out[h] = (heard, 1 / (1 + vr / c), float(heard[i]), float(r[i]))
    return out


def ranges(geo: dict, p: np.ndarray) -> dict:
    """For a candidate point, each aircraft's heard time and slant range (for the level it predicts)."""
    c = geo["speed_of_sound"]
    out = {}
    for h, (te, q, v) in geo["tracks"].items():
        r = np.linalg.norm(q - np.array([p[0], p[1], 0.0]), axis=1)
        out[h] = (te + r / c, r)
    return out


def audible(geo: dict, extent_m: float, max_km: float = 12.0) -> list[str]:
    """Aircraft that pass within `max_km` of some point of the search area while the audio runs."""
    dur, keep = geo["duration_s"], []
    for h, (te, q, v) in geo["tracks"].items():
        heard = te + np.linalg.norm(q, axis=1) / geo["speed_of_sound"]
        inside = (heard >= -HALF_WINDOW_S) & (heard <= dur + HALF_WINDOW_S)
        if not inside.any():
            continue
        horizontal = np.maximum(0, np.abs(q[inside, :2]) - extent_m)     # distance to the area's box
        if np.min(np.hypot(np.hypot(*horizontal.T), q[inside, 2])) <= max_km * 1000:
            keep.append(h)
    return keep


def search(scene: Scene, geo: dict, hexes: list[str], points: np.ndarray) -> np.ndarray:
    """(score, null mean, null spread), points × aircraft × 3 (NaN: outside the audio's time or
    out of earshot)."""
    dur = geo["duration_s"]
    S = np.full((len(points), len(hexes), 3), np.nan)
    for i, p in enumerate(points):
        cv = curves(geo, p)
        for k, h in enumerate(hexes):
            heard, fac, tc, rmin = cv[h]
            if -HALF_WINDOW_S < tc < dur + HALF_WINDOW_S and rmin <= MAX_RANGE_KM * 1000:
                S[i, k] = scene.scores(heard, fac, tc)
    return S


def zscores(S: np.ndarray, floor: np.ndarray | None = None) -> tuple[np.ndarray, np.ndarray]:
    """Per point and aircraft, z = (score − null mean) / null spread, the spread floored at the
    aircraft's median spread over the grid (six nulls make a noisy spread). Returns (z, floor)."""
    if floor is None:
        floor = np.array([np.nanmedian(S[:, k, 2]) if np.isfinite(S[:, k, 2]).any() else 1.0 for k in range(S.shape[1])])
    Z = (S[:, :, 0] - S[:, :, 1]) / np.maximum(S[:, :, 2], floor[None, :])
    return Z, floor


def combine(Z: np.ndarray) -> np.ndarray:
    """All aircraft on one timeline: their z summed (a point that doesn't hear one gets 0 for it)."""
    return np.nan_to_num(Z, nan=0.0).sum(1)


def rank_bits(rank: float, points: int) -> float:
    """How far the audio narrows the search, model-free: log2 of the rank a blind guess would give
    the truth on average ((N + 1) / 2) over the rank the attacker's scores give it. An attacker
    checking candidates in score order needs `rank` tries instead of half the grid; 0 is no help,
    log2((N + 1) / 2) (9.1 bits on 1,089 points) is the truth ranked first, negative the scores
    point away from it."""
    return float(np.log2((points + 1) / 2 / rank))


def _rank(value, others: np.ndarray, low: bool = False):
    """Rank of `value` (scalar or array) among the sorted `others` plus itself, ties in the middle:
    from the top, or with `low` from the bottom."""
    gt = len(others) - np.searchsorted(others, value, side="right")
    lt = np.searchsorted(others, value, side="left")
    tied = len(others) - gt - lt
    return (lt if low else gt) + (tied + 2) // 2


def null_bits(Z: np.ndarray, truth: int, exclude: np.ndarray | None = None, low: bool = False,
              draws: int = 4000, seed: int = 0) -> np.ndarray:
    """Rank bits the truth would get from audio with no information about it, in this scene: each
    aircraft it hears gets a z drawn from that aircraft's z at the other points that hear it (what
    a wrong place scores), the other points keep theirs. Needed because the truth always hears the
    aircraft passing it while many grid points hear none and score exactly 0, so any positive
    noise at the truth beats all of those: one aircraft at z 1.2 ranked a truth 40th of 1,089
    (3.8 bits) with nothing there. `exclude` marks points left out of the draws (those near the
    truth share its evidence, so they aren't wrong places). With `low`, ranks from the bottom: an
    attacker looking for a hole (removal that leaves the truth scoring below wrong places)."""
    total = combine(Z)
    others = np.sort(np.delete(total, truth))
    keep = np.ones(len(Z), bool)
    keep[truth] = False
    if exclude is not None:
        keep &= ~exclude
    rng = np.random.default_rng(seed)
    t = np.zeros(draws)
    for k in np.flatnonzero(np.isfinite(Z[truth])):
        pool = Z[keep, k]
        pool = pool[np.isfinite(pool)]
        if len(pool):
            t += rng.choice(pool, draws)
    return np.log2((len(total) + 1) / 2 / _rank(t, others, low))


def search_envelope(scene: EnvelopeScene, geo: dict, hexes: list[str], points: np.ndarray) -> np.ndarray:
    """As `search`, for the loudness swell: points × aircraft × (score, null mean, null spread)."""
    dur = geo["duration_s"]
    S = np.full((len(points), len(hexes), 3), np.nan)
    for i, p in enumerate(points):
        rg = ranges(geo, p)
        for k, h in enumerate(hexes):
            heard, r = rg[h]
            m = int(np.argmin(r))
            tc = float(heard[m])
            if -HALF_WINDOW_S < tc < dur + HALF_WINDOW_S and r[m] <= MAX_RANGE_KM * 1000:
                S[i, k] = scene.scores(heard, r, tc)
    return S


def place(Z: np.ndarray, truth: int, near: np.ndarray) -> dict:
    """The truth's place in one score map (points × aircraft z): rank from the top and from the
    bottom, rank bits, and p against the scene's no-information baseline for each."""
    total = combine(Z)
    others = np.sort(np.delete(total, truth))
    rank, rank_low = int(_rank(total[truth], others)), int(_rank(total[truth], others, low=True))
    bits, bits_low = rank_bits(rank, len(total)), rank_bits(rank_low, len(total))
    nb, nb_low = null_bits(Z, truth, near), null_bits(Z, truth, near, low=True)
    return {"rank": rank, "bits": round(bits, 2), "p": round(float((nb >= bits - 1e-9).mean()), 3),
            "null_bits_mean": round(float(nb.mean()), 2),
            "rank_low": rank_low, "p_low": round(float((nb_low >= bits_low - 1e-9).mean()), 3)}


def grid(extent_m: float, step_m: float, center=(0.0, 0.0)) -> np.ndarray:
    a = np.arange(-extent_m, extent_m + step_m / 2, step_m)
    X, Y = np.meshgrid(a + center[0], a + center[1])
    return np.stack([X.ravel(), Y.ravel()], 1)


def locate(sid: str, audios: list[tuple[str, np.ndarray]], sr: int, extent_m: float = 8_000,
           coarse_m: float = 500, fine_m: float = 100, fine_extent_m: float = 1_000, envelope: bool = False) -> list[dict]:
    """Search a coarse grid around the true position, then a fine one around the coarse best and
    around the truth (so the truth is always scored on the fine grid's terms). Summaries only.
    With `envelope`, also the loudness swell on the coarse grid, alone and combined with the tones
    (each aircraft's better z of the two at each point)."""
    geo = corpus.geometry(sid)
    hexes = audible(geo, extent_m)
    coarse = grid(extent_m, coarse_m)
    results = []
    for name, x in audios:
        scene = Scene(x, sr, f"{sid}:{name}")
        S = search(scene, geo, hexes, coarse)
        Zc, floor = zscores(S)
        total = combine(Zc)
        truth_i = int(np.argmin(np.hypot(*coarse.T)))
        best_i = int(np.nanargmax(total))
        # Fine grids around the best coarse point and around the truth.
        fine = np.unique(np.concatenate([grid(fine_extent_m, fine_m, coarse[best_i]), grid(fine_extent_m, fine_m)]), axis=0)
        Zf = combine(zscores(search(scene, geo, hexes, fine), floor)[0])
        fb = int(np.nanargmax(Zf))
        ft = int(np.argmin(np.hypot(*fine.T)))
        # Ties share the middle rank: points no aircraft reaches all score 0, and the truth among
        # them is no better placed than any.
        others = np.sort(np.delete(total, truth_i))
        rank = int(_rank(total[truth_i], others))
        rank_low = int(_rank(total[truth_i], others, low=True))
        within = lambda d: float((total >= total[best_i] - d).sum() * (coarse_m / 1000) ** 2)
        near = np.hypot(*coarse.T) < 2_000            # shares the truth's evidence: not a wrong place
        bits, nb = rank_bits(rank, len(coarse)), null_bits(Zc, truth_i, near)
        bits_low, nb_low = rank_bits(rank_low, len(coarse)), null_bits(Zc, truth_i, near, low=True)
        per_aircraft = {h: round(float(Zc[truth_i, k]), 1) for k, h in enumerate(hexes) if np.isfinite(Zc[truth_i, k])}
        results.append({
            "name": name, "aircraft": len(hexes), "points": len(coarse),
            "truth_rank": rank, "truth_percentile": round(100 * (1 - (rank - 1) / len(coarse)), 2),
            "best_error_m": round(float(np.hypot(*coarse[best_i]))), "fine_best_error_m": round(float(np.hypot(*fine[fb]))),
            "best_score": round(float(total[best_i]), 1), "truth_score": round(float(total[truth_i]), 1),
            "fine_truth_score": round(float(Zf[ft]), 1), "fine_best_score": round(float(Zf[fb]), 1),
            "rank_bits": round(bits, 2),
            # Against the same scene with no information at the truth: the mean, how often it
            # reaches the observed bits (p), and the excess (observed minus mean).
            "null_bits_mean": round(float(nb.mean()), 2), "null_bits_p95": round(float(np.percentile(nb, 95)), 2),
            "p": round(float((nb >= bits - 1e-9).mean()), 3), "excess_bits": round(float(bits - nb.mean()), 2),
            # The same from the bottom: does removal leave a hole at the truth?
            "rank_low": rank_low, "rank_bits_low": round(bits_low, 2), "p_low": round(float((nb_low >= bits_low - 1e-9).mean()), 3),
            "z_by_aircraft": np.round(Zc, 2).tolist(),
            "totals": np.round(total, 2).tolist(), "truth_index": truth_i,
            "area_within_3_km2": round(within(3.0), 2), "area_within_6_km2": round(within(6.0), 2),
            "truth_z_by_aircraft": per_aircraft,
        })
        if envelope:
            Ze, _ = zscores(search_envelope(EnvelopeScene(x, sr), geo, hexes, coarse))
            results[-1]["envelope"] = place(Ze, truth_i, near)
            results[-1]["envelope_z_by_aircraft"] = {h: round(float(Ze[truth_i, k]), 1) for k, h in enumerate(hexes) if np.isfinite(Ze[truth_i, k])}
            results[-1]["combined"] = place(np.fmax(Zc, Ze), truth_i, near)
    return results
