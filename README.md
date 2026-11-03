<img src="web/public/icon.svg" width="72" alt="" />

# octave-camo

[![CI](https://github.com/asleepace/octave-camo/actions/workflows/ci.yml/badge.svg)](https://github.com/asleepace/octave-camo/actions/workflows/ci.yml)

**Active camouflage for the sound in your videos.**

A video's soundtrack can give away where it was recorded. Aircraft, and anything else with a
public track, leave Doppler pitch curves in the background noise. An attacker can match those
curves against historical flight logs after you post. Faint, distant planes work too: integrating
along a predicted curve recovers tones far below what you can hear. octave-camo finds that
information and removes it without noticeably changing what a listener hears.

> **Proof of concept.** octave-camo is in active development and provides no guarantee of
> anonymity. It has only been tested on synthetic recordings and needs more testing and
> independent verification. Don't rely on it to protect your location. See
> [THREAT_MODEL.md](THREAT_MODEL.md) for what is and isn't covered.

## Use it

**In the browser:** [asleepace.github.io/octave-camo](https://asleepace.github.io/octave-camo/).
Drop a video, press CLOAK, save. Everything runs on your device: the Swift scrubber is
compiled to WebAssembly, and nothing is uploaded. The saved file keeps the original video
stream untouched and gets a new AAC audio track, with no metadata. The picture is also
scanned for light flicker (the grid clock in rolling-shutter bands); if it's found, you can
remove it, which re-encodes the picture.

## Quick start (development)

```sh
swift build -c release && swift test -c release      # library + CLI (macOS, Linux)
scripts/build-wasm.sh                                # WebAssembly build (Swift 6.4.2 + wasm SDK)
cd web && bun install && bun run dev                 # web app (uses a dev stand-in without the wasm)
cd harness && bun install && bun test                # attackers, defenses, benchmarks
bun run bench:defenses                               # chains × synthetic clips × both attackers
```

CI builds and tests all of it on every push (macOS, Linux, WebAssembly, web, harness), and
deploys the web app from `main`.

## The default chain

`mono → hum → subtract → scurve → lowband`, the same in Swift, the web app and the harness:

1. **mono** averages channels, which removes direction of arrival.
2. **hum** notches mains harmonics (zero-phase, Q = 30), which removes the ENF clock.
3. **subtract** tracks long tones and cancels them: heterodyne with the tracked phase, low-pass to
   get the complex amplitude, resynthesize, subtract, re-track the residual, repeat.
4. **scurve** runs the attacker's own trick blind: it scores every physically possible flyby
   curve (speed, distance, closest-approach time) by integrating energy along it in a
   log-frequency spectrogram, then cancels the best candidates. This catches faint tones
   above the lowband cutoff, such as train wheels.
5. **lowband** regenerates everything below the cutoff (300 Hz) as noise that matches each
   critical band's loudness over time, slowly smoothed and re-gained. It keeps tracked voice
   harmonics. Nothing narrow survives for a matched filter to lock on to.

`wobble` (per-band random pitch drift) is still available, but it's off by default:
benchmarks showed it adds little once `lowband` runs.

Results are in [THREAT_MODEL.md](THREAT_MODEL.md) (trains, ships) and
[harness/README.md](harness/README.md) (aircraft).

## Layout

```
Sources/
  OctaveCamoKit/      pure-Swift DSP, no Foundation: builds for iOS, macOS, Linux, WebAssembly
    DSP/              FFT + RealFFT, Biquad, SeededRNG, low-band STFT, ERB scale
    Model/            FlybyGeometry: the flyby physics, shared by synth, fitter and scurve
    Analysis/         ToneTracker, FlybyAnalyzer (the blind attacker), PitchTracker (YIN),
                      FlickerScan (light flicker in video: scan and removal gains)
    Scrub/            ScrubPipeline: HumNotch, ToneSubtraction, SCurveCancel,
                      LowBandRegeneration, BandWobble
    Synth/            FlybySynth: known-truth test clips
  OctaveCamoIO/       WAV read/write (Foundation)
  OctaveCamoWasm/     WebAssembly exports for the web app (WASI reactor)
  octave-camo/        CLI
Tests/                Swift tests: DSP, physics, attacker vs. defense, lowband, scurve
web/                  the web app: Vite + TypeScript + Tailwind, worker, Mediabunny remux
harness/              Bun/TypeScript: matched (ADS-B) attacker, defense modules, benchmarks,
                      OpenSky / Flightradar24 ground truth
reference/            NumPy prototype and synthetic clip generators
scripts/              wasm build, ffmpeg wrappers
THREAT_MODEL.md       channels, attacker, evidence, known gaps
IDEAS.md              backlog
```

## Using the library

```swift
import OctaveCamoKit

var pipeline = ScrubPipeline()          // mono → hum → subtract → scurve → lowband
pipeline.hum.mains = 50                 // e.g. for EU footage
pipeline.lowband.cutoff = 250
let result = pipeline.run(audio)        // Audio in, mono Audio out
result.log.forEach { print($0) }

let risk = FlybyAnalyzer().analyze(result.audio)
print(risk.consensus == nil ? "clean" : "flyby still recoverable")
```

Every stage is a plain struct with tunable properties; set `pipeline.steps` to switch stages
on or off.

## CLI

| Command | Role | What it does |
|---|---|---|
| `synth out.wav [--hard]` | test data | Known-truth flyby (120 Hz + harmonics, 75 m/s, 1500 m, t₀ = 30 s), 60 Hz hum with ENF wander, pink noise, speech-like syllables |
| `analyze in.wav [--threshold dB] [--json]` | attacker | Tracks tones lasting > 2 s, fits a straight-line flyby (with propagation delay), reports distance / speed / t₀ |
| `scrub in.wav out.wav` | defense | The default chain above |

`scrub` flags: `--steps mono,hum,subtract,scurve,lowband[,wobble]`, `--mains 60|50`,
`--passes 3`, `--cutoff 300`, `--lowband-mode regenerate|highpass`, `--no-keep-voice`,
`--depth 0.015` and `--wobble-top 600` (wobble only), `--seed N`.
`scripts/scrub-video.sh in.mov` runs it on a video (picture copied, metadata stripped).

## Limits

- Every number is from synthetic clips so far. Real recordings, with several aircraft, wind
  and traffic, are being collected.
- The whole clip is processed in memory. The web app caps clips at 5 minutes; the iOS app
  should process long videos in overlapping blocks.
- The web app's output is mono: averaging channels is itself one of the defenses.

## License

MIT, see [LICENSE](LICENSE).
