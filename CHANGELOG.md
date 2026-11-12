# Changelog

All notable changes to octave-camo. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). No versions are tagged yet, so changes
are grouped by milestone, newest first, with the commits that made them.

> **Proof of concept.** Nothing here is a guarantee of anonymity. See
> [THREAT_MODEL.md](THREAT_MODEL.md).

## [Unreleased]

### Deep filling leaves a trace (finding)

- With no plane present, filling 40 strips along a curve raises the attacker's rank (+0.18 on white
  noise, +0.48 over steady tones): independently drawn fill cells are spikier than real noise to the
  attacker. Light filling is unaffected. docs/EXPERIMENTS.md, "Deep filling leaves a trace of its own".
- **`--track-fill-level shift`**, experimental: copies the same bins from another moment of the
  recording. It clears the steady-tones case but not white noise.
- The rank stop's summary now says why it stopped short ("out of fills", "out of lines").

### The cloak judges like the attacker (experimental)

- **`Attacker`**: the lab's scoring attacker (best four lines, the lab's whitening, rank among wrong
  places) in the engine, equal to the lab's ranks to three places on the public corpus.
- **`--track-target rank`**, experimental: fill the attacker's best line, one at a time, until the
  pass's rank falls below a target drawn uniformly from 0 to 1. Passes ranking below 0.9 are left
  alone. Options `--track-act-above`, `--track-rank-rounds` (0 only measures), and
  `--track-rank-null scaled|library` (default scaled: the truth's own curve, scaled; physical flights
  were too easy to beat). On the corpus tuning half it leaks 5 of 34 (default 12, deeper 8) at
  1.16 dB sound change. On real backgrounds it fires on 3 % of copies and leaves under half the
  default's mark. docs/EXPERIMENTS.md, "The cloak judges like the attacker".

### Fair stopping tests, as options

- **`--track-null library` and `--track-null wrongPlaces`**, experimental: the track step's stop
  compares a pass with physical wrong places (the Doppler curves of straight, level flight at other
  closest distances and speeds) or with scaled copies of its own curve, instead of with its own
  flat tails. Both are fair in noise (white-noise z −0.06 to +0.35 against 1.05 to 1.50), and on
  real backgrounds the scaled copies leave no measurable hole where nothing passed. But both remove
  less, and the public corpus leaks more (library 17 of 34 against 12), so the default stays.
  docs/EXPERIMENTS.md, "A fair stopping test".

### Scoring against one attacker, and a review

- **One attacker and one score** (THREAT_MODEL.md): the truth's rank among wrong answers, read at
  both ends (top 5 % a leak, bottom 5 % a hole), against an attacker that adds up an engine's best
  four separate lines. On the public corpus (Pathak 2026, CC BY 4.0) the corpus is scored by `u`,
  the traced curve against the other passes' curves at the same moment; the six-wrong-times z is
  now a diagnostic. Against four lines, cloaked passes leak far more than the one-line score showed.
- **Fixes:** a line exactly on an FFT bin centre was never filled (an off-by-one skipped every
  frame); under the null target `harmonics` 1 still filled ×2. Ranks with an unscorable truth or
  wrong answers come out NaN instead of a hole.
- **Experimental, off by default:** `--track-lines` (the stopping test adds up lines),
  `--track-target null` with `--track-max-raises`, `LineFill.level` (`.logMean`, `.binTime`); the
  null target's harmonic fill is now off (it was tuned on a synthetic engine real ones don't
  match). None is shown better than the defaults yet.
- **OPEN_QUESTIONS.md:** what isn't known yet, and the pitfalls that misled earlier conclusions.

### Track removal: up to 24 tones per pass

- **Removal now fills up to 24 tones per pass** (was 8). On the public 40-flight corpus (Pathak
  2026, CC BY 4.0) 10 of 35 passes hit the old cap with the tone still strong, mostly light
  aircraft whose propellers make many harmonics. Tuning half: median z along the traced harmonic
  2.5 → 1.7; held-out half, scored once: 0.95 → 0.89, three passes better, none worse; sound
  change about the same. No change on our own sessions (none reached 8).
