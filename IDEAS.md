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
- **Video ENF, quasi-static case.** De-flicker handles rolling bands, but at 30 fps under 60 Hz
  lights the bands barely move and only their slow wander carries the clock. A matched attacker
  with the ENF reference could still get processing gain there. Ideas: a phase-coherent model
  across strips and time, or masking the wander with a synthetic band of random slow drift.
- **De-flicker without leaving HDR.** The browser can only re-render to 8-bit SDR. An iOS app
  could apply the same per-row gains in the 10-bit HLG domain with AVFoundation and keep HDR.
- **The loudness envelope is an attack surface we haven't tested.** A distant plane's rumble swells
  and fades over tens of seconds. The peak time and width give its closest-approach time and d/v.
  `lowband` smooths over 0.75 s and adds ±1.5 dB of slow random gain. That's probably not enough
  against an attacker that matches the whole envelope. The next step is an envelope term in the
  matched attacker, then a defense test.

## Defense improvements

- **vDSP fast paths on Apple platforms.** The Swift DSP is portable (it also compiles to
  WebAssembly); the FFT is the one file to swap for Accelerate if the iOS app needs speed.
- **Adaptive chains using Apple's Sound Analysis classifier.**
  - Music detected: fall back to `subtract`, since `lowband` would turn bass notes into noise.
  - Quiet outdoor ambience (the highest-risk case): use the full chain.
  - Speech-heavy clips: `keepVoice` matters most.
- **Make `scurve` sharper for fast sweeps.** Use a 0.5 s analysis window for short τ (close passes)
  and keep 2 s for long τ. A multi-resolution family would let it replace `subtract` in Swift.
- **Refill cancelled bands with matching noise** after `scurve` and `informed`, as `hum` now does
  for its notches, so cancellation never leaves a trough. Keep the refill level static: a level
  that follows the neighbours re-imprints when a tone swept past (the benchmark gate caught this).
- **Choose the cutoff per clip.** Measure where long-lived narrow tones actually stop (often well
  below 300 Hz) and regenerate only up to there, which keeps more voice warmth.
- **Spoof decoys with informed cancellation** worked in synthetic tests: the attacker reported a
  convincing wrong place. It needs flight data, so it suits an "online" mode with a large search
  box, which leaks little about where you are.

## Product

- **Better risk meter.** The web app already shows what the blind tracker finds before and after.
  Adding the `scurve` scores would also flag faint passes the tracker misses.
- **Posting-delay nudge.** Every hour between recording and posting multiplies the flights the
  attacker must try. "Post in 2 hours" is a free, real privacy gain.
- **Shortcuts / App Intent and Share sheet integration**, as discussed early on.
- **Honest UI copy:** "reduces location leakage from sound", never "guarantees".

## Testing and evaluation

- **Real ground-truth recordings.** A small dataset of 60–90 s clips plus saved ADS-B tracks
  (`--save-track`), covering close passes, distant jets, propellers, helicopters and trains. Every
  number so far is from synthetic data.
- **More gate clips.** The gate covers six synthetic scenes. Add a helicopter, a propeller plane,
  two aircraft at once, and real clips once there are some with ground truth.
- **An unknown-time attacker.** Search over the recording-time offset, to measure how much
  stripping metadata alone helps (the attacker only has the post time).
- **Perceptual quality.** ERB loudness change is a proxy. A short listening test, or ViSQOL, on
  real clips would tell us whether `lowband` is truly unnoticeable on phone speakers versus
  headphones.
- **An envelope attacker.** Add a loudness-envelope term to the matched attacker, then measure
  what `lowband`'s smoothing actually buys (the top known gap).
