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
- It now decides the default: on the holdout the rank stop with decoys leaked 4 of 36 against 7,
  and lost on 3 holes against 0. A uniform target makes holes at about the chance rate (5 % of the
  copies it acts on) by design. If a hole at the chance rate is no tell, the rank stop is the better
  cloak; settling that needs a new held-out set (the corpus's is spent).

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

### Why do the remaining leaks leak? (mostly answered)
- **Answered** (docs/EXPERIMENTS.md, "What the remaining leaks are made of"):
  - About 70–90 % of the attacker's evidence in leaking copies comes from lines the cloak never
    filled. The cloak's own verdict says nothing is left while the attacker's statistic still finds
    them.
  - Told exactly which lines to fill (the attacker in the loop), the fill clears most leaks in one to
    three rounds.
  - Two of 17 passes leak through broadband engine noise whose spectral shape moves with the Doppler
    factor, which line fills can't finish.
- **Done since:** the cloak now has the attacker's statistic (`--track-target rank`,
  docs/EXPERIMENTS.md, "The cloak judges like the attacker"): 5 leaks of 34.
- **Still open:**
  - some passes can't reach their drawn target. **Answered:** they run out of fills (all 24 used
    on 24 rests), and filling more partly writes its own trace (docs/EXPERIMENTS.md, "Deep filling
    leaves a trace of its own"); see "Is the fill neutral?" below. **Done since:** decoy fills
    (`--track-decoys`) let them reach it: 1–2 leaks of 34 (docs/EXPERIMENTS.md, "Decoys").
  - after cloaking, the cloak's rank and the corpus's u part ways (0.11 against 0.54; 0.85 against
    1.00). How much of the remaining leak is the cloak's wrong places not being the attacker's?
    Would judging against both sets, or more varied ones, help? With decoys, N621KS s8 (left alone
    at 0.85, corpus 1.00) is the one leak left on the tuning half: the act threshold, or the two
    wrong-place sets, decide it.
  - band-level treatment for the broadband hump.

### Can broadband Doppler-shifted noise be removed?
- Two corpus passes (N60RS, N451EE) carry evidence spread over a band (hundreds of Hz) whose shape
  follows the Doppler factor. Filling strips doesn't converge.
- Candidates:
  - a time-varying flatten across the band during the pass window, so the hump doesn't move;
  - decoy passes (decoy fills are in: they bring N60RS down to its target, but that's one pass).
- How many real recordings have this isn't known (2 of 17 here).

### Is the fill neutral? (no, when there's a lot of it)
- **Answered** (docs/EXPERIMENTS.md, "Deep filling leaves a trace of its own"): filling 40 strips
  along a curve with no plane raises the attacker's rank, +0.18 on white noise and +0.48 over steady
  tones. Cells drawn independently are spikier than real noise in the attacker's whitened excess:
  same median, a fatter upper tail. `--track-fill-level shift` (copy the same bins from another
  moment) clears the tones scene but not white noise (+0.32), where the scaled-truth null's spread
  is only 0.1 dB in four lines' sum.
- **Answered, by not needing one:** subtracting the tracked line isn't the way out (docs/EXPERIMENTS.md,
  "Subtracting the line instead"). Filling along decoy curves too (`--track-decoys 8`) takes the
  empty-audio trace below what 12 seeds can see (+0.06 ± 0.10 on white noise, +0.04 ± 0.09 over
  steady tones; docs/EXPERIMENTS.md, "Decoys").
- **Open:**
  - is 8 decoys enough against an attacker with more wrong places, or different ones? The decoys
    are the truth reshaped, as our attacker's wrong places are; a corpus-style attacker's places
    (other flights) aren't among them.
  - can an attacker find the processed curves blindly, and then pick the truth as the most
    plausible flight among them? The decoys are drawn so their arrangement says nothing
    (`testDecoysDontPointBackToThePass`), but some imply speeds or distances no real flight has.
    Decoys drawn from real flights' shapes would close that, at the risk of matching our wrong
    places less well (physical flights were too easy to beat as the stop's null).
  - why does one removal raise its neighbouring rests by up to +1.5 (N784MB)? Not the flat parts.
    The per-bin 15 s reference is the suspect, unconfirmed.
  - how much of the corpus leakage after cloaking is this, and not lines left unfilled?
  - on real backgrounds, with how many fills does it start to matter? `lab blank` only saw the
    light default (0.6 tones per copy).
- The level test (`testEveryLevelKeepsNoiseAtItsLevel`, six seeds) reads the median fill's power
  bias as +0.4 dB with one set of draws and +0.75 with another: its 0.6 dB bound isn't a margin.
- Earlier, on the fill's level:
- **Answered:** on real backgrounds the fill's level makes no measurable difference to the cloak's
  mark (`lab blank`: the three levels within 0.01). The hole the cloak leaves comes from *what* it
  removes (chance matches, through the biased stop), not from the fill's level.
- **Still open:** in synthetic white noise, along a slowly sweeping line (10 Hz/s), the median fill
  is +0.4 dB in mean power (6 seeds, about 3 standard errors) and +0.2 dB in log power. In the
  attacker's own statistic it's +0.01 to +0.04. The cause is unknown. It doesn't show up as a mark
  so far, but nobody has checked whether a power-based attacker would see it.

### Leaks or holes: is there a stop that avoids both? (partly answered: the rank stop)
- **Answered, on the tuning half:** with decoy fills (`--track-decoys 4` or `8`) the rank stop
  leaks 1–2 of 34, and on real backgrounds fires on the same 3 % as without them. What's left is
  the drawn targets and one pass left alone.
- **Holdout, scored once:** 4 leaks of 36 (default 7), 3 holes (default 0), mean u 0.50 (default
  0.70). It failed the rule written beforehand on holes, by one, so the default stays. Three of
  the four leaks and one hole are targets drawn beyond 0.95 or 0.05; the other two holes
  (N563FX_R21) are the cloak's and the corpus's wrong places disagreeing.
- Before decoys: the rank stop leaks 5 of 34 and, on real backgrounds, fires on
  3 % of copies with an effect of −0.011 ± 0.007 against the default's −0.026 ± 0.012. Its mean
  shift is what a uniform target gives by design. Not settled: one seed pair, a worn tuning half,
  and a bottom tail too small to compare (18 against 19 of 176). The holdout decides.
- The earlier reasoning, kept for context:
- **Known:** the default stop is biased in noise (it compares the sweeping true curve with its own
  flat tails). The bias works as extra removal: it fires on 30 % of real backgrounds where nothing
  passed and leaves a hole (−0.029 ± 0.012), but on the corpus it leaks least of the fair-ish
  options. Fair comparisons (`--track-null wrongPlaces`, `library`) fix the hole (−0.005 ± 0.009)
  and leak more (13 and 17 of 34 against 12). Removing deeper leaks least (8) and fires more.
- **Why:** leaks and holes both come from how much is removed along the true curve, and a real
  pass's faint lines are about as strong as chance matches along it. A per-pass stop moves along
  one line between the two.
- **Would settle it:** removal that isn't specific to the truth. Remove along the true curve deeply,
  and along a few wrong places' curves with the same rule, so the most-cleaned place isn't the true
  one. Check that `lab blank` shows no hole and the corpus leaks no more than "deeper" (8 of 34).

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