- Options for the stopping test, off by default and documented as tried: slack off the curve
  (`--track-tolerance-hz`, `--track-tolerance`) and extra analysis windows (`--track-windows`);
  the second window cut the corpus's median further but over-filled our sessions and left a hole
  an attacker can find. CLI usage now shows `--track-stop`'s real default (1).

### Place-scored evaluation, and track removal stopping at z 1

- **Track removal now stops at z 1** (was 2.5). Scored by where the clip was recorded instead of
  per flight: tones at z 1–2.5 that no single test calls a pass still add up to rank the true
  place high. A borderline session cleared, for 0.1–0.3 dB more change above 300 Hz; on the two
  held-out sessions both settings cleared them. Benchmark and lab: `--track-stop` on the CLI.
- **The lab's place search is the metric** (from an independent review): 4× faster, rank bits
  against each scene's no-information baseline, a frozen holdout. Findings in EXPERIMENTS.md:
  Full alone leaks the place on three sessions, removal from the flight archive on one (stale
  positions); cleaning around a faint pass can make it easier to find.
- **Review fixes:** the benchmark saves at the page's 160 kbps and measures sound change on what a
  listener gets; metric names say what they measure; the evidence tables give the true location's
  rank; PathSearch's cache is locked.

### Flight-track removal on the page

- **The page can remove what flight logs predict.** It reads where and when the clip was recorded
  from the file's own metadata before dropping it (Apple's ISO 6709 key or the `©xyz` atom, and
  the creation date), or takes them typed in. It links adsb.lol's half-hour archive for that time,
  which the user downloads and adds: one worldwide file per half hour, so the download says the
  time and never the place, and the page itself still makes no requests (adsb.lol sends no CORS
  headers anyway). The engine picks the aircraft near the place, predicts their Doppler curves and
  runs `TrackFill` after the preset's stages. Optional and off until an archive is added.
