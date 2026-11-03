import sys, numpy as np, proto
sr = 48000
def tone_level(path):
    # coherent measurement with the TRUE Doppler phase (best possible attacker knowledge)
    _, y = proto.read(path); y = y.mean(1); n = len(y); t = np.arange(n)/sr
    f, _ = proto.doppler(t, 120, 75, 30, 1500)
    out = []
    for k in (1, 2, 3):
        ph = 2*np.pi*np.cumsum(k*f)/sr
        L = int(0.15*sr); box = np.ones(L)/L
        A = np.convolve(y*np.exp(-1j*ph), box, 'same')
        out.append(20*np.log10(np.mean(np.abs(A))+1e-12))
    return np.array(out)
base = tone_level('v_original_aac.wav')
for name in ['mono+hum+subtract', 'full']:
    p = f'v_{name}_aac.wav'
    print(f'{name}: cancellation per harmonic (dB):', np.round(tone_level(p)-base, 1))
    for th in (6.0, 3.0):
        res = proto.analyze(p, quiet=True, thresh_db=th)
        dop = [r for r in res if r['kind']=='doppler' and 100 < r['f0'] < 400 and r['dur'] > 4]
        print(f'  attacker thresh {th} dB -> {len(dop)} doppler fits', [(round(r['f0']), round(r['d']), round(r['dur'],1)) for r in dop][:5])
