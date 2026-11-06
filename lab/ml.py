"""A small learned curve detector (docs/EXPERIMENTS.md, "the curve benchmark").

The input is the same kind of picture the check's path search looks at: a short-window
spectrogram, each frequency over its running median, each frame over its own median, clipped. Two
changes make it easier to learn from: frequencies are on a log scale (a Doppler curve's shape is
then the same at any engine frequency, only shifted, which is what convolutions share), and frames
are 64 ms apart. The model marks every pixel that lies on a passing tone; the physics (path
search + flyby fit) then turns marks into passes, so the model proposes and the fit decides.

Training data is synthetic (lab/passes.py) in backgrounds that never appear in the test set: the
real recordings are split by session, and the three real passes are only ever tested on.

JAX, CPU. The network is a stack of 3×3 convolutions dilated along time (receptive field ~8 s)
with residual connections: ~20 k parameters, small enough to port to Swift.
"""
from __future__ import annotations

import json
import time
from pathlib import Path

import numpy as np

from . import corpus, passes

SR = 16_000
N_FFT = 2_048                  # 0.128 s
HOP = 1_024                    # 0.064 s
F_LO, F_HI, NBINS = 80.0, 4_000.0, 192
EDGES = np.geomspace(F_LO, F_HI, NBINS + 1)
CENTERS = np.sqrt(EDGES[:-1] * EDGES[1:])
REF_S, BLOCK_S = 15.0, 0.25
LABEL_SNR = 3.0                # a pixel is "on a tone" where the tone is at least this, dB/Hz