- **`FlightArchive` and `PassPrediction`:** the archive's positions carry their 10 s block's time,
  a few seconds stale, so one predicted curve's shape is unreliable; each aircraft gets four
  (two interpolations, a local straight-line fit, one anchored to the archive's ground speed). On
  the three real passes, removal driven only by the archive leaves the attacker holding the exact
  tracks at −1.6, −0.5 and −0.2 (one curve per aircraft left the deck pass at 2.8).
- **`TrackFill` faster and wider:** every rest frequency scored at once on a log-frequency axis,
  timings shared between offsets and null shifts (a synthetic 4-curve case: 71 s → 4 s; a
  3-minute 48 kHz clip with 40 curves adds about 16 s in wasm). Fills reach the timing slack
  beyond the searched window and widen by 1 % of frequency, for curve error. Passes are handled
  in a fixed order (the order of a dictionary was random per run).
- **Faster testing:** the lab's known-path attacker searches all rests at once on a log-frequency
  axis (48 s → 5 s per session, scores within a few tenths); the wasm build has its own folder
  (`.build-wasm`), so switching no longer relinks the native build or swaps out its CLI (a no-op
  native build: 67 s → 1 s), and reuses wasm-opt's output when its input hasn't changed (65 s →
  2 s).
- **CI and tests:** the full suite runs on pull requests (a push to main only builds and deploys,
  and docs or lab pushes run nothing); Swift tests run in parallel, one process per test; the
  detection baseline (a third of the suite, 283 s) is four parallel parts, and the monotonicity
  test it duplicated is folded into it; every job has a time limit.
- **Full flattens the low band's slow loudness too** (gently: swells slower than 10 s;
  Experimental keeps 5 s). The strengths are named (`off`, `gentle`, `strong`) and swappable per
  preset: `FLATTEN` and `web/src/presets.ts` on the page (now shared with the lab's runner),
  `LowBandRegeneration.Flatten` and `--flatten off|gentle|strong|N` in the engine and CLI, whose
  default is now gentle. On a 767 at 3 km that no tone attacker sees, the envelope attacker's
  z goes 5.5 → 0.2, for 0.4–2.6 dB of 60–250 Hz level.
- **Lab: the envelope attacker** (`lab envelope`): does a recording's slow level follow a flight's
  predicted level (a jet's broadband roar, invisible to the tone attackers)? A fit holding the
  swell to its physical size, after a correlation proved too weak to see one. It finds a 767 at
  3 km that no tone attacker sees (z 5.5), and **Full keeps that swell (5.2)**; Experimental's
  flatten removes it (0.3).
- **CLI:** `scrub --archive file[,file] --at lat,lon[,alt] --start unix [--temp C]` and
  `predict` (the curves, without positions). **Lab:** `trackfill <session> … --archive` runs the
  page's path.

### The curve benchmark and a first learned detector (lab)

- **`python3 -m lab bench`:** realistic synthetic passes (engine tone families, air absorption,
  directivity, ground reflection, engine-speed wander, scintillation, window filtering) mixed into
  real plane-free recordings and synthetic scenes; detection by strength and false alarms per hour
  for the page's check, the lab's blind search and the known-path attacker.
- **`python3 -m lab ml`:** a 14 k-parameter convolutional curve detector (JAX, CPU), trained on
  synthetic passes in training backgrounds only, feeding the same path search and flyby fit. On
  held-out backgrounds it detects more passes than the check from 9 to 18 dB/Hz and it finds the
  faint real pass the check misses; on real construction audio it raises far more false passes
  (~38/h). Not ported: the lab is where it improves next. Weights stay in `$LAB_DATA` (trained on
  private backgrounds).

### Track removal closes the known-path leak (engine and lab)

- **`TrackFill` runs the known-path attacker's own test and removes until it fails:** the best
  mean excess along the predicted curve over all rest frequencies and ±6 s, against the curve at
  ten wrong times; while z ≥ 2.5, fill the best tone and test again. On three real passes the
  attacker's z after Full + tracks: 6.3 → 0.8, 10.1 → −2.5, 2.8 → −0.2. Plane-free sessions are
  left alone. Not on the page yet.
- **Parity fixes:** curves that leave the band are skipped, as the attacker skips them; the
  running median uses quarter-second blocks (1 s blocks under-scored a real pass and stopped two
  tones short). `ExpectedPass` takes the heard closest-approach time and two minutes either side.
- **Lab:** curves handed to the engine are cleaned (velocity glitches where two position sources
  disagree gave factors over 2 and heard times running backwards).

### Flight-track removal (engine and lab only), a place-searching attacker, tidier docs

- **`TrackFill`, removal driven by flight tracks:** given each aircraft's predicted Doppler curve
  at the recording position (`ExpectedPass`: audio times and factors only, never a position), it
  finds the tones following the curve (rest frequency free, a few seconds of timing slack, against
  the same curve at wrong times) and fills them. CLI `scrub --expect passes.json`, lab `trackfill`.
  Not in the page, and not to be used on real clips yet: on the one real session it was tried on,
  removing some of a plane's tones made the rest more detectable (docs/EXPERIMENTS.md).
- **The place-searching attacker** (`python3 -m lab locate`), after the video that inspired the
  project: every point of a grid scored by every aircraft's predicted curve on one timeline.
- **Invariant tests:** the path search ignores gain (boosting can't help it, attenuating can't hide
  from it), moves with a delay, rejects rising sweeps; the noise fill sits within 0.5 dB of its
  surroundings along a curve; track removal is a no-op without passes, refuses unusable ones,
  touches nothing outside its curve, fills nothing on noise, on speech or at the wrong time, and
  runs after the low band and before `lines`. They caught a masking bug that made ghost tones.
  The lab has its own (`lab/tests`): a 40 dB band-stop over a sweep doesn't hide it from a
  whitened detector, the Doppler geometry, the cache key, alignment. CI runs them, plus a link
  check of the docs.
- **Docs moved to `docs/`** (ACOUSTICS, EXPERIMENTS, IDEAS, PLAN, RESEARCH, SOURCES, with an
  index); README, CHANGELOG, CONTRIBUTING, SECURITY and THREAT_MODEL stay at the root. The README's
  layout, check and limits are up to date; PLAN is reorganized into done, now and next.
- **Tooling review:** the check's flyby fit now needs a distance under 30 km (a looped footstep
  fit a "pass" 3·10¹⁷ m away); the lab's flyby fit includes the sound's travel time (its speeds
  and distances were biased); the corpus measures heights against ADS-B with the phone's pressure
  (both barometric) instead of GPS; tests that couldn't fail now can (harmless scenes run long
  enough for the path search, the falling-notes test requires the search to find the sweeps).
