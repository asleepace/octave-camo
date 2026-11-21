# Plan

The order of work. The reasoning behind the detector work is in [ACOUSTICS.md](ACOUSTICS.md);
unordered ideas are in [IDEAS.md](IDEAS.md); what shipped is in [CHANGELOG.md](../CHANGELOG.md).

**The principle:** the check (the attacker model behind the page's counts) is the security
boundary. It comes first and must be at least as strong as a real attacker. The cloak is then
judged by it. Removing what the check can't see would only make the page look better.

**The focus, for now: aircraft.** Getting aircraft signatures out reliably comes before anything
else. Room, light and other non-aircraft clues keep what already ships, and their work is parked
(below) until aircraft removal is solid.

---

## Done

- **0.1.0 / 0.1.1:**
  - the cloak (hum, tone subtraction, S-curve cancellation, low-band regeneration);
  - light-flicker removal;
  - metadata and SEI stripping;
  - a reproducible wasm build, with release checks.
- **Accessibility, SEO and link previews.**
- **Spectrogram:** a full-width before/after heatmap, with a playhead and click-to-seek.
- **Regression net:**
  - behaviour snapshots of 13 scenes;
  - clue invariants;
  - protocol fuzzing.
- **The check looks up to 8 kHz** and outlines what it finds on the spectrogram.
- **Detection baseline** (slice 1): scenes that measure the check's sensitivity and false alarms,
  recorded so every change shows as a diff.
- **The line integrator** (slice 2): the check averages over seconds. Steady tones are found at
  6–9 dB over a 1 Hz noise band at 16 and 48 kHz (before: 12–20 dB, and never above 1 kHz at
  48 kHz); no lines in noise (ACOUSTICS.md §1).
- **Tidying:** shared helpers, a found-tone cap, warnings, known gaps documented.
- **Clips up to 10 minutes:** cloaked and checked in overlapping parts past 5 minutes. Further
  (an hour and more): stream the decoded audio and the saved file instead of holding them whole.
- **Experimental preset:** flattens the low band's slow swells (the envelope attack) and fills
  every line the check finds (`lines`, step 2), keeping voices; the saved file is decoded and
  checked again; a smaller wasm (`wasm-opt`, 3.6 MB).
- **The check follows fast sweeps above 1 kHz** (top of slice 3): a second detector for moving
  tones, `PathSearch` (E2's design, [EXPERIMENTS.md](EXPERIMENTS.md)). On a real indoor pass the
  page now reports the flyby after Full, and after Experimental neither the check, the lab's blind
  detector nor the known-path attacker finds it; eight plane-free sessions report no pass.
- **Lab:** recorder sessions with ADS-B ground truth, backfill, the known-path attacker, the page's
  check through the real wasm, and the place-searching attacker from the video ([lab](../lab/README.md)).
- **Flight-track removal** (`TrackFill`, `--expect`, the page's adsb.lol archive path): the
  defender runs the attacker's own test first and removes until it fails. In Full and Experimental.
- **Scoring against the public corpus** (Pathak 2026): 35 passes, a tuning half and a held-out
  half. The held-out half was scored once and is spent.
- **Decoys and the rank stop:** they hide heavy filling's own trace. On the corpus holdout the rank
  stop leaked less but left one hole more than the rule allowed, so the default stayed. Its
  advantage then turned out to belong to the attacker it optimises against (#27).
- **Codec checks:** the page's AAC export and platform re-encodes leave leaks, holes and the
  cloak's mark where they were.
- **An attacker panel with calibration** (`lab calibrate`, #30): judges must be within chance on
  plane-free noise and have power on untouched audio of the kind being judged.
- **Testing at 0.68 s too** (`--track-windows 0.17,0.68`, #29): halves the leak to held-back
  attackers on the corpus tuning half, and is no worse on our sessions and real backgrounds.
- **Data intake:** new sessions split into tuning and holdout by a hash of the id
  ([lab/DATA.md](../lab/DATA.md)); `lab fetch-corpus`; resumable runs (`lab/resume.py`).
- **A findings summary:** [FINDINGS.md](FINDINGS.md).

## Now: new recordings, then the session holdout

What's waiting and in flight is in [STATUS.md](../STATUS.md); the backlog is the
[issues](https://github.com/asleepace/octave-camo/issues).

- **Recordings** (#15): about 45 more sessions like the current ones, so that about 20 held-out
  ones have a scorable aircraft. Close, loud passes help most.
- **The session holdout** (#16): the rule is committed (docs/EXPERIMENTS.md, "The new holdout").
  w68 becomes the default if it's no worse on held-out sessions. Colin agreed to adopt it on that
  basis.
- **The blind control on sessions:** does the preset alone already hide the place? (In flight.)

## Next

- **An attacker of a different kind with power on sessions.** Every judge today looks for the curve
  at another resolution; the loudness attacker reaches p ≈ 0.1 at best. Candidates: engine-tone
  families summed (E5), a learned statistic, the mid-band swell.
- **Both cloaks push the truth below chance on sessions.** It's not significant per copy; is it
  usable across copies?
- **Swells above the low band** (a 737 MAX's mid-band swell survived every preset at z 2.3–2.9),
  loudness normalisation ([#17](https://github.com/asleepace/octave-camo/issues/17)), the pink-noise
  hole against a blind control ([#19](https://github.com/asleepace/octave-camo/issues/19)), native
  encoders ([#18](https://github.com/asleepace/octave-camo/issues/18)).
- **False fills on busy indoor audio** (a TV's tones once fitted one curve at z 8), and the fill
  level along the curve (±0.3 dB).
- **A faster path search:** about 45 % more check time today (spans overlap 4×, so a shared
  forward pass would cut it). A decelerating vehicle can still fit a flyby.
- **The learned detector** (`lab ml`): beats the check by roughly 3 dB on held-out synthetic
  backgrounds, but raises ~38 false passes an hour on real construction audio. It needs harder
  negatives before it's a proposer for the check.

## Later: paths, families and risk classes (slice 3, [ACOUSTICS.md](ACOUSTICS.md) §4.4–6)

1. **Paths:** a Viterbi path search through the whitened spectrogram, limiting how fast frequency
   may change, so a Doppler pass or a line that fades in and out is one track, and weak curved
   lines are found. Falling passes over 0.5–4 kHz: done (`PathSearch`, above; the drifting 1.2 kHz
   scene is now covered whole at 20 dB, was 14–17 %). Still to do: rising or wandering lines, and
   below 500 Hz.
2. **Families:** combine 50/60 Hz harmonics into one grid trace; test high lines for grid lock.
3. **Risk classes:** Doppler, grid-locked, steady (room fingerprint), musical/vocal. The page shows
   them, so singing or a whistled tune isn't presented as a location clue.
4. ~~Check the decoded saved file~~: done (the page decodes what it saved and checks it again).
5. **The benchmark gate uses the full check** (attacker parity).
6. **Faster:** the integrator costs about 1 s per minute of audio in the browser, twice per cloak.

Done when: a flyby curve is one track, a drifting tone is found at 12 dB at both rates, music is
classed as such, and the noise scenes still give no lines.

## Then

- **Pitch wobble up to 8 kHz** as a second layer (it breaks drift matching and ENF), after a
  listening check.
- **Aggressive mode:** voice isolation (RNNoise in wasm) with the rest rebuilt, or keep only the
  talking. The check scores it like everything else.
- **Erase brush** on the spectrogram for manual removal.
- **"Outside this tool's reach" note** on the page: broadcasts, bells, sirens, wildlife, the room
  (ACOUSTICS.md §7).

## Parked: not aircraft

Kept as they are today; picked up once aircraft removal is solid.

- **Experimental → Full?** On real clips: does the envelope attack fail on Experimental output,
  does the place search, and does it sound the same? Plus the music policy (`lines` removes held
  notes today), and the flattened low band's level: on one session it came out 17 dB quieter than
  Full's (60–250 Hz), possibly lost bass.
- **Above the audible band.** Steady tones above 16 kHz (electronics, ultrasonic beacons) pass
  through every preset untouched and fingerprint a room. A gentle low-pass near 16 kHz in every
  preset is the cheap fix (most of it is lost to platform encoders anyway, but not reliably);
  the alternative is extending the line search up there. To decide.
- **Room and grid clues beyond what ships:** grid-lock tests and risk classes (slice 3, items 2–3).

## Housekeeping

- Branches are kept, not deleted (CLAUDE.md). `review-tests` is old work in progress that `main`
  has superseded.
- The next release (after v0.1.1, at `19e6902`) collects the work since then.
