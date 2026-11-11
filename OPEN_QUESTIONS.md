# Open questions

These are things we don't know yet, written down so they don't get treated as settled. Each one
says what's known, why it matters, and what would settle it. When one is answered, move the answer
into [docs/EXPERIMENTS.md](docs/EXPERIMENTS.md) (or the code) and delete it here.

The attacker and score these refer to are defined in [THREAT_MODEL.md](THREAT_MODEL.md) ("The
attacker every result is scored against").

## Scoring

### Is the corpus score fair on real audio with no plane in it?
- **Known:** `u` (the truth's rank among wrong places' curves) averages 0.49–0.56 with about 5 % in
  each tail on *synthetic* plane-free audio (room noise, music, pink noise), for 1, 2, 4 and 8
  lines. `lab/tests` checks the rank itself is uniform when the truth is one more draw.
- **Not known:** whether that holds on real plane-free recordings, where the background isn't
  stationary or smooth.
- **Why it matters:** every corpus number assumes it. If real backgrounds push u off 0.5, leaks
  and holes are miscounted.
- **Would settle it:** u on plane-free real stretches (quiet windows of our own sessions with no
  aircraft in the saved tracks, or a public recording known to be aircraft-free).

### Do the corpus's wrong answers make it easier or harder than the place search?
- **Known:** the corpus's wrong places are the other passes' traced shapes, with their closest
  approach within ±6 s of the truth's. Real wrong places in a 16 km box can be tens of seconds off,
  and a geometry close to the truth's scores about as well as the truth.
- **Not known:** which way this biases u relative to the place search's p.
- **Would settle it:** on our own sessions (place known), compute both u and the place search's p for
  the same clips and compare.

### How many lines should the attacker add, and how?
- **Known:** four lines find far more leaks after cloaking than one (fixed stop: 12 of 34 against 3).
  Eight finds about as many as four. A plain sum is the simplest choice; weighting the lines
  (likelihood ratio, learned) would be stronger.
- **Why it matters:** a stronger statistic moves every number, and the cloak should be judged
  against the strongest plausible attacker.
- **Would settle it:** compare statistics by how well they find planes in *untouched* audio (power),
  without tuning them to the cloak.

### The place search on our sessions still uses one line
- `lab locate` hasn't been switched to the four-line statistic, so session results are against the
  weaker attacker. Switch it and re-score the tuning sessions.

### Does a hole matter to a real attacker?
- A truth that scores unusually *low* is counted as a loss, to be safe. Nobody has measured how well
  an attacker could exploit one. Until then it stays counted.

### How many seeds does a decision need?
- **Known:** one pass's u under two seeds correlates only 0.3–0.8. On 17 passes × 2 seeds,
  differences under about 0.1 in mean u aren't resolvable.
- **Would settle it:** a power estimate from the per-pass spread already measured, before the next
  comparison.

### The tuning half is getting worn
- The same 17 corpus passes have been used to compare many variants, so their numbers are now
  optimistic. The holdout half has been looked at once (all 35, before the split) and must be scored
  only once more, when a change is settled.

## The cloak

### Why do the remaining leaks leak?
- **Known:** after cloaking, the four-line attacker still finds 8–12 of 34 passes (chance: about 2).
  Of the lines it adds up in leaking copies, about a third were clear lines before cloaking.
- **Candidates:**
  - faint real lines the engine never reaches (its stopping test is biased, see below);
  - lines it fills only partly (tolerance, tracking);
  - the fill itself (next question).
- **Pitfall:** a per-line z against wrong places *on the same clip* can't separate these. See
  "Pitfalls" below.
- **Would settle it:** for each leak, the truth's four picked rest frequencies against wrong places'
  values at the same rests on the *cloaked* audio, together with the engine's list of what it
  filled.

### Is the fill neutral on real backgrounds?
- **Known (synthetic white noise):**
  - Along a slowly sweeping line (10 Hz/s) the median fill comes out +0.4 dB in mean power (6 seeds,
    about 3 standard errors) and +0.2 dB in mean log power. At 40 Hz/s it's +0.2 dB, within noise.
  - In the attacker's own statistic it's +0.01 to +0.04 (lines are ~0.4).
  - Cause of the power bias unknown.
- **Not known (real backgrounds):**
  - A probe on the corpus clips read −0.5 below 600 Hz for every fill level tried.
  - Those clips contain a plane, though: the probe's curves cross its lines and the fill removes
    them, so that number is confounded.
- **Why it matters:** a fill that differs from what it replaces lifts or lowers every wrong curve that
  crosses it, while the true curve runs parallel to it and is unaffected. Either way the truth stands
  out.
- **Would settle it:** the same probe on plane-free real audio.
- **Then:** pick between `LineFill.level` `.median` (default), `.logMean` and `.binTime`. All three
  are experimental until then.

### The engine's stopping test is biased in noise
- **Known:** in white noise along the test pass, the engine's z (the curve against itself 20–60 s
  away) averages 0.9 with one line and 1.3 with four, up to 3.2. A fair test would average 0. With
  the stop at z 1, the fill acts on noise about half the time.
