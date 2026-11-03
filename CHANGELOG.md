# Changelog

All notable changes to octave-camo. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). No versions are tagged yet, so changes
are grouped by milestone, newest first, with the commits that made them.

> **Proof of concept.** Nothing here is a guarantee of anonymity. See
> [THREAT_MODEL.md](THREAT_MODEL.md).

## [Unreleased]

### The check looks up to 8 kHz

- The attacker model behind "what a tracker finds" now searches 1–8 kHz as well as 40 Hz–1 kHz
  (a separate peak budget, so nothing it found below 1 kHz changes). A steady tone up there, such
  as a jet's fan whine or an electrical whine, is counted instead of hidden behind a "→ 0".
- The cloak doesn't remove those yet (tone subtraction still stops at 1 kHz), so the page says so:
  the spectrogram outlines every long tone found, dashed on the original and solid for what a
  tracker can still follow after cloaking, with a count under it.
- A steady tone above 1 kHz is no longer called mains hum just because it sits within 1 Hz of a
  50/60 Hz multiple (up there, nearly every tone does).
- The wasm reports each tone's start, end and frequency range (`camo_tracks`); the CLI's JSON
  gains `start` per track.
- The new range has its own, stricter settings (a 15 dB threshold, matching within 5% per second
  of drift): with the low band's, background noise at 16 kHz chained into false 2–5 s "tones".
- What the snapshot shows now: the 1.2 and 4.5 kHz tones are counted (1 → 1, not yet removed);
  held notes' harmonics above 1 kHz are counted and stay (59 → 31); and the hum scene shows two
  leftovers near 1 kHz (19 → 2) that the old check couldn't see.

### Tests

- **Behavior snapshots** (`Tests/OctaveCamoKitTests/Snapshots/behavior.json`): 13 synthetic scenes,
  from planes and hum to sounds that carry no clue (speech, singing, whistling, birdsong, held
  notes, footsteps, silence) and tones above 1 kHz. Each records the attacker's counts before and
  after, how much sound above the low band is kept, and the level change per octave; a change
  beyond the tolerances fails, and re-recording shows the diff. Identical on Linux and macOS.
- **Clue invariants**: the check behind the page's counts covers every frequency the cloak
  changes; cloaking never adds a Doppler track, hum line or flyby; a second cloak finds nothing
  new; level and sample rate don't change what's found; ordinary sound keeps its level above the
  low band.
- **Web**: 5,000 hostile worker messages are rejected without throwing; heatmap levels are relative
  and put a tone in the same row at any sample rate.

### Known issues (found by the new tests, targets written and skipped)

- **Tones above 1 kHz are counted but not removed yet** (tone subtraction covers 40 Hz–1 kHz).
- **Cloaked speech can show a "long tone" at the voice's own pitch** (with about half the seeds):
  not a location clue, but the page would show "long tones 0 → 1".
- **Held musical notes are removed** like engine tones (the snapshot keeps 8% of a chord scene's
  shape and takes 10–13 dB off 250–500 Hz).

### Spectrogram

- A full-width 2D spectrogram (frequency over time) under the detected levels, with a
  before / after control that follows "listen to" in the player. Before and after share one
  color range, so the toggle shows what cloaking changed: the planes' curves and the hum lines
  go, speech stays. A dotted line marks where the low end is regenerated; a playhead follows
  playback, and clicking the image seeks there.
- Finer than the 3D view (256 log-spaced rows from 30 Hz to 8 kHz, ~100 ms windows), so a
  Doppler bend reads as a curve rather than steps. Computed in the worker; long clips are
  pooled to at most 2,400 columns, keeping the loudest value so short tones aren't lost.
- Before a file is opened it shows an illustration (a passing plane, mains hum and speech),
  labelled as an example. The stage log moved below it.

## [0.1.1] — 2026-11-03

### Accessibility

- Text meets WCAG AA contrast (4.5:1) everywhere: the two dimmest greys were 4.4:1 and 2.7:1 on
  black (now 6.1:1 and 5.1:1), and the smallest text is a step larger.