def to_rate(x: np.ndarray, sr: int) -> np.ndarray:
    if sr == SR:
        return x
    from math import gcd
    from scipy.signal import resample_poly
    g = gcd(sr, SR)
    return resample_poly(x, SR // g, sr // g)


def features(x: np.ndarray, sr: int, linear: bool = False):
    """(log-frequency excess, NBINS × frames, float32; frame times, s), and with `linear` also
    the linear-frequency excess and its frequencies (to place a path more finely than a log bin)."""
    from scipy.signal import stft
    x = to_rate(np.asarray(x, dtype=float), sr)
    f, t, Z = stft(x, SR, nperseg=N_FFT, noverlap=N_FFT - HOP, boundary=None, padded=False)
    t = t.astype(float)
    k = (f >= F_LO * 0.97) & (f <= F_HI * 1.03)
    f, P = f[k], np.abs(Z[k]) ** 2 + 1e-20
    # Running median per bin: the median of quarter-second block medians over ±7.5 s.
    B = max(1, int(round(BLOCK_S * SR / HOP)))
    nb = (P.shape[1] + B - 1) // B
    pad = nb * B - P.shape[1]
    Pb = np.concatenate([P, P[:, -1:].repeat(pad, 1)], 1).reshape(P.shape[0], nb, B)
    bm = np.median(Pb, 2)
    half = int(round(REF_S / 2 / BLOCK_S))
    ref = np.stack([np.median(bm[:, max(0, i - half): i + half + 1], 1) for i in range(nb)], 1)
    L = 10 * np.log10(P / ref.repeat(B, 1)[:, : P.shape[1]])
    L -= np.median(L, 0, keepdims=True)
    L = np.clip(L, -3, 12)
    # Log bins: the loudest linear bin in each (a narrow tone survives pooling).
    idx = np.searchsorted(EDGES, f) - 1
    out = np.full((NBINS, L.shape[1]), np.nan)
    for b in range(NBINS):
        m = idx == b
        if m.any():
            out[b] = L[m].max(0)
        else:
            out[b] = L[int(np.argmin(np.abs(f - CENTERS[b])))]
    if linear:
        return out.astype(np.float32), t, f, L
    return out.astype(np.float32), t


def labels(truth, snr: float, times: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """(target, weight), NBINS × frames: 1 on a tone's bin where it's at least LABEL_SNR dB/Hz;
    the bins beside it don't count either way (off-by-one isn't an error)."""
    y = np.zeros((NBINS, len(times)), np.float32)
    w = np.ones_like(y)
    for g, f, lvl in truth:
        ft, lt = np.interp(times, g, f), np.interp(times, g, lvl)
        b = np.searchsorted(EDGES, ft) - 1
        for j in np.flatnonzero((b >= 0) & (b < NBINS)):
            on = snr + lt[j] >= LABEL_SNR
            for d in (-1, 1):
                if 0 <= b[j] + d < NBINS:
                    w[b[j] + d, j] = 0
            if on:
                y[b[j], j] = 1
            else:
                w[b[j], j] = 0                       # a tone too faint to mark: not a "no" either
    return y, w


# --- data ----------------------------------------------------------------------------------

def _scene(name: str, seed: int) -> np.ndarray:
    from . import synth
    fn = {"room": lambda: synth.room(60, seed=seed), "music": lambda: synth.music(seed=seed),
          "singing": lambda: synth.singing(seed=seed), "speech": lambda: synth.speech(seed=seed),
          "siren": lambda: synth.siren(seed=seed), "bangs": lambda: synth.bangs(seed=seed),
          "scales": lambda: synth.descending_scales(seed=seed)}[name]
    x = fn()
    return np.asarray(x[0] if isinstance(x, tuple) else x, dtype=float)


def background_pool(sessions: list[str], synth_seeds: int = 3) -> list[np.ndarray]:
    """16 kHz backgrounds: whole plane-free sessions, and synthetic scenes with a few seeds."""
    pool = []
    for sid in sessions:
        _, x, sr = corpus.load(sid)
        pool.append(to_rate(x[int(5 * sr):], sr))                    # skip the calibration chirps
    for name in ("room", "music", "singing", "speech", "siren", "bangs", "scales"):
        for s in range(synth_seeds):
            pool.append(to_rate(_scene(name, 100 + s), passes_sr()))
    return pool


def passes_sr() -> int:
    from . import synth
    return synth.SR


def example(pool: list[np.ndarray], seed: int, seconds: float = 30.0, p_pass: float = 0.75, return_audio: bool = False):
    """One training example: (features, target, weight, info)."""
    rng = np.random.default_rng(seed)
    bg = pool[int(rng.integers(len(pool)))]
    n = int(seconds * SR)
    i = int(rng.integers(0, max(1, len(bg) - n)))
    x = bg[i: i + n].copy()
    if len(x) < n:
        x = np.pad(x, (0, n - len(x)))
    x *= 10 ** (rng.uniform(-10, 10) / 20)
    if rng.random() < 0.3:                                   # a second background on top
        bg2 = pool[int(rng.integers(len(pool)))]
        j = int(rng.integers(0, max(1, len(bg2) - n)))
        x2 = np.pad(bg2[j: j + n], (0, max(0, n - len(bg2[j: j + n]))))
        x += x2 * (x.std() / (x2.std() + 1e-12)) * 10 ** (rng.uniform(-10, 0) / 20)
    truth, snr = [], None
    if rng.random() < p_pass:
        p = passes.draw(rng, seconds)
        snr = float(rng.uniform(3, 24))
        x, truth = passes.mix(x, SR, p, snr, rng)
    if return_audio:
        return x
    F, t = features(x, SR)
    y, w = labels(truth, snr or 0.0, t) if truth else (np.zeros_like(F), np.ones_like(F))
    return F, y, w, {"seed": seed, "snr": snr}


def make_dataset(path: Path, pool_sessions: list[str], count: int, seed0: int, workers: int = 2):
    """Write `count` examples to an .npz (features, targets, weights) for training."""
    from multiprocessing import Pool
    with Pool(workers, initializer=_init_pool, initargs=(pool_sessions,)) as pool:
        ex = pool.map(_example, range(seed0, seed0 + count), chunksize=4)
    F = np.stack([e[0] for e in ex]).astype(np.float16)
    Y = np.stack([e[1] for e in ex]).astype(np.uint8)
    W = np.stack([e[2] for e in ex]).astype(np.uint8)
    np.savez(path, F=F, Y=Y, W=W, info=json.dumps([e[3] for e in ex]))
    return path


_POOL: list = []


def _init_pool(sessions):
    global _POOL
    _POOL = background_pool(sessions)


def _example(seed):
    return example(_POOL, seed)


# --- model ---------------------------------------------------------------------------------

DILATIONS = (1, 2, 4, 8, 16, 32)
CH = 16


def init(key) -> dict:
    import jax
    import jax.numpy as jnp
    ks = jax.random.split(key, len(DILATIONS) + 2)
    he = lambda k, shape: jax.random.normal(k, shape) * np.sqrt(2 / np.prod(shape[:-1]))
    params = {"in_w": he(ks[0], (5, 5, 1, CH)), "in_b": jnp.zeros(CH)}
    for i, _ in enumerate(DILATIONS):
        params[f"w{i}"] = he(ks[i + 1], (3, 3, CH, CH)) * 0.5
        params[f"b{i}"] = jnp.zeros(CH)
    params["out_w"] = he(ks[-1], (1, 1, CH, 1)) * 0.1
    params["out_b"] = jnp.full(1, -3.0)                      # start near "nothing here"
    return params


def apply(params: dict, F):
    """F: (batch, NBINS, frames) → logits, same shape. Frequency is the first spatial axis."""
    import jax
    dn = ("NHWC", "HWIO", "NHWC")
    x = F[..., None]
    x = jax.nn.relu(jax.lax.conv_general_dilated(x, params["in_w"], (1, 1), "SAME", dimension_numbers=dn) + params["in_b"])
    for i, d in enumerate(DILATIONS):
        h = jax.lax.conv_general_dilated(x, params[f"w{i}"], (1, 1), "SAME", rhs_dilation=(1, d), dimension_numbers=dn)
        x = x + jax.nn.relu(h + params[f"b{i}"])
    out = jax.lax.conv_general_dilated(x, params["out_w"], (1, 1), "SAME", dimension_numbers=dn) + params["out_b"]
    return out[..., 0]


def loss_fn(params, F, Y, W, pos_weight: float = 20.0):
    import jax
    import jax.numpy as jnp
    z = apply(params, F)
    # Weighted binary cross-entropy: on-curve pixels are rare.
    l = pos_weight * Y * jax.nn.softplus(-z) + (1 - Y) * jax.nn.softplus(z)
    return jnp.sum(l * W) / (jnp.sum(W) + 1e-6)


def train(data: Path, out: Path, steps: int = 3_000, batch: int = 16, crop: int = 128, lr: float = 2e-3, seed: int = 0, log=print):
    import jax
    import optax
    d = np.load(data)
    F, Y, W = d["F"], d["Y"], d["W"]                     # float16, uint8, uint8
    rng = np.random.default_rng(seed)
    params = init(jax.random.PRNGKey(seed))
    opt = optax.adam(optax.cosine_decay_schedule(lr, steps))
    state = opt.init(params)

    @jax.jit
    def step(params, state, f, y, w):
        l, g = jax.value_and_grad(loss_fn)(params, f, y, w)
        upd, state = opt.update(g, state, params)
        return optax.apply_updates(params, upd), state, l

    t0, run = time.time(), []
    for s in range(steps):
        i = rng.integers(0, len(F), batch)
        j = rng.integers(0, F.shape[2] - crop + 1, batch)
        fb = np.stack([F[a, :, b: b + crop] for a, b in zip(i, j)]).astype(np.float32)
        yb = np.stack([Y[a, :, b: b + crop] for a, b in zip(i, j)]).astype(np.float32)
        wb = np.stack([W[a, :, b: b + crop] for a, b in zip(i, j)]).astype(np.float32)
        params, state, l = step(params, state, fb, yb, wb)
        run.append(float(l))
        if (s + 1) % 200 == 0:
            log(f"step {s + 1}: loss {np.mean(run[-200:]):.4f} ({time.time() - t0:.0f} s)")
        if (s + 1) % 500 == 0:                                  # a checkpoint to evaluate early
            np.savez(out, **{k: np.asarray(v) for k, v in params.items()})
    np.savez(out, **{k: np.asarray(v) for k, v in params.items()})
    return out


def load(path: Path) -> dict:
    import jax.numpy as jnp
    d = np.load(path)
    return {k: jnp.asarray(d[k]) for k in d.files}


_JIT = None


def predict(params: dict, F: np.ndarray) -> np.ndarray:
    """Probability map for one clip's features (NBINS × frames)."""
    global _JIT
    import jax
    if _JIT is None:
        _JIT = jax.jit(apply)
    return np.asarray(jax.nn.sigmoid(_JIT(params, F[None]))[0])


def n_params(params: dict) -> int:
    return int(sum(np.prod(v.shape) for v in params.values()))


# --- detector ------------------------------------------------------------------------------

def windows(params: dict, x: np.ndarray, sr: int, floor: float = 0.15, win_s: float = 10.0) -> list[tuple]:
    """Every 10 s window (every 2.5 s) whose best smooth falling path through the model's log-odds
    has a mean probability of at least `floor` and fits a flyby once placed finely:
    (t0, t1, f_lo, f_hi, mean prob)."""
    F, _ = features(x, sr)
    return _detect_from_features(params, F, floor, win_s)


def group(wins: list[tuple], threshold: float, min_windows: int = 2) -> list[tuple]:
    """Passes: windows at or above `threshold` joined where they overlap in time and frequency;
    a pass needs `min_windows` of them (a real pass bends over 20–30 s, as the check requires).
    (t0, t1, f_lo, f_hi, best mean prob)."""
    out, cur = [], None
    for w in sorted((w for w in wins if w[4] >= threshold), key=lambda w: w[0]):
        if cur and w[0] < cur[1] and w[2] <= cur[3] * 1.03 and w[3] >= cur[2] * 0.97:
            cur = [cur[0], max(cur[1], w[1]), min(cur[2], w[2]), max(cur[3], w[3]), max(cur[4], w[4]), cur[5] + 1]
        else:
            if cur and cur[5] >= min_windows:
                out.append(tuple(cur[:5]))
            cur = [*w, 1]
    if cur and cur[5] >= min_windows:
        out.append(tuple(cur[:5]))
    return out


def detect_passes(params: dict, x: np.ndarray, sr: int, threshold: float, min_windows: int = 2) -> list[tuple]:
    """Passes the model proposes and the flyby fit accepts (see `windows` and `group`)."""
    return group(windows(params, x, sr), threshold, min_windows)


# --- the split and the experiment -------------------------------------------------------------

# Plane-free recorder sessions, split by session so no test background is ever trained on.
TRAIN_SESSIONS = ["20261104T082022Z_f74a40", "20261104T083314Z_a2f229", "20261104T084455Z_94d99a",
                  "20261104T090113Z_e9a1c3", "20261104T173439Z_1f57cd"]
TEST_SESSIONS = ["20261105T053504Z_f8b75a", "20261105T160319Z_9f5d28", "20261105T161812Z_cf7ad9",
                 "20261105T190941Z_454d2c"]
# Sessions with a real pass the known-path attacker finds: test only.
REAL_PASSES = {"20261104T174102Z_efb8f8": 76.2, "20261105T083825Z_37a954": 57.6, "20261105T193328Z_af39e1": 66.6}


def calibrate(params: dict, pool: list[np.ndarray], minutes: float = 60, fa_per_hour: float = 1.0, seed0: int = 900_000) -> float:
    """The probability threshold giving about `fa_per_hour` false passes on pass-free training
    backgrounds (never the test sessions)."""
    scores = []
    for k in range(int(minutes * 60 / 30)):
        x = example(pool, seed0 + k, p_pass=0.0, return_audio=True)
        scores += [b[4] for b in detect_passes(params, x, SR, threshold=0.15)]   # pass-level scores
    scores = sorted(scores, reverse=True)
    allowed = int(fa_per_hour * minutes / 60)
    return float(scores[allowed] + 1e-6) if len(scores) > allowed else 0.15


def refine(bins: np.ndarray, cols: np.ndarray, prob: np.ndarray) -> np.ndarray:
    """A path's frequency per frame, finer than a log bin: a parabola through the model's
    probability at the bin and its neighbours, then smoothed over ~2 s (a Doppler curve is smooth).
    A 2 % log bin alone would make every path fail the flyby fit's 0.5 % rms; the loudest linear
    bin nearby is worse (at low strength it's noise)."""
    from scipy.signal import savgol_filter
    logc, step = np.log(CENTERS), np.log(EDGES[1] / EDGES[0])
    out = np.empty(len(bins))
    for i, (b, c) in enumerate(zip(bins, cols)):
        out[i] = logc[b]
        if 0 < b < NBINS - 1:
            a, m, z = prob[b - 1, c], prob[b, c], prob[b + 1, c]
            den = a - 2 * m + z
            if den < 0:
                out[i] += float(np.clip(0.5 * (a - z) / den, -0.5, 0.5)) * step
    return np.exp(savgol_filter(out, min(31, len(out) - (1 - len(out) % 2)), 2))


def _detect_from_features(params: dict, F: np.ndarray, threshold: float, win_s: float = 10.0) -> list[tuple]:
    from . import detect
    dt = HOP / SR
    t = (N_FFT / 2 + np.arange(F.shape[1]) * HOP) / SR
    prob = predict(params, F)
    pc = np.clip(prob, 1e-4, 1 - 1e-4)
    A = np.clip(np.log(pc / (1 - pc)), -6, 6)
    p = detect.Params(win_s=win_s, slopes=(0, 1, 2), penalty=2.0, min_drop=0.02)
    out = []
    for w in detect.search(CENTERS, t, A, p):
        if not np.isfinite(w.score) or len(w.path) < 10:
            continue
        j0 = int(round((w.start - t[0]) / dt))
        bins = np.clip(np.searchsorted(EDGES, w.path) - 1, 0, NBINS - 1)
        cols = np.clip(np.arange(j0, j0 + len(bins)), 0, prob.shape[1] - 1)
        mp = float(prob[bins, cols].mean())
        if mp < threshold:
            continue
        path = refine(bins, cols, prob)
        if detect.shape_test(path, win_s, dt=dt)["ok"]:
            out.append((w.start, w.start + win_s, float(path.min()), float(path.max()), mp))
    return out


def report(model: Path) -> str:
    """The experiment's numbers, from saved windows (calibration, benchmark, real sessions):
    the threshold for about one false pass an hour on training backgrounds, then every detector
    on the benchmark's held-out clips and on the real recordings."""
    from . import bench
    out_dir = corpus.DATA / "ml"
    cal = json.load(open(out_dir / f"calib-{model.stem.split('-')[-1]}.json"))
    lines = []
    # Threshold: the lowest giving ≤ 1 false pass per hour on the 60 min of training negatives.
    hours = len(cal) * 30 / 3600
    th = 0.15
    for cand in np.arange(0.15, 1.0, 0.01):
        if sum(len(group([tuple(w) for w in ws], cand)) for ws in cal) / hours <= 1.0:
            th = float(cand)
            break
    lines.append(f"threshold {th:.2f} (≤ 1 false pass per hour on {len(cal) * 30 / 60:.0f} min of training backgrounds)\n")
    clips = bench.plan()
    rows = bench.run(clips)                                            # cached
    wins = bench.ml_windows(clips, model)                              # cached
    mlrows = bench.ml_rows(clips, wins, th)
    held_out = lambda r: r["background"].startswith("synth:") or any(s in r["background"] for s in TEST_SESSIONS)
    lines.append("Held-out backgrounds (test sessions; synthetic scenes, other seeds than training):\n")
    lines.append(bench.compare(rows, mlrows, held_out))
    lines.append("\nAll backgrounds (training sessions included, for scale):\n")
    lines.append(bench.compare(rows, mlrows, lambda r: True))
    real = json.load(open(out_dir / f"real-{model.stem.split('-')[-1]}.json"))
    lines.append("\n| real recording | passes found | on the real pass |\n| --- | ---: | ---: |")
    for key, ws in real.items():
        sid, version = key.split(":")
        ps = group([tuple(w) for w in ws], th)
        tc = REAL_PASSES.get(sid)
        on = sum(1 for p in ps if tc is not None and p[0] - 10 <= tc <= p[1] + 15)
        label = f"pass at {tc:.0f} s, {version}" if tc is not None else f"plane-free ({version})"
        lines.append(f"| {sid[-6:]} {label} | {len(ps)} | {on if tc is not None else '–'} |")
    return "\n".join(lines)
