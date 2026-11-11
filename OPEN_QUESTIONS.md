# Open questions

These are things we don't know yet, written down so they don't get treated as settled. Each one
says what's known, why it matters, and what would settle it. When one is answered, move the answer
into [docs/EXPERIMENTS.md](docs/EXPERIMENTS.md) (or the code) and delete it here.

The attacker and score these refer to are defined in [THREAT_MODEL.md](THREAT_MODEL.md) ("The
attacker every result is scored against").

## Scoring

### Is the corpus score fair on real audio with no plane in it? (answered: yes, in aggregate)
- Answered in [docs/EXPERIMENTS.md](docs/EXPERIMENTS.md) ("Real backgrounds"). Every tuning-half
  shape was placed as the truth at 91 moments in 16 of our sessions where no tracked aircraft came
  within 4 km. Over 1,547 scores, u averages 0.494–0.496 (per-session means 0.49–0.51 ± 0.007), with
  5.4–6.6 % in each 5 % tail.
- **Left open:** single shapes carry a baseline of their own with nothing there (0.33 to 0.59
  across shapes). A single pass's u should be read against its shape's baseline; aggregates are
  fair.

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

### The place search on our sessions needs re-scoring
- `lab locate` hasn't been switched to the four-line statistic, so session results are against the
  weaker attacker.
- Its p-values (`locate.null_bits`) drew each aircraft's wrong-place z independently, which loses
  the dependence between aircraft that share a background. With strongly correlated aircraft that
  understates the null's spread, and the truth looks rarer than it is (an independent review's
  stress test: a tail of 0.0005 against 0.0094). Draws are now joint by default (one wrong place,
  all its aircraft). The session numbers in docs/EXPERIMENTS.md were computed the old way.
- Switch to four lines, re-score the tuning sessions with joint draws, and check the p-values'
  calibration on scenes with nothing there.

### Does a hole matter to a real attacker?
- A truth that scores unusually *low* is counted as a loss, to be safe. Nobody has measured how well
  an attacker could exploit one. Until then it stays counted.

### Are the lab's scores what a posted video would give?
- `lab zenodo` and `lab blank` score the cloak's floating-point output. A posted video carries AAC
  (or another codec) after the browser's export. The benchmark harness re-encodes (160 kbps AAC);
  the lab doesn't.
- **Would settle it:** score the same copies after the page's own export and a platform-like
  re-encode, and compare u.

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

### Is the fill neutral on real backgrounds? (partly answered: its level doesn't matter there)
- **Answered:** on real backgrounds the fill's level makes no measurable difference to the cloak's
  mark (`lab blank`: the three levels within 0.01). The hole the cloak leaves comes from *what* it
  removes (chance matches, through the biased stop), not from the fill's level.
- **Still open:** in synthetic white noise, along a slowly sweeping line (10 Hz/s), the median fill
  is +0.4 dB in mean power (6 seeds, about 3 standard errors) and +0.2 dB in log power. In the
  attacker's own statistic it's +0.01 to +0.04. The cause is unknown. It doesn't show up as a mark
  so far, but nobody has checked whether a power-based attacker would see it.

### The engine's stopping test was biased in noise (fix built, not yet default)
- **Cause:** it compared the sweeping true curve with its own flat tails (wrong times), and a flat
  curve gets fewer independent tries at the best rest frequency. In white noise z averaged 1.05; on
  real backgrounds the stop fired on 30 % of curves nothing follows and left a hole (−0.029 ±
  0.012).
- **Fix:** `--track-null wrongPlaces` (curves a different geometry gives). In white noise z averages
  −0.06. On real backgrounds it fires on 14 % and the hole is −0.005 ± 0.009. On the corpus, leaks
  +0.04 ± 0.04 (not significant).
- **Open:** whether to make it the default, and whether the null target with fair nulls (remove until
  the score is a random draw from the wrong places) gets leaks down without bringing the hole back.

### Is the plane-free pink hole the stop's bias too?
- **Known:** 24 plane-free pink runs, paired with untouched: the fixed stop is lower by 0.07 ± 0.04
  (four lines). Room and music show nothing. On real backgrounds the same kind of hole is the stop
  acting on noise (above).
- **Caveat:** this was measured against "before", which regression to the mean confounds (see
  "Pitfalls"). It needs rerunning against a blind control, before and after the stop is fixed.

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
- **Measuring a cloak against "before" or against 0.5.** Single shapes have baselines of their own,
  and processing pulls a "before" that landed high or low back toward them. Two runs read as a hole
  and as nothing for that reason alone. Compare with a control that has the same processing but is
  blind to the curve (`lab blank`).
- **Importing `lab.nulltest` switches off the whitening cache** for the whole process, by design.
  Shared helpers (`locate.rank`) live in `locate`, not there.