- A visible focus ring on every control, including the hidden file input (shown on the drop zone).
- CLOAK keeps keyboard focus while it works (it was disabled, which dropped focus to the page),
  so SAVE is one key press away.
- Landmarks (header, main, footer), a caption for the levels table, a text description for the
  3D spectrogram, decorative symbols hidden from screen readers; the status line is only rewritten
  when it changes, so screen readers don't re-announce it; the demo animation holds still with
  "reduce motion".
- Inactive player controls and steps that are off use readable greys instead of being faded.
- Tests: axe-core (WCAG 2.2 A/AA) on the page empty, loaded and cloaked; a contrast check that
  reads the real colors (axe can't parse Tailwind's oklch); keyboard-only open, cloak and save.

### Search and link previews

- A descriptive title and description, a one-line intro under the name, canonical URL, Open
  Graph and X/Twitter tags with a 1200×630 preview image (`web/scripts/og-image.ts` renders it),
  and schema.org `WebApplication` data.

### Reproducible builds

- **The WebAssembly build is reproducible.** Rebuilding a commit gives the same bytes on any
  machine and in any directory, so the engine hash in the page's footer can be checked against
  your own build, not only against ours. The only bytes that varied were the compiler's
  `.swift_modhash` section (per-object hashes of the IR including debug info, kept for
  incremental builds, unused at runtime); release builds now have no debug info and no modhash.
  CI rebuilds the wasm in another directory on every push and fails if a byte differs.
- **A release ships the exact wasm that was deployed** for its commit, not a rebuild (0.1.0's
  first release listed a rebuilt file whose hash didn't match the site's footer; it was
  corrected the same day). Rebuilds are made to check reproducibility, and a release fails if they
  don't match. Releases can be re-run by hand for an existing tag.

## [0.1.0] — 2026-11-03

