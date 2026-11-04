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
- **The check looks up to 8 kHz** and outlines what it finds. Tones above 1 kHz are counted but not
  yet removed.

## Now: an attacker-grade detector (ACOUSTICS.md §4)

1. **Spectrogram in physical units:** about 1 Hz resolution and a 0.25 s step at any sample rate.
2. **Integration along drift:** sliding 2–4 s spans, drift rates within ±6 %/s, tree search.
3. **A derived threshold:** ordered-statistic CFAR. The threshold comes from the effective number
   of independent looks and the search size, for under 0.1 false lines per minute.
4. **Paths:** a Viterbi path search joins detections into tracks.
5. **Families:** combine 50/60 Hz harmonics, and test high lines for grid lock.
6. **Risk classes:** Doppler, grid-locked, steady (room fingerprint), musical. The page shows them.
7. **Tests:**
   - scenes for a strength ladder, drifting tones, intermittent tones and weak harmonic families;
   - noise-only scenes (white, pink, wind, traffic) for false alarms per minute;
   - a detection vs false-alarm curve, to choose the operating point;
   - re-recorded snapshots.
8. **Check the decoded saved file,** not only the float output (AAC can add or hide lines).
9. **The benchmark gate uses the new detector** (attacker parity).

Done when: the 1.2 kHz line in the reference clip is found, the 3.8 kHz line is one track, and the
noise-only scenes stay under the false alarm budget.

## Next: remove tones above 1 kHz (step 2)

- Fill a narrow strip around each detected track with noise at the local floor's level, crossfaded,
  wide enough for tracking uncertainty and the window's main lobe. Treat strong lines' sidelobes.
- Re-check the decoded file and repeat for anything left.
- Turn on the skipped `testAToneAboveOneKilohertzIsRemoved`.
- **Policy decisions to make alongside:** music (held notes are removed today), and the speech
  "long tone" known issue.

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

- Delete the merged `test-net` and `tone-check` branches.
- Tag `v0.1.1` at `19e6902` if not done; the next release collects the work since then.
- Allowlisting `download.swift.org` would let Swift tests and wasm builds run outside CI, which
  would shorten every round trip above.
