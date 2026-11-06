# Plan

The order of work. The reasoning behind the detector work is in [ACOUSTICS.md](ACOUSTICS.md);
unordered ideas are in [IDEAS.md](IDEAS.md); what shipped is in [CHANGELOG.md](../CHANGELOG.md).

**The principle:** the check (the attacker model behind the page's counts) is the security
boundary. It comes first and must be at least as strong as a real attacker. The cloak is then
judged by it. Removing what the check can't see would only make the page look better.

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

## Now: remove what the flight tracks predict

The known-path attacker saw passes the blind check can't (a faint climb-out under 1 kHz survived
both presets, z 6.3 / 5.7). The phone knows where and when it recorded, so the defender runs the
attacker's own test first and removes until it fails.

- **In the engine and the lab: works.** `TrackFill` (CLI `scrub --expect`, `python3 -m lab
  trackfill`) takes the attacker's statistic and fills until it's below 2.5. On the three real
  passes we have, the attacker's z after Full + tracks is 0.8, −2.5 and −0.2 (docs/EXPERIMENTS.md).
- **Next, for the page:** where the location and time come from (the video's own metadata before
  it's stripped, or the browser), fetching tracks for a wide box so the request doesn't give the
  place away, and speed (about a minute per 2-minute clip in native code today; the null's
  10 wrong-time searches dominate).
- **Then:** fill level unbiased along the curve (±0.3 dB today); engine-tone families searched
  together; a decoy-aware attacker before any decoys.

## Now, alongside: the curve benchmark and a learned detector

A synthetic benchmark measures every detector (`python3 -m lab bench`), and a 14 k-parameter
learned detector (`python3 -m lab ml`) beats the check by roughly 3 dB at 9–18 dB/Hz on held-out
backgrounds and finds the faint real pass the check misses, but on real construction audio it
raises ~38 false passes an hour (docs/EXPERIMENTS.md). Next: harder negatives in training (vehicles
slowing down, beepers, more real outdoor backgrounds), a pass-level score over the whole curve,
more clips per strength; port it to Swift as a proposer for the check only once its false alarms
on real audio are near the check's.

## Next

- **Experimental → Full?** On real clips: does the envelope attack fail on Experimental output,
  does the place search, and does it sound the same? Plus the music policy (`lines` removes held
  notes today), and the flattened low band's level: on one session it came out 17 dB quieter than
  Full's (60–250 Hz), possibly lost bass.
- **Decoys (to discuss).** Silence is evidence, and so is the time between events. Synthetic passes
  consistent with real logged aircraft heard from a *different* place would point a place search
  elsewhere; random fake curves only fool blind checks. Open questions: where to "put" the
  recording (not someone else's home), and whether the decoy itself becomes a fingerprint.
- **A faster path search:** about 45 % more check time today (spans overlap 4×, so a shared
  forward pass would cut it). Its z isn't the lab's (real rooms score far above white noise, so the
  duration rule and the shape test do the work), and a decelerating vehicle can still fit a flyby.

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

## Housekeeping

- Delete the merged branches (everything on the remote but `main` and `track-fill`, once it's
  merged); `review-tests` is old work in progress that `main` has superseded.
- The next release (after v0.1.1, at `19e6902`) collects the work since then.