The first tagged release. octave-camo removes the location and time clues in a video's sound and
picture: the Doppler curves of planes, trains and ships, mains hum and light flicker (the grid's
clock), direction from multiple mics, metadata and data embedded in the video stream. It runs
entirely in the browser ([asleepace.github.io/octave-camo](https://asleepace.github.io/octave-camo/)),
from a Foundation-free Swift library compiled to WebAssembly.

**Proof of concept: no guarantee of anonymity.** Every result so far is on synthetic clips; see
[THREAT_MODEL.md](THREAT_MODEL.md) for what is covered, the evidence, and the known gaps.
Review is very welcome: [SECURITY.md](SECURITY.md) says how to report privately.

### New in this release

- **Silent videos** are accepted: no audio stage, the picture is still checked for light flicker,
  and the saved MP4 has only the picture, with metadata (and, for H.264/HEVC, embedded data)
  removed.
- **Verifiable builds.** The page footer shows the version, the commit, and the SHA-256 of the
  wasm it actually loaded (computed in the browser). The site publishes `checksums.txt` for every
  file; after each deploy CI re-downloads the live site and checks every file against its own
  build; the web build is reproducible, and each release records whether the wasm build was.
- A release workflow (tag → checked versions → builds → GitHub release with checksums), a Perf
  workflow (browser timings up to the 5-minute limit, with a phone-like CPU slowdown), and
  `octave-camo --version`.

### Fixed

- **The benchmark gate was nondeterministic.** The harness passed `subtract`'s stage list to the
  Swift CLI in an environment variable only the NumPy reference reads, and no seed, so in CI the
  harness chain ran the whole Swift pipeline, unseeded, in the middle: its results varied between
  runs (the "flaky" ship). The Swift pipeline's own results, which the README reports, were
  always seeded and unaffected.

### Fixed before release (a final review)

- If the worker failed to load or crashed, the page waited on it forever ("LOADING…",
  "LISTENING…"); it now says the scrubber failed and stops offering actions. The footer's engine
  hash is reported only once the engine is instantiated, and a load failure shows as such.
- "Embedded data removed" was claimed for every codec; it's said only for H.264/HEVC (AV1
  metadata units are still copied).
- The fallback AAC encoder (Firefox) was fetched mid-save, so "works offline once loaded" wasn't
  true there; it's loaded at startup.
- A failed check of the saved file made the page claim the picture was never scanned.
- After a preset change or a failed cloak, "out" still played and drew the previous result; for a
  silent video the "out" button was enabled. The demo spectrum stood in for a file whose analysis
  hadn't arrived. The picture-scan progress on the button stayed at 0 %. A bar in the levels
  table could overflow when a count went up.
- Space toggled playback even with a button focused; it now leaves controls alone.
- With a file loaded there was no visible way to open another (only drag and drop): an "open
  another file" link.
- `checksums.txt` was written relative to the working directory, not Vite's root. A packet with
  no parseable NAL units is refused rather than copied unchecked.
- CI: a newer push to `main` no longer cancels a deploy in progress; releases run the typecheck
  and tests (with the real wasm) before publishing.
- The CLI help described an old default chain; `scripts/scrub-video.sh` named its output after
  the input (keeping the capture date), let ffmpeg write its version, and copied SEI.
- Light-flicker removal: new, plainer wording; if it's unticked the page says the flicker is kept.

Everything before this release is listed below by milestone.

## Second review: invariants and media edge cases — 2026-11-03

A second independent review (Swift core and web app), plus new invariant tests and a media
edge-case suite. Several of the fixes below were found by the new tests themselves, and the
benchmark gate caught one change that made things worse (see "Known").

### Security / privacy

- **Mains hum survived at the clip's edges.** Zero-phase notches start cold, so the first and
  last fraction of a second kept the local grid's hum (which says which grid). Near each edge both
  filter passes now run in from inside the clip, already settled. Found by the invariant tests.
- **A passing engine could be kept as "voice"** by `lowband` (and so survive the Light preset):
  the voice tracker only rejected unbroken runs of steady pitch, but a Doppler glide moves, and in
  noise a machine's voicing flickers, which chopped even a steady tone into speech-length pieces
  (a 137 Hz tone at 8 kHz was kept in 82 % of frames). Now unbroken runs over 2 s are rejected,
  and stretches joined across short gaps are rejected when their pitch is steady (interquartile
  range under 80 cents) or moves one way throughout (Kendall's τ ≥ 0.7): rank and quartile tests,
  so the estimator's jitter in noise can't hide a machine. Speech rises and falls (the shipped
  pipeline keeps 67 % of the speech clip's voice detail below 300 Hz). Same rules in the harness. The voice keep-width is in Hz, not FFT bins (it
  grew with the sample rate, keeping up to 88 % of the band at 192 kHz).
- **Saving any H.264/HEVC video failed** partway through this round's changes (a reference to
  `SharedArrayBuffer`, which doesn't exist on pages that aren't cross-origin isolated); the
  Chrome end-to-end cases caught it before release.
- **Data embedded in H.264/HEVC packets (SEI) is removed** when the picture is copied: x264's
  version and settings, camcorder date and GPS, drone telemetry. Also removed from HEVC
  configurations. The UI's "metadata dropped" is now true for the picture too.
- **Timestamps start at zero**: a source's absolute start (an MPEG-TS an hour in, a recorder's
  clock) was carried into the output as an edit list.
- **The worker is under the page's Content-Security-Policy**: started from a blob: URL (which
  inherits the page's policy) instead of its own URL (which on GitHub Pages had none).
- One NaN, Inf or absurd sample (a corrupt float file) no longer silences or blanks the output:
  replaced and logged. One NaN in the picture profiles no longer turns the flicker scan off.

### Fixed

