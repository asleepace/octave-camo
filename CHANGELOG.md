# Changelog

All notable changes to octave-camo. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). No versions are tagged yet, so changes
are grouped by milestone, newest first, with the commits that made them.

> **Proof of concept.** Nothing here is a guarantee of anonymity. See
> [THREAT_MODEL.md](THREAT_MODEL.md).

## [Unreleased]

Nothing yet.

## Hardening for review — 2026-11-03

Getting the project to a state the security community can check for themselves.

### Security / privacy

- Saved files get a random name (`camo-xxxxxx.mp4`); phone and screen-recording names carry the
  capture date and time. ([5486d5f])
- The muxer's name is scrubbed from the output (handler names neutralised, compressor name
  cleared, byte lengths unchanged). ([5486d5f])
- Seeds come from `crypto.getRandomValues` (52 bits), not `Math.random`. ([5486d5f])
- Crafted input files: channel count and sample rate are checked before decoding, decoding stops
  at the duration limit, and a mid-stream sample-rate change is refused. ([5486d5f])
- Strict Content-Security-Policy in the built page (`default-src 'none'`,
  `connect-src 'self' blob:`, no remote origins, no referrer). ([79a547a], [1a42494])
- The worker loads the wasm at startup, so the page works offline after the first load.
  ([fbe2c7c])
- CI: read-only workflow permissions by default, all actions pinned to commit SHAs, deploy only
  after every job passes. ([5486d5f])

### Fixed

