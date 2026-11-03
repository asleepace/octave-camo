"""Round-trip bench: scrub variants -> AAC 128k (like X) -> attacker fitter."""
import subprocess, sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
import proto
from scipy.signal import butter, sosfiltfilt

D = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(D, os.environ.get('SRC', 'fly.wav'))
truth = dict(f0=120, v=75, d=1500, t0=30)

def aac(inp, outp):
    m4a = outp + '.m4a'
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', inp, '-c:a', 'aac', '-b:a', '128k', m4a], check=True)
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', m4a, '-c:a', 'pcm_f32le', outp], check=True)

def band_snr(a, b, sr, lo=500, hi=4000):
    sos = butter(6, [lo, hi], 'bandpass', fs=sr, output='sos')
    A, B = sosfiltfilt(sos, a), sosfiltfilt(sos, b)
    n = min(len(A), len(B)); A, B = A[:n], B[:n]
    g = (A @ B) / (B @ B)
    return 10 * np.log10((A @ A) / ((A - g * B) @ (A - g * B)))

variants = {
    'original': None,
    'mono+hum': ('mono', 'hum'),
    'mono+hum+subtract': ('mono', 'hum', 'subtract'),
    'full': ('mono', 'hum', 'subtract', 'wobble'),
}
S = np.load(src.replace('.wav', '_speech.npy'))
sr, x = proto.read(src); xm = x.mean(1)
for name, steps in variants.items():
    p = os.path.join(D, f"v_{os.environ.get('TAG','')}{name}.wav")
    if steps is None:
        proto.wavfile.write(p, sr, x.astype(np.float32))
    else:
        proto.scrub(src, p, steps=steps, seed=7)
    _, y = proto.read(p)
    snr = band_snr(S, y.mean(1), sr)
    q = p.replace('.wav', '_aac.wav'); aac(p, q)
    res = proto.analyze(q, quiet=True, thresh_db=float(os.environ.get('THRESH', 10)))
    hum = [r for r in res if r['kind'] == 'hum']
    dop = [r for r in res if r['kind'] == 'doppler']
    bad = [r for r in res if r['kind'] == 'nofit']
    print(f'\n== {name}: speech SNR {snr:5.1f} dB | hum tracks {len(hum)} | doppler fits {len(dop)} | failed fits {len(bad)}')
    for r in sorted(dop, key=lambda r: -r['dur'])[:4]:
        err = 100 * (r['d'] - truth['d']) / truth['d']
        print(f"   f0 {r['f0']:7.2f}  v {r['v']:6.1f}  t0 {r['t0']:6.2f}  d {r['d']:8.0f} m ({err:+6.1f}%)  dur {r['dur']:5.1f}s  rms {r['rms']:.3f}")
