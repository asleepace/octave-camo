<img src="web/public/icon.svg" width="72" alt="" />

# octave-camo

[![CI](https://github.com/asleepace/octave-camo/actions/workflows/ci.yml/badge.svg)](https://github.com/asleepace/octave-camo/actions/workflows/ci.yml)
[![wasm](https://img.shields.io/endpoint?url=https%3A%2F%2Fasleepace.github.io%2Foctave-camo%2Fbadges%2Fwasm.json)](https://asleepace.github.io/octave-camo/octave-camo.wasm)
[![wasm gzipped](https://img.shields.io/endpoint?url=https%3A%2F%2Fasleepace.github.io%2Foctave-camo%2Fbadges%2Fwasm-gzip.json)](https://asleepace.github.io/octave-camo/checksums.txt)

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
| Doppler curves of planes, trains, ships | Your position, matched against public tracks (ADS-B, transit feeds, AIS) | Cancels long tones below 1 kHz, searches blind for flyby-shaped curves and cancels them, regenerates the low band as information-free noise. **Experimental** also fills in every tone the check still finds up to 8 kHz (a jet's fan tone near 1–2 kHz, an electrical whine) |
| Mains hum | Recording time and grid region (ENF) | Notches both 50 and 60 Hz harmonic families, right to the clip's edges, and refills the notches, so neither the hum nor the notch pattern survives |
| Light flicker in the picture | The same grid timestamp, as rolling-shutter bands | Scans every frame; if found, divides the bands out (optional: re-encodes the picture) |
| Loudness rising and falling as a plane passes (below 300 Hz) | The recording's time, by lining it up with flight tracks; it can work even indoors, from a rumble no one in the room hears | Regenerated low band follows loudness smoothed over 0.75 s, so slow swells survive in **Full**. The **Experimental** preset flattens every swell slower than 5 s (thumps and doors stay) |
| Multiple mics, spatial-audio tracks | Direction of sounds | Mono output; extra audio tracks dropped |
| Metadata | GPS, device, timestamps, directly | No container metadata is copied: no tags, no creation time, timestamps rebased to zero, a random file name. Data embedded in H.264/HEVC packets (SEI: encoder settings, camcorder date and GPS) is removed too |

It doesn't touch what the picture shows, what people say, or anything about the account that posts
it.

## Use it

**[asleepace.github.io/octave-camo](https://asleepace.github.io/octave-camo/)**: drop a video, press
CLOAK, save. Everything runs on your device; the Swift scrubber is compiled to WebAssembly and
nothing is uploaded. The saved MP4 has the original video packets (bit for bit, minus any SEI
data embedded in H.264/HEVC, unless you remove light flicker) and a new mono AAC audio track, with
no metadata.

## Verify it yourself

You shouldn't have to take a privacy tool's word for it.

- **Nothing leaves your device.** The page has no code that sends anything anywhere, and its
  Content-Security-Policy (`default-src 'none'; connect-src 'self' blob:`; see
  [web/vite.config.ts](web/vite.config.ts)) blocks requests, scripts, styles and fonts from any
  other origin. A CSP can't stop everything (it doesn't cover navigating the page away or WebRTC),
  so check for yourself: watch the Network tab in your browser's developer tools while you cloak a
  file, or load the page, go offline, and use it.
- **The picture is untouched.** Both files decode to exactly the same frames (the cloak copies
  the video packets, removing only SEI, which decoders don't need):

  ```sh
  ffmpeg -v error -noautorotate -i original.mov -map 0:v:0 -f hash -hash sha256 -
  ffmpeg -v error -noautorotate -i camo-xxxxxx.mp4 -map 0:v:0 -f hash -hash sha256 -
  ```

  For VP9 and AV1 even the packets are identical (`-c copy -f streamhash` instead of `-f hash`).

- **The metadata is gone.** `ffprobe -show_format -show_streams camo-xxxxxx.mp4` (or `exiftool`)
  shows no location, device or creation time.
- **The page is the code in this repository.** The footer shows the version, the commit, and the
  SHA-256 of the WebAssembly the page actually loaded (computed in your browser from the bytes it
  runs). Compare it with the `octave-camo.wasm` checksum in the
  [release](https://github.com/asleepace/octave-camo/releases), or rebuild it yourself: the build
  is reproducible (from 0.1.1; CI rebuilds it in another directory on every push and fails if a
  byte differs), so the commit in the footer gives the same hash on any machine:

  ```sh
  git clone https://github.com/asleepace/octave-camo && cd octave-camo && git checkout <commit>
  docker run --rm -v "$PWD":/src -w /src swift:6.4.2 bash -c "swift sdk install \
    https://download.swift.org/swift-6.4.2-release/wasm-sdk/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE_wasm.artifactbundle.tar.gz \
    --checksum 83baca83553f8c443cda7b84800912e6e709c3acd2e7ebf277794ca5836c0da5 && scripts/build-wasm.sh /src/rebuilt.wasm"
  sha256sum rebuilt.wasm
  ```

  The site's `checksums.txt` lists every file it serves (the web build is reproducible too), and
  after each deploy CI re-downloads the live site and checks every file against its own build:

  ```sh
  site=https://asleepace.github.io/octave-camo
  curl -s $site/checksums.txt | while read -r hash file; do
    [ "$(curl -s "$site/$file" | sha256sum | cut -d' ' -f1)" = "$hash" ] || echo "MISMATCH $file"
  done
  ```

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
2. **hum** notches the 50 and 60 Hz harmonic families below 400 Hz (zero-phase, Q = 30) and
   refills each notch with noise at its neighbours' long-term level. Near the clip's edges, where a filter pass would start cold and
   let the hum through, both passes run in from the inside. That removes the grid clock without
   leaving a notch pattern that says which grid the recording came from.
3. **subtract** follows each long tone, cancels a matched copy, re-tracks the residual, repeats.
4. **scurve** runs the attacker's trick blind: it scores every physically possible straight pass
   (speed, distance, timing) by integrating energy along its pitch curve, and cancels the curves
   that fit. It catches faint tones above the low band, like train wheels.
5. **lowband** rebuilds everything below 300 Hz, where distant engines live, as noise that matches
   each hearing band's loudness, smoothed and slowly re-gained. Tracked voice harmonics are kept.
   Nothing narrow survives for a matched filter to lock on to.

**The check** behind the page's "what a tracker finds" counts and the spectrogram's outlines is a
blind attacker: a frame-by-frame tone tracker (40 Hz–8 kHz, which also fits flyby curves), a line
integrator that averages over seconds, as a patient attacker would, so faint steady lines count
too, and a short-window path search that follows fast falling sweeps (a jet's fan tone, 0.5–4 kHz)
and keeps those that fit a flyby. It looks further than the cloak reaches, so whatever the cloak
leaves is shown, not hidden. [ACOUSTICS.md](docs/ACOUSTICS.md) explains how it works and measures it; [EXPERIMENTS.md](docs/EXPERIMENTS.md) is the lab notebook for improving it. [RESEARCH.md](docs/RESEARCH.md) surveys related work, and [SOURCES.md](docs/SOURCES.md) lists every source.

The web app also scans the picture: one decode pass measures each frame's row brightness, and a
blind search for a band at 100 or 120 Hz (the way an attacker would look) decides whether the
picture carries the grid clock. If it does, saving can divide the band out of every row on the GPU,
and the saved file is decoded and scanned again to confirm. The sound is checked again the same
way: after saving, the page decodes the file it wrote and runs the check on it, so the count it
shows ("saved N") is for the file you post, not only for what went into the encoder.

## Limits

- The evidence table is synthetic. Real phone recordings with ADS-B ground truth are scored in the
  lab (kept private; results in [docs/EXPERIMENTS.md](docs/EXPERIMENTS.md)): so far, Experimental
  removes a real jet pass that Full leaves, but a fainter one survived both presets for an
  attacker who has the flight tracks. Removal driven by those tracks closes it in the engine and
  the lab (attacker z 6.3 → 0.8); it isn't on the page yet.
- Faint tones, and any above 1 kHz, are counted and outlined but only **Experimental** removes
  them: on a real outdoor clip, passing cars' faint tones and a steady 5 kHz whine survived Full.
- Other known gaps: a source's loudness envelope under Full; weak curved (Doppler) lines (the
  check now follows a jet's fan tone above 1 kHz, but only Experimental removes it); light flicker that
  barely moves (60 Hz lights at 30 fps); timetabled sounds such as bells and horns. Details in
  [THREAT_MODEL.md](THREAT_MODEL.md).
- Removing light flicker re-encodes the picture in standard dynamic range, so HDR footage looks a
  little different. Clips under 5 seconds are too short to check for flicker.
- Without de-flicker, the video packets are copied. SEI (where H.264/HEVC cameras and encoders
  put user data, timecode and telemetry) is removed; AV1 metadata units are copied as is (VP9 has
  none). The codec settings and resolution still say what kind of device recorded it.
- Audio is cloaked as mono at up to 48 kHz. A video with no sound is saved with its picture only
  (metadata removed, and embedded data for H.264/HEVC; flicker checked).
- Slow-motion pictures (about 200 fps and up) and clips under 5 seconds can't be checked for
  flicker; the page says "not checkable" or "too short" rather than "none".
- A cloaked file is recognisable as one (mono AAC audio, regenerated low band). That says the file
  was processed, not where it was recorded.
- The web app takes clips up to 10 minutes. Past 5 minutes the audio is cloaked and checked in
  overlapping parts of at most 4 minutes (10 s of overlap, crossfaded at the seams; a tone that
  crosses a seam is counted once), which keeps the scrubber's memory and time in step with a
  5-minute clip's. The decoded audio, the cloaked copy and the saved file are still held in memory
  whole. A 5-minute clip takes about a minute to cloak on a laptop (Light: about 12 s), likely a
  few minutes on a phone; most of it is `subtract`'s tone tracking, then `scurve`, whose cost grows
  with the square of a part's length.

## Development

```sh
swift build -c release && swift test -c release      # library + CLI (macOS, Linux)
scripts/build-wasm.sh                                # WebAssembly build (Swift 6.4.2 + its wasm SDK)
cd web && bun install && bun run dev                 # web app (a JS stand-in runs without the wasm)
cd harness && bun install && bun test                # attackers, defenses, benchmarks
python3 -m unittest discover -s lab/tests -t .       # lab invariants (numpy, scipy, soundfile)
python3 scripts/check-links.py                       # every relative Markdown link resolves
```

CI runs on every push (actions pinned to commits, read-only permissions): Swift tests on macOS,
Linux and WebAssembly; the web app's unit tests against the real wasm build; a browser end-to-end
test of the production build (CSP on, metadata gone, picture hash-identical, flicker removed and
re-verified on the saved file); the harness tests; and the benchmark gate on both the harness and
the Swift pipeline; the lab's invariants and a link check of the docs. The site deploys from
`main` only when all of them pass.

```
Sources/
  OctaveCamoKit/      pure-Swift DSP, no Foundation: builds for iOS, macOS, Linux, WebAssembly
    DSP/              FFT, RealFFT, Biquad, SeededRNG, low-band and band-limited STFTs, ERB scale
    Model/            FlybyGeometry: the flyby physics, shared by synth, fitter and scurve
    Analysis/         the check: FlybyAnalyzer over ToneTracker, LineIntegrator and PathSearch;
                      PitchTracker (YIN), FlickerScan
    Scrub/            ScrubPipeline: HumNotch, ToneSubtraction, SCurveCancel, LowBandRegeneration,
                      BandWobble, LineFill (Experimental), TrackFill (flight tracks, engine and lab)
    Synth/            FlybySynth: known-truth test clips
  OctaveCamoIO/       WAV read/write
  OctaveCamoWasm/     WebAssembly exports for the web app (WASI reactor)
  octave-camo/        CLI: synth, analyze, scrub
Tests/                Swift tests: behaviour snapshots, invariants, the detection baseline
web/                  web app: Vite, TypeScript, Tailwind; worker, Mediabunny remux, WebGL de-flicker
harness/              Bun/TypeScript: matched (ADS-B) attacker, defense modules, benchmark gate,
                      OpenSky / Flightradar24 ground truth (see harness/README.md)
lab/                  Python: recorder sessions with ADS-B ground truth, the known-path and
                      place-searching attackers, experiments (see lab/README.md)
docs/                 how the check works, the lab notebook, plan, ideas, research, sources
reference/            NumPy prototypes and synthetic clip generators
scripts/              wasm build, video scrub, link check
tools/wasm-opt/       pinned binaryen for release builds
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
- [docs/](docs/README.md): how the check finds tones ([ACOUSTICS](docs/ACOUSTICS.md)), the lab
  notebook ([EXPERIMENTS](docs/EXPERIMENTS.md)), the [plan](docs/PLAN.md), [ideas](docs/IDEAS.md),
  [research](docs/RESEARCH.md) and [sources](docs/SOURCES.md). [CHANGELOG.md](CHANGELOG.md): what
  changed.
- MIT, see [LICENSE](LICENSE).