- **Second review:** track removal fills one tone per pass and searches again instead of masking
  (masking left a loud tone's shoulders and ghosts); the lab's known-path attacker uses means and
  34 wrong-time curves (eight made its spread fragile: z could jump after a cloak with less
  evidence left) and reports the effect in dB; key numbers re-measured.
- **Review fixes:** the path search's cache is marked as single-threaded state; the pipeline runs
  track removal between two explicit stage groups; passes are validated (finite, increasing,
  physical factors); the lab's shared plumbing moved out of `__main__` (`lab/common.py`), and its
  dependencies are listed (`lab/requirements.txt`).

### The check follows a jet's fan tone

- **A second detector in the check, `PathSearch`:** short windows (0.17 s) over 500 Hz–4 kHz, each
  frequency against its running median and each frame against its own median, then a search for
  smooth falling paths in 10 s spans, joined into passes that must last longer than one span. A
  pass is kept only if the check's flyby fit accepts it. The frame tracker's 1 s windows smear a
  fast sweep (a fan tone falling 1.75 → 1.0 kHz in 25 s) below its threshold; the path search
  finds it from ~14–16 dB/Hz. Because `lines` fills what the check finds, the Experimental preset
  now removes it.
- **On a real indoor recording with a jet overhead:** the page now reports the flyby on the
  original and after Full (it said nothing was left); after Experimental the check, the lab's blind
  detector and an attacker who knows the plane's real track (z 9.8 before) find nothing. Seven
  plane-free recordings report no pass. The check takes about 45 % longer.
- **Detection baseline:** the drifting 1.2 kHz pass is covered whole at 20 dB (was 14–17 %), and
  partly at 12 dB at 48 kHz (was not at all).
- **Lab:** `python3 -m lab check` runs the page's check (`web/scripts/check-raw.ts`, the real wasm)
  on a session and its cloaked copies. Fixed: the spectrogram cache ignored a file's contents, and
  backfill kept archive rows that aren't positions, which broke the known-path attacker's curves.

### A smaller wasm, the saved file checked again, and the tone fill keeps voices

- **Smaller wasm:** release builds go through binaryen's `wasm-opt -Oz` (pinned by a lockfile in
  `tools/wasm-opt`, installed in CI and in the release rebuild; the build stays byte-for-byte
  reproducible). 7.5 → 3.6 MB raw, 2.0 → 1.3 MB gzipped. `-Osize` alone saved almost nothing.
  Measured by a new on-demand **Wasm size** workflow (`web/scripts/bench-wasm.ts`), which put
  `wasm-opt` at about 7 % slower on a 60 s, 48 kHz cloak; `OPT=size` builds for size.
- **The saved file's sound is checked again:** after saving, the page decodes the file it wrote and
  runs the check on it in the worker (`check` request → `checked`), shows "saved N" next to each
  count, and warns if the encoder added tones. What gets posted is the AAC file, not the float output.
- **`lines` keeps voices:** a line is left alone when, over its span, a quarter of the frames are
  voiced and in a fifth of those one of the tracked pitch's first four harmonics sits on it. On the
  speech scene the check's six lines are all a voice's recurring pitch: before, they were filled
  (and a second pass found seven more next to them); now speech is kept whole (1.0, was 0.92).
- **The fan-tone test was passing for the wrong reason,** and found a gap in the check: at 20 dB
  the check saw only the part below 1 kHz, and even at 30–40 dB it follows a sweep this fast
  (~40 Hz/s) only up to ~1.15 kHz, because its 1 s windows smear it. The test now uses 35 dB,
  where Full leaves the part above 1.1 kHz and `lines` removes it. Fixing the check comes next
  (PLAN.md).

### Step 2 in Experimental: fill in whatever the check finds

