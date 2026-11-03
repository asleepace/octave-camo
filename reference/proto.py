"""NumPy prototype of octave-camo (frozen). Same algorithms as the Swift package except the
faster decimated wobble; defaults here are the older ones (2 passes, wobble to 400 Hz)."""
import sys, json
import numpy as np
from scipy.io import wavfile

C = 343.0

# ---------- physics ----------
def emission_times(t, v, d, t0e):
    # solve tau + r(tau)/c = t  (Newton; g' > 0 since v < c)
    tau = t - d / C
    for _ in range(8):
        dx = v * (tau - t0e)
        r = np.sqrt(dx * dx + d * d)
        g = tau + r / C - t
        gp = 1 + v * dx / (C * r)
        tau = tau - g / gp
    return tau

def doppler(t, f0, v, t0, d):
    """t0 = received time of closest approach."""
    t0e = t0 - d / C
    tau = emission_times(t, v, d, t0e)
    dx = v * (tau - t0e)
    r = np.sqrt(dx * dx + d * d)
    vr = -v * dx / r            # radial velocity toward observer
    return f0 / (1 - vr / C), r

# ---------- synth ----------
def synth(path, sr=48000, dur=60.0, f0=120.0, v=75.0, d=1500.0, t0=30.0, seed=1, hard=False):
    rng = np.random.default_rng(seed)
    n = int(sr * dur)
    t = np.arange(n) / sr
    f, r = doppler(t, f0, v, t0, d)
    amp = (d / r)
    # slow atmospheric amplitude wander
    wander = 1 + 0.3 * np.convolve(rng.standard_normal(n // 4800 + 10), np.ones(5) / 5, 'same')
    amp *= np.interp(t, np.linspace(0, dur, len(wander)), wander)
    x = np.zeros(n)
    if hard:  # turbulence: ~0.3% frequency jitter, band-limited to a few Hz
        j = rng.standard_normal(n // 480 + 10)
        j = np.convolve(j, np.ones(8) / 8, 'same'); j *= 0.003 / j.std()
        f = f * (1 + np.interp(t, np.linspace(0, dur, len(j)), j))
    for k, a in [(1, 1.0), (2, 0.6), (3, 0.4)]:
        ph = 2 * np.pi * np.cumsum(k * f) / sr
        x += 0.05 * a * amp * np.sin(ph)
    if hard:  # ground reflection: delayed copy whose delay drifts with geometry -> moving comb fades
        delay = 0.004 + 0.003 * np.cos(np.pi * (t - t0) / dur)
        idx = np.clip(np.arange(n) - (delay * sr), 0, n - 1)
        x = x + 0.7 * np.interp(idx, np.arange(n), x)
    # mains hum with ENF wander
    enf = 60 + 0.02 * np.sin(2 * np.pi * t / 17) + 0.01 * np.sin(2 * np.pi * t / 5.3)
    hum_ph = 2 * np.pi * np.cumsum(enf) / sr
    for k, a in [(1, 1.0), (2, 0.5), (3, 0.3)]:
        x += 0.004 * a * np.sin(k * hum_ph)
    # pinkish noise
    w = rng.standard_normal(n)
    W = np.fft.rfft(w); fr = np.fft.rfftfreq(n, 1 / sr); W[1:] /= np.sqrt(fr[1:]); W[0] = 0
    pink = np.fft.irfft(W, n); pink *= 0.01 / pink.std()
    x += pink
    # speech-like syllables: short harmonic stacks, 100-220 Hz f0, 0.15-0.4 s
    sp = np.zeros(n)
    tt = 0.5
    while tt < dur - 1:
        L = rng.uniform(0.15, 0.4); m = int(L * sr); i0 = int(tt * sr)
        p = rng.uniform(100, 220) * (1 + 0.1 * np.linspace(-1, 1, m) * rng.uniform(-1, 1))
        ph = 2 * np.pi * np.cumsum(p) / sr
        env = np.sin(np.pi * np.arange(m) / m) ** 2
        seg = sum((0.6 / k) * np.sin(k * ph) * (1.0 if k * 180 > 300 else 0.5) for k in range(1, 25))
        sp[i0:i0 + m] += 0.03 * env * seg
        tt += L + rng.uniform(0.05, 0.6)
    x += sp
    np.save(path.replace('.wav', '_speech.npy'), sp)
    x = np.stack([x, x * 0.9 + 0.002 * rng.standard_normal(n)], 1)  # fake stereo
    g = 1 / (np.abs(x).max() * 1.1); x *= g
    np.save(path.replace('.wav', '_speech.npy'), sp * g)
    wavfile.write(path, sr, x.astype(np.float32))
    return dict(f0=f0, v=v, d=d, t0=t0)

# ---------- I/O ----------
def read(path):
    sr, x = wavfile.read(path)
    x = x.astype(np.float64)
    if np.issubdtype(x.dtype, np.integer): pass
    if x.max() > 2: x /= 32768.0
    return sr, x if x.ndim == 2 else x[:, None]

# ---------- tracking ----------
WIN, HOP = 16384, 2048
FMIN, FMAX = 40.0, 1000.0

def tracks(mono, sr, min_dur=2.0, thresh_db=10.0):
    win = np.hanning(WIN)
    nfr = 1 + (len(mono) - WIN) // HOP
    binhz = sr / WIN
    lo, hi = int(FMIN / binhz), int(FMAX / binhz)
    active, done = [], []
    for fi in range(nfr):
        seg = mono[fi * HOP: fi * HOP + WIN] * win
        mag = np.abs(np.fft.rfft(seg))[:hi + 25] + 1e-12
        db = 20 * np.log10(mag)
        peaks = []
        for k in range(lo, hi):
            if db[k] > db[k - 1] and db[k] >= db[k + 1]:
                floor = np.median(db[max(k - 20, 0):k + 21])
                if db[k] - floor > thresh_db:
                    a, b, c = db[k - 1], db[k], db[k + 1]
                    off = 0.5 * (a - c) / (a - 2 * b + c)
                    peaks.append(((k + off) * binhz, b))
        peaks.sort(key=lambda p: -p[1]); peaks = peaks[:24]
        tc = (fi * HOP + WIN / 2) / sr
        used = set()
        for tr in active:
            pred = tr['f'][-1]
            tol = max(3.0, 0.02 * pred)
            best, bd = None, tol
            for j, (pf, pa) in enumerate(peaks):
                if j in used: continue
                if abs(pf - pred) < bd: best, bd = j, abs(pf - pred)
            if best is not None:
                used.add(best); tr['t'].append(tc); tr['f'].append(peaks[best][0]); tr['a'].append(peaks[best][1]); tr['miss'] = 0
            else:
                tr['miss'] += 1
        still = []
        for tr in active:
            (done if tr['miss'] > 3 else still).append(tr)
        active = still
        for j, (pf, pa) in enumerate(peaks):
            if j not in used:
                active.append(dict(t=[tc], f=[pf], a=[pa], miss=0))
    done += active
    out = []
    for tr in done:
        if tr['t'][-1] - tr['t'][0] >= min_dur:
            out.append({k: np.array(tr[k]) for k in 'tfa'})
    return out

def is_hum(tr):
    f = tr['f']
    m = f.mean()
    if f.std() > 0.6 or (f.max() - f.min()) / m > 0.05: return False
    return any(abs(m - round(m / b) * b) < 1.0 for b in (50.0, 60.0))

# ---------- Doppler fit ----------
def nelder_mead(fun, x0, scale, iters=600):
    n = len(x0)
    pts = [np.array(x0, float)] + [np.array(x0, float) + np.eye(n)[i] * scale[i] for i in range(n)]
    vals = [fun(p) for p in pts]
    for _ in range(iters):
        o = np.argsort(vals); pts = [pts[i] for i in o]; vals = [vals[i] for i in o]
        cen = np.mean(pts[:-1], 0)
        xr = cen + (cen - pts[-1]); fr_ = fun(xr)
        if fr_ < vals[0]:
            xe = cen + 2 * (cen - pts[-1]); fe = fun(xe)
            pts[-1], vals[-1] = (xe, fe) if fe < fr_ else (xr, fr_)
        elif fr_ < vals[-2]:
            pts[-1], vals[-1] = xr, fr_
        else:
            xc = cen + 0.5 * (pts[-1] - cen); fc = fun(xc)
            if fc < vals[-1]: pts[-1], vals[-1] = xc, fc
            else:
                for i in range(1, n + 1):
                    pts[i] = pts[0] + 0.5 * (pts[i] - pts[0]); vals[i] = fun(pts[i])
    i = int(np.argmin(vals)); return pts[i], vals[i]

def fit(tr):
    t, f = tr['t'], tr['f']
    # init from shape
    fs = np.convolve(f, np.ones(5) / 5, 'same')
    sl = np.gradient(fs, t)
    k = np.argmin(sl[3:-3]) + 3
    fmax, fmin = f[:max(3, len(f)//10)].mean(), f[-max(3, len(f)//10):].mean()
    beta = np.clip((fmax - fmin) / (fmax + fmin), 0.01, 0.9)
    f0 = 0.5 * (fmax + fmin); v = float(np.clip(beta * C, 10, 330))
    d = np.clip(f0 * beta * v / max(abs(sl[k]), 1e-3), 20, 30000)
    t0 = t[k]
    def loss(p):
        f0_, v_, t0_, ld = p; d_ = np.exp(ld)
        if not (5 < v_ < 340): return 1e9
        m, _ = doppler(t, f0_, v_, t0_, d_)
        return np.mean((m - f) ** 2)
    best = None
    for dmul in (0.5, 1, 2):
        p, val = nelder_mead(loss, [f0, v, t0, np.log(d * dmul)], [0.02 * f0, 0.2 * v, 1.0, 0.5])
        if best is None or val < best[1]: best = (p, val)
    p, val = best
    sweep = (f.max() - f.min()) / f.mean()
    return dict(f0=p[0], v=p[1], t0=p[2], d=float(np.exp(p[3])), rms=float(np.sqrt(val)),
                dur=float(t[-1] - t[0]), fmin=float(f.min()), fmax=float(f.max()), sweep=float(sweep))

def analyze(path, quiet=False, thresh_db=10.0):
    sr, x = read(path)
    mono = x.mean(1)
    trs = tracks(mono, sr, thresh_db=thresh_db)
    res = []
    for tr in trs:
        if is_hum(tr):
            res.append(dict(kind='hum', f=float(tr['f'].mean()), dur=float(tr['t'][-1] - tr['t'][0]), std=float(tr['f'].std())))
            continue
        if (tr['f'].max() - tr['f'].min()) / tr['f'].mean() < 0.01:
            res.append(dict(kind='steady', f=float(tr['f'].mean()), dur=float(tr['t'][-1] - tr['t'][0])))
            continue
        r = fit(tr); r['kind'] = 'doppler' if r['rms'] / r['f0'] < 0.005 else 'nofit'; res.append(r)
    if not quiet:
        for r in res: print(json.dumps({k: (round(v, 3) if isinstance(v, float) else v) for k, v in r.items()}))
    return res

# ---------- scrub ----------
def biquad_notch(x, f, q, sr):
    from scipy.signal import lfilter
    w = 2 * np.pi * f / sr; al = np.sin(w) / (2 * q); cw = np.cos(w)
    b = np.array([1, -2 * cw, 1]); a = np.array([1 + al, -2 * cw, 1 - al])
    return lfilter(b / a[0], a / a[0], x)

def subtract_tracks(y, sr, trs, lp_sec=0.15):
    n = len(y); ts = np.arange(n) / sr
    L = int(lp_sec * sr)
    box = np.ones(L) / L
    for tr in trs:
        t, f = tr['t'], tr['f']
        i0, i1 = max(int((t[0] - 0.2) * sr), 0), min(int((t[-1] + 0.2) * sr), n)
        tt = ts[i0:i1]
        finst = np.interp(tt, t, f)
        ph = 2 * np.pi * np.cumsum(finst) / sr
        e = np.exp(-1j * ph)
        z = y[i0:i1] * e
        A = np.convolve(np.convolve(z, box, 'same'), box, 'same')
        s = 2 * np.real(A * np.conj(e))
        fade = np.ones(len(tt)); m = min(int(0.2 * sr), len(tt) // 2)
        fade[:m] = np.linspace(0, 1, m); fade[-m:] = np.linspace(1, 0, m)
        y[i0:i1] -= s * fade
    return y

BANDS = [30, 55, 80, 110, 150, 200, 270, 400]
XO = 0.15   # crossover width (fraction of edge freq)

def narrowband_flatten(y, sr, fmax=1000.0, win=65536, hop=16384, half_width=4, ceiling=1.5):
    """Caps each STFT bin below fmax at `ceiling` x the median magnitude of its +-half_width
    neighbors (phase kept). Steady narrowband tones are flattened even when far below any
    detection threshold; broadband rumble and pitch-varying speech harmonics mostly pass."""
    from scipy.signal import stft, istft
    from scipy.ndimage import median_filter
    f, t, Z = stft(y, sr, window='hann', nperseg=win, noverlap=win - hop, boundary='even', padded=True)
    k = f <= fmax
    mag = np.abs(Z[k])
    local = median_filter(mag, size=(2 * half_width + 1, 1), mode='nearest')
    capped = np.minimum(mag, ceiling * local)
    Z[k] *= np.where(mag > 0, capped / np.maximum(mag, 1e-30), 1)
    _, out = istft(Z, sr, window='hann', nperseg=win, noverlap=win - hop, boundary=True)
    return out[:len(y)]

def band_wobble(y, sr, depth=0.015, seed=None, slow_depth=0.0):
    rng = np.random.default_rng(seed)
    n = len(y); N = 1 << int(np.ceil(np.log2(n)))
    Y = np.fft.fft(y, N)
    fr = np.abs(np.fft.fftfreq(N, 1 / sr))
    def ramp(f, edge):  # 0 below, 1 above, raised-cosine across edge
        w = XO * edge
        u = np.clip((f - (edge - w)) / (2 * w), 0, 1)
        return 0.5 - 0.5 * np.cos(np.pi * u)
    ramps = [ramp(fr, e) for e in BANDS]
    masks = [ramps[i] - ramps[i + 1] for i in range(len(BANDS) - 1)]
    rest = 1 - sum(masks)
    out = np.real(np.fft.ifft(Y * rest))[:n]
    pos = np.fft.fftfreq(N, 1 / sr) > 0
    t = np.arange(n) / sr
    for i, m in enumerate(masks):
        fc = np.sqrt(BANDS[i] * BANDS[i + 1])
        Z = Y * m * pos * 2
        z = np.fft.ifft(Z)[:n]
        r = np.zeros(n)
        for _ in range(3):
            per = rng.uniform(1.0, 4.0)
            r += np.sin(2 * np.pi * t / per + rng.uniform(0, 2 * np.pi))
        r *= depth / 3 * 1.0
        if slow_depth > 0:   # slow components: corrupt gentle trends from distant aircraft
            for _ in range(2):
                r += slow_depth / 2 * np.sin(2 * np.pi * t / rng.uniform(15.0, 60.0) + rng.uniform(0, 2 * np.pi))
        psi = 2 * np.pi * np.cumsum(r * fc) / sr
        out += np.real(z * np.exp(1j * psi))
    return out

def scrub(inp, outp, mains=60.0, passes=2, depth=0.015, seed=None, steps=('mono', 'hum', 'subtract', 'wobble'),
          slow_depth=0.0):
    sr, x = read(inp)
    y = x.mean(1) if 'mono' in steps else x[:, 0]
    if 'hum' in steps:
        k = 1
        while k * mains < 400:
            y = biquad_notch(y, k * mains, 30.0, sr); y = biquad_notch(y[::-1], k * mains, 30.0, sr)[::-1]
            k += 1
    if 'subtract' in steps:
        for _ in range(passes):
            trs = tracks(y, sr)
            if not trs: break
            y = subtract_tracks(y, sr, trs)
    if 'flatten' in steps:
        y = narrowband_flatten(y, sr)
    if 'wobble' in steps:
        y = band_wobble(y, sr, depth, seed, slow_depth=slow_depth)
    peak = np.abs(y).max()
    if peak > 0.99: y *= 0.99 / peak
    wavfile.write(outp, sr, y.astype(np.float32))

if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'synth': print(synth(sys.argv[2], hard=len(sys.argv) > 3))
    elif cmd == 'analyze': analyze(sys.argv[2])
    elif cmd == 'scrub': scrub(sys.argv[2], sys.argv[3], steps=tuple(sys.argv[4].split(',')) if len(sys.argv) > 4 else ('mono', 'hum', 'subtract', 'wobble'))