- Replies from the worker carry the open file's token, and replies about a previous file are
  dropped (a slow flicker scan could otherwise apply one file's gains to the next). ([5486d5f])
- De-flicker refuses to save if the decoded frame count differs from the scanned one, instead of
  clamping. ([5486d5f])
- "Flicker gone" is now confirmed by decoding the saved file again, not the canvas fed to the
  encoder. ([5486d5f])
- wasm exports return pointers to buffers they own (no pointer escaping
  `withUnsafeBufferPointer`). ([5486d5f])
- HE-AAC input uses the decoded sample rate. ([5486d5f])

### Changed

- Clips under 5 s say "too short to check" for flicker; a failed picture scan shows a warning.
  The Light and Hum-only presets are labelled partial. ([5486d5f])
- Benchmark: detections below the attacker's noise floor that happen to land near the truth are
  labelled as such. ([4ce744d])

### Added (evidence and tests)

- A `swift` harness module runs the shipped Swift pipeline; the benchmark gate checks it
  alongside the harness chain, using a static Linux CLI built in CI. ([5486d5f])
- Matched-attacker null calibration: three source-free renders set the noise floor; a leak needs
  a detection above `max(7, floor + 3)` within 1 km of the truth. ([5486d5f])
- End-to-end cases: neutral file names, exact track list, no tool name in the bytes, audio-only
  input, clips too short to scan, and (in Google Chrome) an H.264/AAC MOV with rotation and an
  extra audio track. ([5486d5f])

### Docs

- README rewritten: what each side channel gives away, how to verify the claims yourself (network
  tab, packet hashes, `ffprobe`, reproducible benchmark gate), evidence table with the thin
  margins called out, limits. ([fbe2c7c])
- New [SECURITY.md](SECURITY.md) (what counts as a vulnerability, private reporting) and
  [CONTRIBUTING.md](CONTRIBUTING.md). ([fbe2c7c])
- Threat model: the cloak's own fingerprint, in-stream video data and the output's recognisability
  stated as limits; attacker noise floors listed. ([fbe2c7c], [5486d5f])

## Audio: no grid fingerprint from the cloak — 2026-11-03

A real clip showed 7 dB notches at 120/240/300 Hz after cloaking: a hint the recording came
from a 60 Hz grid.

### Changed

- **hum** notches both the 50 Hz and 60 Hz harmonic families (Q = 30) and refills each notch with
  independent noise, so neither the hum nor the notch pattern says which grid it was. `--mains`
  takes a list. ([de87a2c])
- **lowband** smooths its spectral shape over 1 ERB, so notch holes and steady motor tones aren't
  copied into the regenerated noise. ([de87a2c])

### Fixed

- The notch refill now sits at the neighbouring bands' long-term median level. A level that
  followed the neighbours over time re-imprinted a slow ship's tone as it drifted past each notch,
  and the matched attacker located it; the new benchmark gate caught it. ([1a42494])

### Added

- CI gates: a Playwright end-to-end test of the production build with the real wasm (flyby and
  hum found then gone, no location or creation tags, mono AAC, video packets hash-identical, no
  CSP violations or external requests, flicker removed and re-verified), and a benchmark gate that
  fails if the default chain leaks on any of the 6 clips, or if uncloaked clips stop leaking.
  ([79a547a], [1a42494])
- Tests: both grids notched once, wandering mains line removed without a hole, no 50/60 asymmetry
  after the cloak, no narrow line in regenerated noise. Web unit tests for the spectrum, worker
  protocol, output naming, band chart and CSP. ([de87a2c], [79a547a])

## Light flicker in the picture — 2026-11-03

LED and fluorescent lights flicker at twice the grid frequency, and rolling-shutter cameras record
it as faint bands: the same timestamp the audio hum carries.

### Added

- `reference/video_flicker.py`: blind flicker scan and removal prototype, with realistic grid
  wander in the synthetic clips. ([d5b6530], [4b3c94c])
- Swift `FlickerScan`: column-strip coherence, static removal, per-frequency whitening,
  least-squares band amplitude with fine refinement, smoothed and depth-capped removal; wasm
  exports `camo_flicker` / `camo_flicker_gains`. ([08e5012])
- Web app: one decode pass measures row profiles and the scan reports whether the picture carries
  the grid clock. If it does, an opt-in toggle divides the bands out of every frame on the GPU
  (WebGL), re-encodes (HEVC, H.264, VP9 or AV1, rotation kept), and scans the saved picture again.
  ([77b07ff])

## Web app — 2026-11-03

### Added

- Browser scrubber at [asleepace.github.io/octave-camo](https://asleepace.github.io/octave-camo/):
  the Swift pipeline compiled to WebAssembly, run in a worker; Mediabunny decodes and remuxes;
  the video stream is copied and a new mono AAC track written, with no container metadata.
  Spectral terrain visualiser, drag and drop, presets, detected levels. Deployed to GitHub Pages.
  ([d592d44])
- Simpler layout and the Octave Camo mark and icons. ([790e72d])
- Proof-of-concept disclaimer: no guarantee of anonymity, in active development. ([6042775])

### Fixed

- `camo_analyze` trapped with "Index out of range": a WASI reactor never runs `main.swift`'s
  top-level code, so its globals stayed empty. Shared state now lives in statics; a debug wasm
  build (with readable traps) is built in CI. ([b1fd7c6], [3504761], [0eb2990], [b6f39e8],
  [bffd229], [1d62e18])

## Swift core and WebAssembly — 2026-11-03

### Added

- MIT license. ([981fbbd])
- CI: Swift on macOS and Linux, harness tests. ([b25c3a6], [332fb2c])
- `lowband` and `scurve` ported to Swift; default chain becomes
  `mono → hum → subtract → scurve → lowband`, the same in the library, CLI and harness.
  ([e02308c], [b85615f])
- [THREAT_MODEL.md](THREAT_MODEL.md), WebAssembly entry points (`camo_scrub`, `camo_analyze`)
  and a wasm build in CI. ([d967f3a], [7d43042])

### Changed

- `OctaveCamoKit` no longer depends on Foundation, so it builds for iOS, macOS, Linux and
  WebAssembly; WAV I/O moved to `OctaveCamoIO`. ([e02308c])

### Fixed

- Swift type-check timeouts in `FlybySynth` and `LowBandRegeneration`. ([157c67c], [aef1440])

## Initial release — 2026-11-03

### Added

- Swift package: `OctaveCamoKit` (tone tracker, blind flyby fitter, scrub pipeline with hum notch,
  tone subtraction and band wobble, synthetic flyby clips) and the `octave-camo` CLI
  (`synth`, `analyze`, `scrub`), with tests.
- Bun/TypeScript research harness: OpenSky and Flightradar24 ground truth, blind and ADS-B matched
  attackers, modular defenses (`hum`, `subtract`, `lowband`, `scurve`, `decoy`, `informed`,
  `legacy`), benchmarks.
- NumPy reference prototype and ffmpeg scripts. ([a68ec12])

[981fbbd]: https://github.com/asleepace/octave-camo/commit/981fbbd
[a68ec12]: https://github.com/asleepace/octave-camo/commit/a68ec12
[b25c3a6]: https://github.com/asleepace/octave-camo/commit/b25c3a6
[157c67c]: https://github.com/asleepace/octave-camo/commit/157c67c
[332fb2c]: https://github.com/asleepace/octave-camo/commit/332fb2c
[e02308c]: https://github.com/asleepace/octave-camo/commit/e02308c
[aef1440]: https://github.com/asleepace/octave-camo/commit/aef1440
[b85615f]: https://github.com/asleepace/octave-camo/commit/b85615f
[d967f3a]: https://github.com/asleepace/octave-camo/commit/d967f3a
[7d43042]: https://github.com/asleepace/octave-camo/commit/7d43042
[d592d44]: https://github.com/asleepace/octave-camo/commit/d592d44
[b1fd7c6]: https://github.com/asleepace/octave-camo/commit/b1fd7c6
[3504761]: https://github.com/asleepace/octave-camo/commit/3504761
[0eb2990]: https://github.com/asleepace/octave-camo/commit/0eb2990
[b6f39e8]: https://github.com/asleepace/octave-camo/commit/b6f39e8
[bffd229]: https://github.com/asleepace/octave-camo/commit/bffd229
[1d62e18]: https://github.com/asleepace/octave-camo/commit/1d62e18
[790e72d]: https://github.com/asleepace/octave-camo/commit/790e72d
[6042775]: https://github.com/asleepace/octave-camo/commit/6042775
[d5b6530]: https://github.com/asleepace/octave-camo/commit/d5b6530
[4b3c94c]: https://github.com/asleepace/octave-camo/commit/4b3c94c
[08e5012]: https://github.com/asleepace/octave-camo/commit/08e5012
[77b07ff]: https://github.com/asleepace/octave-camo/commit/77b07ff
[de87a2c]: https://github.com/asleepace/octave-camo/commit/de87a2c
[79a547a]: https://github.com/asleepace/octave-camo/commit/79a547a
[1a42494]: https://github.com/asleepace/octave-camo/commit/1a42494
[fbe2c7c]: https://github.com/asleepace/octave-camo/commit/fbe2c7c
[5486d5f]: https://github.com/asleepace/octave-camo/commit/5486d5f
[4ce744d]: https://github.com/asleepace/octave-camo/commit/4ce744d
