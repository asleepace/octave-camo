# Ideas backlog

Things that came up while building and testing. Each is roughly ordered by value for effort.

## Sparks: observations and outside-the-box ideas

A short running list of things noticed in real recordings or worth trying someday, kept loose on
purpose. Real-clip numbers are from a handful of indoor and outdoor phone recordings.

- **The loudness swell gives the time away.** A blind search, using only the low band's loudness
  over time and the public ADS-B archive for one place, put a 15-minute indoor recording in the right
  minute (3rd of 1,835 start times over two hours), with no plane audible to the person recording. The phone heard what the ear didn't. → The Experimental preset flattens it.
- **Jets aren't point sources.** In two passes so far, an arrival was heard ~20 s *before* its
  closest approach and a climbing departure *after*. That's what jet noise directivity predicts
  (fan noise forward at low thrust, exhaust aft at full thrust). If it holds, an attacker should
  weight loudness by flight phase and heading, and so should our tests.
- **Rooms have fingerprints.** The same handful of steady lines appears in every recording from one
  room: appliances and fans. They don't say where, but they link
  videos to one place. → An "unlink" option that removes a room's steady lines.
- **Background TV or music is the cheapest attack of all:** match it against broadcasts and you have
  the time and the region. → At least a warning; maybe detect broadcast audio and offer to remove it.
- **Walls are low-pass filters.** Doors and walls cut the highs far more than the lows, and ears are
  least sensitive to the lows, so indoor clips carry rumble no one in the room notices.
- **Direction needs wavelength.** Phone mics a few cm apart can tell direction at kHz, not at 50 Hz
  (a 7 m wavelength). Spatial (ambisonic) capture also cuts below ~30 Hz. Direction finding helps
  outdoors, where the highs survive; indoors the rumble has no direction to give.
- **Self-calibrating recordings.** A sweep played by the phone at the start and end of a clip pins
  the audio clock to the device clock to ~2 ppm and the timing chain to <1 ms, and gives the room's
  echo time (~0.2 s in a furnished room).
- **Decoys only work on clean audio, and only if they match a real flight** at a wrong place or
  time: a fake path matches nothing and costs the attacker nothing. Scrub first, decoys on top.
- **Other scheduled sounds are clocks too:** church bells on the hour, ferry horns, train horns at
  crossings, garbage trucks, school bells. Each is a timetable an attacker can match.
- **A barometer hears doors.** A door closing makes a small pressure pulse; with the recorder's
  pressure log and tap-to-mark labels, door events could be detected and excluded automatically.

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
