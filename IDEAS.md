# Ideas backlog

Things that came up while building and testing. Each is roughly ordered by value for effort.

## The threat is bigger than aircraft

- **Anything with public telemetry and a known path leaks the same way.**
  - Trains: BART, Caltrain and Muni publish live vehicle positions via GTFS-realtime.
  - Buses, and ships: AIS covers foghorns and engine tones on the Bay.
  - Delivery drones.

  The matched attacker only needs *a sound source with a known track*. Rail is arguably worse
  than air, because the tracks are fixed and close to people. The `lowband` defense covers these
  too, since it doesn't care what made the tone. But the harness should get a GTFS-RT source and a
  "train" synthetic clip to prove it.
- **Scheduled sounds act as clocks and beacons.** Church bells, the Golden Gate foghorns, school
  bells and train horns at crossings are all timetabled events. Hearing one pins down the time,
  and its loudness and echo give rough distance.
- **Video carries the mains frequency (ENF) too.** LED and fluorescent lights flicker at twice
  the grid frequency, and rolling-shutter cameras record that flicker as faint bands. That's a
  timestamp in the *picture*, even after `hum` removes it from the audio. A video-side
  de-flicker would close it.
- **The loudness envelope is an attack surface we haven't tested.** A distant plane's rumble swells
  and fades over tens of seconds. The peak time and width give its closest-approach time and d/v.
  `lowband` smooths over 0.75 s and adds ±1.5 dB of slow random gain. That's probably not enough
  against an attacker that matches the whole envelope. The next step is an envelope term in the
  matched attacker, then a defense test.

## Defense improvements

- **Port `lowband` and `subtract` to Swift** using vDSP. These are the default chain, and the TS
  `subtract` still shells out to the NumPy reference.
- **Adaptive chains using Apple's Sound Analysis classifier.**
  - Music detected: fall back to `subtract`, since `lowband` would turn bass notes into noise.
  - Quiet outdoor ambience (the highest-risk case): use the full chain.
  - Speech-heavy clips: `keepVoice` matters most.
- **Make `scurve` sharper for fast sweeps.** Use a 0.5 s analysis window for short τ (close passes)
  and keep 2 s for long τ. A multi-resolution family would let it replace `subtract` in Swift.
- **Refill cancelled bands with matching noise** after `scurve` and `informed`, so cancellation
  never leaves a spectral trough (the artifact we saw with a short low-pass).
- **Choose the cutoff per clip.** Measure where long-lived narrow tones actually stop (often well
  below 300 Hz) and regenerate only up to there, which keeps more voice warmth.
- **Spoof decoys with informed cancellation** worked in synthetic tests: the attacker reported a
  convincing wrong place. It needs flight data, so it suits an "online" mode with a large search
  box, which leaks little about where you are.

## Product

- **Pre-post risk meter.** Run the blind detectors (tracker plus `scurve` scores) and show
  "this clip contains aircraft-like tones" before scrubbing. This is cheap and explains *why*
  the app is useful.
- **Posting-delay nudge.** Every hour between recording and posting multiplies the flights the
  attacker must try. "Post in 2 hours" is a free, real privacy gain.
- **Shortcuts / App Intent and Share sheet integration**, as discussed early on.
- **Honest UI copy:** "reduces location leakage from sound", never "guarantees".

## Testing and evaluation

- **Real ground-truth recordings.** A small dataset of 60–90 s clips plus saved ADS-B tracks
  (`--save-track`), covering close passes, distant jets, propellers, helicopters and trains. Every
  number so far is from synthetic data.
- **Golden regression tests for the benchmark.** Pin seeds, store the table, and fail CI if a
  change makes any "safe" cell leak.
- **An unknown-time attacker.** Search over the recording-time offset, to measure how much
  stripping metadata alone helps (the attacker only has the post time).
- **Perceptual quality.** ERB loudness change is a proxy. A short listening test, or ViSQOL, on
  real clips would tell us whether `lowband` is truly unnoticeable on phone speakers versus
  headphones.
- **Swift test target.** The package has XCTest files but has never been compiled here. Run
  `swift test -c release` on a Mac and wire it into CI.
