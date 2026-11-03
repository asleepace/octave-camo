<img src="web/public/icon.svg" width="72" alt="" />

# octave-camo

[![CI](https://github.com/asleepace/octave-camo/actions/workflows/ci.yml/badge.svg)](https://github.com/asleepace/octave-camo/actions/workflows/ci.yml)

**Active camouflage for the sound (and light) in your videos.**

A video can give away where and when it was recorded even with its metadata stripped. Planes,
trains and ships within earshot leave Doppler pitch curves in the background noise, and their
positions are public: an attacker predicts the curve for every candidate place and time and checks
which one your audio matches, even for tones far too faint to hear. Mains hum, and the flicker of
mains-powered lights in the picture, carry the power grid's frequency drift, which is logged and
works as a timestamp. octave-camo removes those clues while keeping the picture, voices and the
overall sound.

> **Proof of concept.** octave-camo is in active development and provides no guarantee of
> anonymity. It has only been tested on synthetic recordings and needs more testing and
> independent verification. Don't rely on it to protect your location. See
> [THREAT_MODEL.md](THREAT_MODEL.md) for what is and isn't covered.

## What it removes

| Side channel | What it gives away | What octave-camo does |
| --- | --- | --- |
| Doppler curves of planes, trains, ships | Your position, matched against public tracks (ADS-B, transit feeds, AIS) | Cancels long tones, searches blind for flyby-shaped curves and cancels them, regenerates the low band as information-free noise |
| Mains hum | Recording time and grid region (ENF) | Notches both 50 and 60 Hz harmonic families and refills the notches, so neither the hum nor the notch pattern survives |
| Light flicker in the picture | The same grid timestamp, as rolling-shutter bands | Scans every frame; if found, divides the bands out (optional: re-encodes the picture) |
| Multiple mics, spatial-audio tracks | Direction of sounds | Mono output; extra audio tracks dropped |
| Metadata | GPS, device, timestamps, directly | No container metadata is copied: no tags, no creation time, a random file name |

It doesn't touch what the picture shows, what people say, or anything about the account that posts
it.

## Use it

**[asleepace.github.io/octave-camo](https://asleepace.github.io/octave-camo/)**: drop a video, press
CLOAK, save. Everything runs on your device; the Swift scrubber is compiled to WebAssembly and
nothing is uploaded. The saved MP4 has the original video stream (bit for bit, unless you remove
light flicker) and a new mono AAC audio track, with no metadata.

## Verify it yourself

You shouldn't have to take a privacy tool's word for it.

- **Nothing leaves your device.** The page has no code that sends anything anywhere, and its
  Content-Security-Policy (`default-src 'none'; connect-src 'self' blob:`; see
  [web/vite.config.ts](web/vite.config.ts)) blocks requests, scripts, styles and fonts from any
  other origin. A CSP can't stop everything (it doesn't cover navigating the page away or WebRTC),
  so check for yourself: watch the Network tab in your browser's developer tools while you cloak a
  file, or load the page, go offline, and use it.
- **The picture is untouched.** Compare the video packets of the original and the cloaked file:

  ```sh
  ffmpeg -v error -i original.mov -map 0:v:0 -c copy -f streamhash -hash sha256 -
  ffmpeg -v error -i original.camo.mp4 -map 0:v:0 -c copy -f streamhash -hash sha256 -
  ```

- **The metadata is gone.** `ffprobe -show_format -show_streams original.camo.mp4` (or `exiftool`)
  shows no location, device or creation time.
- **The numbers below are reproducible.** `cd harness && bun install && bun run bench:gate`
  renders the benchmark clips, runs both attackers before and after cloaking, and fails if the
  default chain leaks. CI runs it on every push.

## Evidence

Synthetic clips, cloaked with the default chain, then re-encoded as 128 kbps AAC (as a platform
would). Two attackers: a blind tracker that fits flyby curves with no outside data, and a matched
attacker that has the source's true track, the exact recording time, and a 10 km search grid. A
leak means the true location was recovered within 1 km, above the attacker's noise floor on the
same scene with no source in it. CI checks both the harness's implementation of the default chain
and the Swift pipeline the web app runs.

| Clip | Uncloaked | Cloaked (default chain) | Sound change below / above 300 Hz |
| --- | --- | --- | --- |
| Distant jet (5.8 km, 25 dB below the noise) | matched attacker: found, 0 m off | not found | 3.0 / 0.2 dB |
| Same jet under speech | matched: found, 0 m | not found (68 % of low voice detail kept) | 3.1 / 0.2 dB |
| Close pass (1.5 km) | both attackers: found | not found* | 10.3 / 1.1 dB |
| Train, close (120 m) | matched: found, 0 m | not found | 3.2 / 1.3 dB |
| Train, distant (900 m) | both attackers: found | not found | 3.0 / 0.8 dB |
| Ship (400 m, 6 m/s) | matched: found, 0 m | not found* | 3.2 / 1.0 dB |

\* The thinnest margins: on these two, the matched attacker's best guess was still the true
location, just below its detection threshold. On the ship, that attacker scores about as high on
the same scene with no ship in it (a slow source's curve is nearly flat and matches anything), so
its result there says little either way. The close pass costs more sound because its tones are
loud and get cancelled.

Method, more cases (light flicker in the picture, the notch fingerprint) and the known gaps are in
[THREAT_MODEL.md](THREAT_MODEL.md).

## How it works

The default chain is `mono → hum → subtract → scurve → lowband`, the same in the Swift library, the
web app and the research harness:

1. **mono** averages the channels, which removes direction of arrival.
2. **hum** notches the 50 and 60 Hz harmonic families (zero-phase, Q = 30) and refills each notch
   with noise at its neighbours' long-term level. That removes the grid clock without leaving a
   notch pattern that says which grid the recording came from.
3. **subtract** follows each long tone, cancels a matched copy, re-tracks the residual, repeats.
4. **scurve** runs the attacker's trick blind: it scores every physically possible straight pass
   (speed, distance, timing) by integrating energy along its pitch curve, and cancels the curves
   that fit. It catches faint tones above the low band, like train wheels.
5. **lowband** rebuilds everything below 300 Hz, where distant engines live, as noise that matches
   each hearing band's loudness, smoothed and slowly re-gained. Tracked voice harmonics are kept.
   Nothing narrow survives for a matched filter to lock on to.

The web app also scans the picture: one decode pass measures each frame's row brightness, and a
blind search for a band at 100 or 120 Hz (the way an attacker would look) decides whether the
picture carries the grid clock. If it does, saving can divide the band out of every row on the GPU,
and the saved file is decoded and scanned again to confirm.

## Limits

- Every number so far is from synthetic clips. Real recordings with ground-truth tracks are being
  collected.
- Known gaps, in order: a source's loudness envelope; light flicker that barely moves (60 Hz
  lights at 30 fps); timetabled sounds such as bells and horns. Details in
  [THREAT_MODEL.md](THREAT_MODEL.md).
- Removing light flicker re-encodes the picture in standard dynamic range, so HDR footage looks a
  little different. Clips under 5 seconds are too short to check for flicker.
- Without de-flicker, the video stream is copied as is, including any data embedded in the stream
  itself (some cameras put timecode, user data or telemetry there; container metadata is removed).
  The codec settings and resolution also say what kind of device recorded it.
- A cloaked file is recognisable as one (mono AAC audio, regenerated low band). That says the file
  was processed, not where it was recorded.
- Clips are processed in memory; the web app takes up to 5 minutes.

## Development

```sh
swift build -c release && swift test -c release      # library + CLI (macOS, Linux)
scripts/build-wasm.sh                                # WebAssembly build (Swift 6.4.2 + its wasm SDK)
cd web && bun install && bun run dev                 # web app (a JS stand-in runs without the wasm)
cd harness && bun install && bun test                # attackers, defenses, benchmarks
```

CI runs on every push (actions pinned to commits, read-only permissions): Swift tests on macOS,
Linux and WebAssembly; the web app's unit tests against the real wasm build; a browser end-to-end
test of the production build (CSP on, metadata gone, picture hash-identical, flicker removed and
re-verified on the saved file); the harness tests; and the benchmark gate on both the harness and
the Swift pipeline. The site deploys from `main` only when all of them pass.

```
Sources/
  OctaveCamoKit/      pure-Swift DSP, no Foundation: builds for iOS, macOS, Linux, WebAssembly
    DSP/              FFT, RealFFT, Biquad, SeededRNG, low-band STFT, ERB scale
    Model/            FlybyGeometry: the flyby physics, shared by synth, fitter and scurve
    Analysis/         ToneTracker, FlybyAnalyzer (blind attacker), PitchTracker (YIN), FlickerScan
    Scrub/            ScrubPipeline: HumNotch, ToneSubtraction, SCurveCancel, LowBandRegeneration
    Synth/            FlybySynth: known-truth test clips
  OctaveCamoIO/       WAV read/write
  OctaveCamoWasm/     WebAssembly exports for the web app (WASI reactor)
  octave-camo/        CLI: synth, analyze, scrub
Tests/                Swift tests
web/                  web app: Vite, TypeScript, Tailwind; worker, Mediabunny remux, WebGL de-flicker
harness/              Bun/TypeScript: matched (ADS-B) attacker, defense modules, benchmark gate,
                      OpenSky / Flightradar24 ground truth (see harness/README.md)
reference/            NumPy prototypes and synthetic clip generators
```

### Library

```swift
import OctaveCamoKit

var pipeline = ScrubPipeline()                 // mono → hum → subtract → scurve → lowband
let result = pipeline.run(audio)               // Audio in, mono Audio out
result.log.forEach { print($0) }
print(FlybyAnalyzer().analyze(result.audio).consensus == nil ? "clean" : "flyby still recoverable")
```

Every stage is a plain struct with tunable properties (`pipeline.hum.mains`,
`pipeline.lowband.cutoff`, …); `pipeline.steps` switches stages on or off. The CLI
(`octave-camo synth | analyze | scrub`, `--help` for flags) and `scripts/scrub-video.sh` wrap the
same pipeline.

## Security, contributing, license

- Found a way to recover location from a cloaked file, or anything leaving the browser? See
  [SECURITY.md](SECURITY.md) for private reporting.
- [CONTRIBUTING.md](CONTRIBUTING.md): real recordings with ground truth help most.
- [IDEAS.md](IDEAS.md): the backlog.
- MIT, see [LICENSE](LICENSE).