- **Why:** on a real indoor recording, a climbing jet's fan tone swept from 1.75 to 1.0 kHz for
  25 s, clear enough that a flyby fit from the sound alone put its closest approach in the same
  second as the ADS-B track. Full's tone subtraction stops at 1 kHz and its flyby search at ~600 Hz
  base frequency. Earlier, an outdoor clip cloaked
  with Full kept faint car tones and a 5 kHz whine: the check (up to 8 kHz) found them; nothing
  removed them.
- New stage `lines` (`LineFill`, last in the chain): asks the check for every line it reports, with
  its frequency path (`FlybyAnalyzer.lines(in:)`, which `analyze` now classifies, unchanged), and
  replaces a strip along each path with noise at the median level of the bins beside it. The strip
  covers the window's main lobe, a tracking margin and the sweep within a frame; it fades in and
  out at the ends. Then the check looks again (2 passes). It works on one stretch and one band at a
  time (`BandSTFT`), so memory follows the line, not the clip.
- In the page's **Experimental** preset (with the flattened low band); `--steps …,lines` on the CLI.
  Full is unchanged. It removes held musical notes as readily as engines: that's the music policy
  still to decide before it can join Full.
- Tests: a steady 1.2 kHz tone filled at 16 and 48 kHz with no hole and nothing changed beside it; a
  modelled jet fan tone (1.23 kHz, 141 m/s, 2 km, 1.7 → 0.9 kHz received) removed with `lines`
  (see the entry above: at that level the check only saw the part below 1 kHz); nothing changes when the check finds nothing; speech mostly
  kept (≈ 0.92: the check finds a few long tones in a voice, and they're filled); seeded; the band STFT
  edits only its band. `testAToneAboveOneKilohertzIsRemoved` is on (with `lines`).

### Experimental preset: flatten the low band's slow swells

- **Why:** on a real 15-minute indoor recording, a blind search lining up the 30–150 Hz loudness with
  every aircraft's ADS-B track found the right minute (3rd of 1,835 start times over two hours). The
  regenerated low band follows each band's loudness smoothed over 0.75 s, so a passing plane's rise
  and fall over tens of seconds goes straight through: simulated, the cloak only lowered the true
  start to 8th, while flattening swells slower than 5 s put it at 1,613th (chance).
- `LowBandRegeneration.flattenSeconds` (0 = off, the default, so Full and every snapshot are
  unchanged): each band's loudness, in dB, minus a centered triangular running average (a box that
  many seconds wide, twice), plus the band's median. Quick sounds (thumps, doors) keep their
  contrast. (A running median was tried first: with thumps every 2 s it ate 4 dB of their contrast,
  because a 5 s window holds two or three of them in turn; the triangle's sinc² response cancels
  anything that recurs within the window.)
- The page's **Experimental** preset is Full plus `flattenSeconds = 5`; the CLI takes `--flatten 5`;
  the wasm `camo_scrub` takes it as a last argument.
- Tests: a 12 dB swell over ~30 s survives plain regeneration (> 8 dB, the leak pinned) and is gone
  when flattened (< 3.5 dB); thumps keep their contrast; the helper's edge cases; off by default. On
  the real wasm build, a plane-like rumble swell's correlation with the output: Full high, Experimental low.
- IDEAS.md starts a short "sparks" list: things noticed in real recordings and ideas worth trying.

### Clips up to 10 minutes

- The page takes clips up to 10 minutes (was 5). Past 5 minutes the worker cloaks and checks the
  audio in balanced, overlapping parts of at most 4 minutes (`web/src/engine/chunks.ts`): each part
  carries 10 s either side so every stage has settled at the seams, which are crossfaded over 2 s
  above and below 300 Hz with gains set by how alike the parts are there (level kept for the same
  sound and for fresh noise alike). Tones found by neighbouring parts are joined, so one crossing a
  seam is counted and outlined once. Part *k* uses seed + *k*.
- The button shows the part (`CLOAKING 2/3…`); the stage log says how many parts.
- Clips up to 5 minutes go through in one piece, exactly as before.
- Tests: the parts arithmetic, an exact round trip, seam levels for unrelated noise, the joining
  of tones; a ten-minute 48 kHz clip on the real wasm build (one line across both seams, no click,
  nothing left to follow, a flyby on a seam removed; time and memory printed); and in the browser,
  a 330 s clip cloaked in two parts and saved whole.

