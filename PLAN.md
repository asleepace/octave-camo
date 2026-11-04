# Plan

The order of work. The reasoning behind the detector work is in [ACOUSTICS.md](ACOUSTICS.md);
unordered ideas are in [IDEAS.md](IDEAS.md); what shipped is in [CHANGELOG.md](CHANGELOG.md).

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

## Now: paths, families and risk classes (slice 3, ACOUSTICS.md §4.4–6)

1. **Paths:** a Viterbi path search through the whitened spectrogram, limiting how fast frequency
   may change, so a Doppler pass or a line that fades in and out is one track, and weak curved
   lines are found (drifting tones are the weak spot: found only at 20 dB, in pieces).
2. **Families:** combine 50/60 Hz harmonics into one grid trace; test high lines for grid lock.
3. **Risk classes:** Doppler, grid-locked, steady (room fingerprint), musical/vocal. The page shows
   them, so singing or a whistled tune isn't presented as a location clue.
4. **Check the decoded saved file,** not only the cloak's float output (AAC can add or hide lines).
5. **The benchmark gate uses the full check** (attacker parity).
6. **Faster:** the integrator costs about 1 s per minute of audio in the browser, twice per cloak.

Done when: a flyby curve is one track, a drifting tone is found at 12 dB at both rates, music is
classed as such, and the noise scenes still give no lines.

## Next: remove what the check finds (step 2)

A real outdoor clip (a plane, passing cars, light rain), cloaked on the site: the page said
"nothing left a tracker can follow", while the line integrator found 19 lines in the saved file.
Most were car tones at 500–950 Hz, inside tone subtraction's range but too faint for its frame
tracker, so it never targeted them; plus 1–1.3 kHz lines and a steady 5 kHz whine. The low band
was clean. So removal must target the integrator's lines at **every** frequency, not only above
1 kHz.

- Fill a narrow strip around each line the check finds (integrator and tracker, any frequency)
  with noise at the local floor's level, crossfaded, wide enough for tracking uncertainty and the
  window's main lobe. Treat strong lines' sidelobes.
- Re-check the decoded file and repeat for anything left.
- Turn on the skipped `testAToneAboveOneKilohertzIsRemoved`.
- **Policy decisions to make alongside:** music (held notes are removed today), the speech
  "long tone" and footsteps 100 Hz known issues.

## Then

- **Pitch wobble up to 8 kHz** as a second layer (it breaks drift matching and ENF), after a
  listening check.
- **Aggressive mode:** voice isolation (RNNoise in wasm) with the rest rebuilt, or keep only the
  talking. The check scores it like everything else.
- **Erase brush** on the spectrogram for manual removal.
- **Decoys,** as an experiment scored by the true flight's rank against a decoy-aware attacker.
- **"Outside this tool's reach" note** on the page: broadcasts, bells, sirens, wildlife, the room
  (ACOUSTICS.md §7).

## Housekeeping

- Delete the merged branches: `review-tests`, `test-net`, `tone-check`, `detection-baseline`, `tidy`,
  `line-integrator`, `invariants-docs`.
- The next release (after v0.1.1, at `19e6902`) collects the work since then.
- Allowlisting `download.swift.org` would let Swift tests and wasm builds run outside CI, which
  would shorten every round trip above.