- 192 kHz audio hung the save (AAC can't carry it): audio is decoded straight to mono and
  resampled to 48 kHz at most, which also cuts memory by up to 16×.
- Opening a second file while the first was decoding mixed the two (stale analysis, stuck
  "LISTENING…", one file's flicker gains applied to the other).
- A failed re-cloak left the previous preset's output savable under the new preset's name.
- The `c` shortcut could save before the picture scan finished (skipping flicker removal).
- A late check of an earlier save could report "flicker gone" for a later one.
- The "too short to check" test used the audio's length, not the picture's.
- Streams cut mid-GOP failed at save; copying now starts at the first keyframe.
- MPEG-TS files starting hours in (camcorder .MTS) were refused as too long: the length is now the
  end timestamp minus the first, and the flicker scan uses frame times relative to the first frame.
- The primary audio track is chosen among those the browser can decode.
- Worker errors and unreadable messages no longer leave the UI stuck; any error no longer forces
  the wasm to download again (the compiled module is kept, so the page stays usable offline).
- Encoders and GPU contexts are released when a save fails; `neutralize` only searches outside the
  media data.
- Swift: notch filters guarded against Nyquist; nonsense `mains`, lowband cutoffs and scurve f0
  ranges no longer trap; empty WAV data is an error.
- wasm exports check sizes for overflow, report rejected input (instead of a stale result or
  zeros that read as clean), and export the flicker gains' length.

### Added

- **The flicker scan says when it couldn't look** (too few frames, or a frame rate around 200 fps
  and up): shown as "not checkable", never as "none".
- **Swift invariant tests** (`InvariantTests`): every sample rate from 8 to 192 kHz and 1, 2 or 6
  channels gives mono, finite, same-length, peak-limited output; degenerate lengths and
  pathological signals; same seed same output, different seed different noise, in every seeded
  stage; channel order doesn't matter; hum removed at every rate; lowband removes a steady tone at
  every rate; the voice band changes by under 2 dB; no time shift; a passing engine isn't kept as
  voice; the default chain removes a flyby at 22.05 and 96 kHz; every combination of steps is
  sound; bad settings don't trap; flicker gains finite and depth-capped; a timing tripwire.
- **Media edge-case suite** (`web/e2e/media.test.ts`): MKV/VP9/FLAC 96 kHz 6-channel, WebM
  VP8/Vorbis 22.05 kHz with an odd 177×99 picture, MP4/AV1/Opus, variable frame rate, Ogg/Opus,
  MP3 8 kHz, FLAC 192 kHz, a 0.3 s clip, two video tracks, a silent track, audio starting late
  (sync kept); refused cleanly without echoing the file name: no audio track, random bytes, an
  empty file, over the length limit; a truncated file; a second file opened mid-load; a double
  press of CLOAK. In Google Chrome: GPS injected as SEI is gone, an MPEG-TS starting an hour in
  comes out at zero, a stream cut mid-GOP saves. Every case checks that workers run from blob:
  URLs.
- Web unit tests for SEI stripping (length-prefixed and Annex B, H.264 and HEVC, HEVC configs),
  box-aware neutralizing and the stricter worker protocol; wasm tests for rejected input, NaN
  samples, sample rates and "not checked" flicker.

### Changed

- Display spectrograms are computed in the worker (a long clip no longer freezes the page,
  twice); the picture scan reads back only its small probe image; scan profiles are transferred,
  not copied; `scurve`'s hot loop works out its valid range once per frame instead of testing
  every element.
- The stand-in engine (dev only) no longer pretends to find flicker unless
  `VITE_STANDIN_FLICKER=1`.

### Known, not yet fixed

- Mains harmonics above 400 Hz are removed only when `subtract` can follow them. Notching up to
  1 kHz was tried in this round and dropped: the benchmark gate caught the close train leaking
  (the notches carved its tones and broke `subtract`'s tracking). See the threat model.
- ~~Videos with no audio track are refused~~ (fixed in 0.1.0).
- A cloaked MP3 keeps the encoder's start and end padding (the browser's decoder doesn't trim it):
  a fraction of a second longer, audio-only files only.
- AV1 metadata units are copied with the picture.
- Speed: a 5-minute clip takes about a minute in the browser on a CI machine (Light: 12 s).
  `subtract` dominates (its tracker runs full-rate FFTs), then `scurve` (quadratic in length).

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
