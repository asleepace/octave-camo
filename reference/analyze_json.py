"""Stand-in for the Swift CLI with the same interface and JSON, backed by the NumPy prototype.

    python3 analyze_json.py analyze <in.wav> --json [--threshold 10]
    python3 analyze_json.py scrub <in.wav> <out.wav>

Uses the Swift package's current defaults (3 subtraction passes, wobble to 600 Hz) and its
flyby plausibility bounds, so the harness can run before the Swift build is verified.
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import proto

proto.BANDS = [30, 55, 80, 110, 150, 200, 270, 400, 600]
PLAUSIBLE_SPEED = (20.0, 300.0)
MIN_DISTANCE = 50.0
KIND = {'hum': 'hum', 'steady': 'steady', 'doppler': 'doppler', 'nofit': 'noFit'}


def analyze(path, threshold):
    tracks = []
    for r in proto.analyze(path, quiet=True, thresh_db=threshold):
        if 'fmin' in r:
            lo, hi, mean = r['fmin'], r['fmax'], (r['fmin'] + r['fmax']) / 2
        else:
            lo = hi = mean = r['f']
        kind = KIND[r['kind']]
        fit = None
        if kind in ('doppler', 'noFit'):
            fit = {'geometry': {'f0': r['f0'], 'speed': r['v'], 't0': r['t0'], 'distance': r['d']}, 'rms': r['rms']}
            plausible = PLAUSIBLE_SPEED[0] <= r['v'] <= PLAUSIBLE_SPEED[1] and r['d'] >= MIN_DISTANCE
            if kind == 'doppler' and not plausible:
                kind = 'noFit'
        tracks.append({'kind': kind, 'meanFrequency': mean, 'minFrequency': lo, 'maxFrequency': hi,
                       'duration': r['dur'], 'fit': fit})
    tracks.sort(key=lambda t: -t['duration'])
    flybys = [t for t in tracks if t['kind'] == 'doppler']
    consensus = None
    if flybys:
        w = [t['duration'] for t in flybys]
        avg = lambda k: sum(t['fit']['geometry'][k] * wi for t, wi in zip(flybys, w)) / sum(w)
        consensus = {'f0': min(t['fit']['geometry']['f0'] for t in flybys),
                     'speed': avg('speed'), 't0': avg('t0'), 'distance': avg('distance')}
    return {'consensus': consensus, 'tracks': tracks}


if __name__ == '__main__':
    args = sys.argv[1:]
    if args[:1] == ['analyze']:
        threshold = float(args[args.index('--threshold') + 1]) if '--threshold' in args else 10.0
        print(json.dumps(analyze(args[1], threshold), sort_keys=True))
    elif args[:1] == ['scrub']:
        # SCRUB_STEPS / SLOW_DRIFT override the defaults for experiments.
        steps = tuple(os.environ.get('SCRUB_STEPS', 'mono,hum,subtract,wobble').split(','))
        proto.scrub(args[1], args[2], passes=3, steps=steps, slow_depth=float(os.environ.get('SLOW_DRIFT', 0)))
    else:
        sys.exit(__doc__)