### Spectrogram labels and an outline toggle

- The note under the spectrogram says "original" and "cloaked".
- An eye button next to it hides or shows the outlines (faint, white on hover; remembered in this
  browser when it can be).

### Check invariants and current docs

- **Check invariants** (`CheckInvariantTests`): reports are well-formed (finite, inside the clip and
  the search range, counts nested, longest first) for every scene at 16 and 48 kHz; the same input
  gives the same report; a 5 s delay moves a line 5 s and not in frequency; a line is the same
  played backwards (a grid family too); the sample rate doesn't move a line; a stronger tone is
  never harder to find; and a loud sound elsewhere doesn't hide a line.
- **Docs:** ACOUSTICS.md §1 describes the check as it is (tracker + integrator) with before/after
  numbers and both real clips; PLAN.md moves slices 1–2 to done and slice 3 to now; THREAT_MODEL.md
  and README.md say plainly that faint tones, and any above 1 kHz, survive the cloak today; the
  page's "Cancel long tones" step says the same.

### The check integrates over seconds (slice 2 of ACOUSTICS.md §4)

- **A line integrator** (`LineIntegrator`) joins the frame-by-frame tracker in the check. It works
  in physical units (a window close to 1 s at any sample rate, a 0.5 s hop), divides each frame by
  its local median floor, and tests every slowly drifting path over 3 s and 8 s spans: is it above
  τ in at least half the frames? τ comes from the binomial tail for a false alarm budget over the
  whole search, not from a hand-set dB figure. A line must also be narrow, and weaker neighbours
  (sidelobes) are suppressed.
- **What it changes** (prototype measurements on the detection scenes): steady tones are found at
  6–9 dB over the noise in a 1 Hz band (the frame tracker needs 12–20 dB, and at 48 kHz missed tones
  above 1 kHz entirely); weak grid harmonics with no fundamental are found at 6 dB each; noise
  (white, pink, wind, traffic) gives no lines. Speech, birdsong and footsteps stay clean; a
  whistled tune that repeats its notes does show lines.
- Its lines are classed as hum or steady, never Doppler: their drift is slow by construction.
  Passing sources stay with the frame tracker until the path search (slice 3).
- **Measured in Swift** (`Snapshots/detection.json`): at 48 kHz, steady tones at 1.2 and 4.5 kHz are
  found from 9 dB (before: not at 20 dB); weak grid harmonics at 6 dB per harmonic, about 16 of 19
  at 16 kHz (before: none); intermittent tones at 15 dB at both rates (before: none at 48 kHz).
  No lines in any noise scene.
- **It found a cloak artifact:** the cloaked footsteps scene gains a steady line near 100 Hz,
  classed as hum (a known issue with a skipped target test). Singing and a repeated whistled tune
  now show many lines, and speech a few: telling music and voices from machines is slice 3's.

### Tidying

- The worker reports at most the 1,000 longest tones for outlining (the counts stay complete), so a
  dense clip can no longer fail the message check and lose its whole analysis.
- One seeded generator (`web/src/random.ts`) instead of eight copies, one percentile helper, and
  the spectrogram's axes moved into its module. Swift tests share their seeded pipeline,
  band-energy and snapshot record-and-compare code (`TestSupport.swift`).
- SwiftPM no longer warns about the snapshot files; a test's denormal literal no longer warns.
- THREAT_MODEL.md's known gaps: tones above 1 kHz, the check's sensitivity, room fingerprints,
  music and voices, and that cloaking is detectable.

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
- **Detection baseline** (`Snapshots/detection.json`): how weak a tone the check still finds (steady,
  drifting and intermittent tones, weak grid harmonics, 0–20 dB over a 1 Hz noise band, at 16 and
  48 kHz) and how often it reports one in noise (none). At 48 kHz it misses tones above 1 kHz even at
  20 dB: the baseline for the new detector (ACOUSTICS.md §1).
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
