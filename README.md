# octave-camo

[![CI](https://github.com/asleepace/octave-camo/actions/workflows/ci.yml/badge.svg)](https://github.com/asleepace/octave-camo/actions/workflows/ci.yml)

**Active camouflage for the sound in your videos.**

A video's soundtrack can give away where it was recorded. Aircraft, and anything else with a
public track, leave Doppler pitch curves in the background noise. An attacker can match those
curves against historical flight logs after you post. Faint, distant planes work too: integrating
along a predicted curve recovers tones far below what you can hear. octave-camo finds that
information and removes it without noticeably changing what a listener hears.

> Status: research prototype. The defenses are validated on synthetic clips, not yet on a real
> recording with flight-log ground truth. Treat it as "reduces location leakage", never
> "guarantees privacy".

## Quick start

The Bun/TypeScript harness runs today (attackers, modular defenses, benchmarks):

```sh
cd harness && bun install
bun run scrub clip.mov clip.camo.mp4            # default chain: hum+subtract+lowband (offline)
bun run scrub --list                            # every defense module and its options
bun test                                        # 88 tests
bun run bench:defenses                          # chains × synthetic clips × both attackers
```

The Swift package is the start of the iOS library. It builds, and its 19 tests pass in CI on
macOS and Linux. It has the original pipeline (hum, tone subtraction, wobble); the modular
defenses (`lowband` and friends) live in the harness for now.

```sh
swift build -c release && swift test -c release
scripts/roundtrip.sh                            # synth → attack → scrub → AAC 128k → attack
scripts/scrub-video.sh in.mov                   # Swift CLI on a video (picture copied, metadata stripped)
```

See [harness/README.md](harness/README.md) for the attackers, defenses and results, and
[IDEAS.md](IDEAS.md) for what's next.

## Layout

```
Sources/
  OctaveCamoKit/              library — what the iOS app imports
    Audio/      Audio (planar PCM), WAV read/write
    DSP/        FFT + RealFFT, Biquad, SeededRNG, DSP helpers
    Model/      FlybyGeometry — the flyby physics, shared by synth and fitter
    Analysis/   ToneTracker, FlybyAnalyzer (the attacker), NelderMead
    Scrub/      ScrubPipeline and its stages: HumNotch, ToneSubtraction, BandWobble
    Synth/      FlybySynth — known-truth test clips
  octave-camo/                thin CLI: argument parsing, commands, output formatting
Tests/OctaveCamoKitTests/     DSP correctness, physics, WAV round trip, attacker vs. defense
reference/                    NumPy prototype the published numbers came from (frozen)
scripts/                      ffmpeg wrappers
harness/                      Bun/TypeScript: attackers, modular defenses, benchmarks, ground truth
IDEAS.md                      backlog: other leaky sources (trains, ships, ENF in video), next steps
```

## Using the library

```swift
import OctaveCamoKit

var pipeline = ScrubPipeline()          // mono → hum → subtract → wobble
pipeline.hum.mains = 50                 // e.g. for EU footage
let result = pipeline.run(audio)        // Audio in, mono Audio out
result.log.forEach { print($0) }

let risk = FlybyAnalyzer().analyze(result.audio)
print(risk.consensus == nil ? "clean" : "flyby still recoverable")
```

To check the attack and the scrub against a real recording and the aircraft's actual ADS-B track,
see [harness/README.md](harness/README.md).

Every stage is a plain struct with tunable properties and defaults; set `pipeline.steps` to
switch stages off.

## Commands

| Command | Role | What it does |
|---|---|---|
| `synth out.wav [--hard]` | test data | Known-truth flyby (120 Hz + harmonics, 75 m/s, 1500 m, t₀ = 30 s), 60 Hz hum with ENF wander, pink noise, speech-like syllables |
| `analyze in.wav [--threshold dB] [--json]` | attacker | Tracks tones lasting > 2 s, fits a straight-line flyby (with propagation delay), reports distance / speed / t₀ |
| `scrub in.wav out.wav` | defense | Mono → hum notches → tone subtraction (3 passes) → per-band wobble below 600 Hz |

`scrub` flags: `--steps mono,hum,subtract,wobble`, `--mains 60|50`, `--passes 3`,
`--depth 0.015`, `--wobble-top 600` (400 is gentler on voices, see below), `--seed N`.

## How the scrub works

1. **Mono** removes direction of arrival from multi-mic recordings.
2. **Hum notches** (60 Hz harmonics below 400 Hz, Q = 30, zero-phase) remove the ENF clock.
3. **Subtraction**: for each long tone, heterodyne with the tracked phase, low-pass (0.15 s,
   centered) to get its complex amplitude, resynthesize and subtract. Re-track the residual
   and repeat.
4. **Wobble**: split 30–600 Hz into 8 bands (crossovers sum to 1) and give each band its own
   slow random frequency drift (±1.5 %, 1–4 s periods). Harmonics of one plane land in
   different bands, so the drift can't be estimated from one and divided out of the others.
   Applied at a decimated rate and summed into one spectrum: two full-size FFTs instead of one
   per band.

## Results (NumPy reference, after AAC 128 kbps re-encode)

| Case | Before | After scrub |
|---|---|---|
| Clean flyby | d = 1500 m on all 3 harmonics (±0.1 %) | no tracks found, even at 3 dB sensitivity; tone cancelled 33–38 dB |
| `--hard` (turbulence + multipath) | d = 1467–1474 m (−2 %) | ~20 dB cancelled; at 3 dB sensitivity one short fragment with a wrong speed (169 vs 75 m/s) |
| Speech 500 Hz–4 kHz | — | no measurable change |

**Why the wobble stops at 600 Hz by default.** On 30 s `--hard` clips across 3 seeds, an attacker
at 6 dB sensitivity recovered a fit within 10 % of the true distance on 1 of 3 seeds when the
wobble stopped at 400 Hz (a stray 3rd-harmonic fragment: 1510 m, but the wrong speed). At 600 Hz,
0 of 3 seeds at either 6 or 3 dB, and the leftover fits scatter between 3 and 338 m. Cost: about
0.5 dB in the 500 Hz–4 kHz speech band.

## Limits

- Synthetic flybys only; real recordings will have more than one aircraft, wind, and traffic.
- The whole clip is processed in memory (the wobble uses one FFT the size of the clip, about
  64 MB per minute at 48 kHz). The iOS app should process long videos in overlapping blocks.
- `reference/` is the prototype the numbers above came from. The Swift code mirrors its
  algorithms and defaults, except the faster wobble (matches the original to better than
  −60 dB) and different random streams, so exact figures won't match.

## License

MIT, see [LICENSE](LICENSE).