- **Would settle it:** give the verdict wrong places' curves as its null (as `u` uses), then check
  it averages 0 in noise.

### Is the plane-free pink hole real, and is the stop's bias its cause?
- **Known:** 24 plane-free pink runs, paired with untouched: the fixed stop is lower by 0.07 ± 0.04
  (four lines). Room and music show nothing.
- **Would settle it:** fix the stopping bias above, then rerun.

### How good is the synthetic engine model?
- **Known:** `nulltest.engine` has a main line plus Poisson(2) others, −6 to +3 dB, mostly not
  harmonics. It was fitted roughly from lines at z ≥ 4 along the corpus's curves. That per-rest z
  undercounts faint lines next to strong ones (the crossing lift, see "Pitfalls").
- With it, the synthetic test agreed with the corpus on one comparison (fixed against no-raise).
  One agreement isn't validation.
- **Would settle it:** a few more comparisons where the synthetic test and the corpus are run side
  by side.

### Is the null target worth keeping?
- **Known:** on synthetic scenes it got close to a fair score. On the corpus, raising rebuilt plane
  traces along the true curve, and against wrong places' curves `.null` (with or without raising)
  was no better than `.fixed`. It stays experimental and off.
- **Decoys** (faint fake passes at wrong times or places, rather than raising the truth) are the
  untried alternative.

### Line separation is in rest frequency
- `lines_of` (lab) and `TrackFill.lines` (engine) keep picks at least the tolerance's width apart in
  *rest* frequency. Where the curve's Doppler factor is below 1, the observed gap is narrower (down
  to half), so "one line counts once" is approximate. It applies the same way to the truth and the
  wrong answers, so ranks are fair. Worth tightening only if a statistic ever depends on it.

## Pitfalls we've hit

These are ways a flawed assumption got in before. Check new work against them.

- **Few wrong answers make a loose z.** Six wrong times put one corpus pass at z 20.8. Against 144
  wrong places it simply ranks first. Rank against many wrong answers instead.
- **A synthetic stand-in can steer a design.** A tone with ×2 and ×3 made the null target and the
  harmonic fill look good. Real engines aren't like that, and the corpus didn't confirm either.
  Check a synthetic result against real data before acting on it.
- **The crossing lift (it misled us twice).** A strong line lifts every wrong curve that crosses it
  at nearby rest frequencies, but never the true curve, which runs parallel to it. So:
  - a per-line z against wrong places on the same clip is depressed near strong lines;
  - removing a line "raises" its neighbours' z without anything along the truth changing;
  - a fill probe on audio that contains a plane measures the removal of that plane, not the fill.
  Compare on the same cloaked audio (as `u` does), or use plane-free backgrounds.
- **One seed per copy.** A single cloaked copy is one draw. Results within about ±0.1 on 17 passes
  are noise.
- **Loose tolerances hide biases.** "Strip vs beside within 2.5 dB" passed a fill that's 0.4 dB loud
  on average, and a guard off by one skipped every frame of a line exactly on a bin centre. An
  invariant test needs a tolerance set from the measured spread, not a generous guess.
- **Importing `lab.nulltest` switches off the whitening cache** for the whole process, by design.
  Shared helpers (`locate.rank`) live in `locate`, not there.
