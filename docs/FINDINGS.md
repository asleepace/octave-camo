# Findings

The settled results, most important first. Each is a claim, its key number and a link to the
notebook section with the full table. The notebook, [EXPERIMENTS.md](EXPERIMENTS.md), is the
complete record; this page is for catching up. What isn't settled is in
[OPEN_QUESTIONS.md](../OPEN_QUESTIONS.md).

Terms used below:

- **u:** where the truth ranks among wrong answers (0 to 1; 0.5 is chance). A **leak** is u ≥ 0.95,
  a **hole** u ≤ 0.05.
- **The corpus:** Pathak 2026 (Zenodo 23424278, CC BY 4.0), 35 usable passes, split into a tuning
  half (17) and a held-out half (18). The held-out half is spent. The tuning half is worn, so its
  numbers are optimistic.
- **Copies:** cloaked outputs, usually 17 passes × 2 seeds = 34.
- **Attackers:** P is the old scoring attacker (0.17 s frames, a 15 s running-median reference, four
  lines). P0, PM0, PL0 and PXL0 use the whole clip's median instead, at 0.17, 0.34, 0.68 and 1.36 s
  frames. T reads P's deficits. "/1" means one line instead of four (P01 and T0 in older tables:
  P0 with one line, and P0's deficits).

## 1. The leak is real, and a codec doesn't remove it

Untouched, 14 of 17 corpus tuning passes give the true flight away to P (u ≥ 0.95), and 16 of 17 to
P0 or PL0. On the held-out half, 12 of 18. After the page's AAC export and a platform-like
re-encode (AAC 128k, AAC 64k or Opus 96k) it's still 14 of 17, with Δu within ±0.015.

Notebook: [After the export](EXPERIMENTS.md#after-the-export-do-the-scores-survive-a-codec),
[Attackers the cloak doesn't model](EXPERIMENTS.md#attackers-the-cloak-doesnt-model-issue-27).

## 2. The default cloak leaks more than the early tables said

The finer-resolution attacker PL0 (0.68 s frames) catches 18 of 34 default copies on the tuning
half, against 12 for P. Every leak count before it understated the default's leak to a capable
attacker by about half again. On the held-out half, scored by P, the default leaked 7 of 36 copies
with 0 holes.

Notebook: [The default's line finder with a whole-clip
reference](EXPERIMENTS.md#the-defaults-line-finder-with-a-whole-clip-reference-plan-written-before-it-ran),
[The holdout for the rank stop](EXPERIMENTS.md#the-holdout-for-the-rank-stop-with-decoys-plan-written-before-it-ran).

## 3. Testing at 0.68 s too halves that leak (tuning half)

`--track-windows 0.17,0.68` lets the cloak's stopping test see the weak, narrow lines it used to
leave. Against the attackers held back to judge it, leaks of 34 fall from 17 to 8 (PXL0) and 16 to
6 (PM0). No attacker with power gains leaks. By pass: PM0 7 better and none worse (sign test
p = 0.016), PXL0 6 and none (p = 0.031). It costs +0.36 ± 0.09 dB of sound change. It holds on our
sessions and real backgrounds (finding 4). It isn't the default yet: it becomes the default if a
new holdout of sessions, scored once by a committed rule, shows it's no worse.

Notebook: [The default testing at 0.68 s
too](EXPERIMENTS.md#the-default-testing-at-068-s-too-plan-written-before-it-ran).

## 4. On our recordings, both cloaks hide the place, and 0.68 s too is no worse

Three calibrated judges (P0/1, PM0/1, PL0/1) give the place away on 4 of 18 untouched tuning
sessions. Of those 4 sessions' 8 copies, they find none under the default and none under
`--track-windows 0.17,0.68` (two seeds). Overall, 0 of 36 and 1 of 36 copies are found, below the
14 % chance rate on noise. On real backgrounds, the two-window cloak puts fewer copies in the top
5 % than the default (11 against 13 under PM0, 1 against 3 under PXL0). It costs +0.08 ± 0.03 dB
over the default on sessions. Without the track step, the preset alone hides the faint passes too,
but not every clear one: one of three sessions with a clear original keeps its lead. Both cloaks
push the truth slightly *below* chance on sessions; whether an attacker can use that is open.

Notebook: [The two-window cloak on our
sessions](EXPERIMENTS.md#the-two-window-cloak-on-our-sessions-plan-written-before-it-ran),
[The new holdout](EXPERIMENTS.md#the-new-holdout-w68-against-the-default-on-held-out-sessions-rule-written-before-it-ran).

## 5. The rank stop's advantage belongs to the attacker it optimises against

The rank stop with 8 decoys leaks 1 of 34 to P, against the default's 12. Against attackers it
doesn't model it's level with the default: P0 7 against 10, P01 10 against 10, T0 6 against 4, mean
u within ±0.03. A cloak that models an attacker has to be scored by attackers it doesn't model. On
the held-out half (scored by P) it leaked 4 of 36 against 7, but with 3 holes against the rule's
limit of 2, and +0.47 dB, so the default stayed.

Notebook: [Attackers the cloak doesn't
model](EXPERIMENTS.md#attackers-the-cloak-doesnt-model-issue-27), [The holdout for the rank
stop](EXPERIMENTS.md#the-holdout-for-the-rank-stop-with-decoys-plan-written-before-it-ran).

## 6. Holes give nothing away

On the rank stop's three hole copies, an attacker looking for a missing line (T) ranks the truth
0.10, 0.08 and 0.42. The rank stop's P ranks are spread like chance (χ² 9.5 on 9 degrees of freedom;
KS 0.10 against a 5 % critical value of 0.23), so learning their shape gains nothing. Holes are now
a diagnostic, not a loss. (The earlier claim that T catches lines P misses was withdrawn: T is
shape-biased.)

Notebook: [Do holes help an attacker?](EXPERIMENTS.md#do-holes-help-an-attacker-plan-written-before-it-ran).

## 7. "The check sees nothing" is not "the tone is gone"

On the whole corpus, the engine's own blind check finds a flyby in 33 of 35 originals and in 1
after Full, yet the median z along the traced tone goes 3.7 → 4.0. Cleaning up the background can
make a faint surviving line stand out more. A cloak has to be judged by an attacker, not by its
own detector.

Notebook: [The public corpus: 35 held-out
passes](EXPERIMENTS.md#the-public-corpus-35-held-out-passes-tone-removal).

## 8. The default leaves a small mark where nothing passed

On real backgrounds (curves nothing follows, 88 scorable placements, two seeds), the default's
track step fills on 27 % of curves, with an effect of −0.026 ± 0.012 against the same preset blind
to the curve (−0.11 ± 0.06 where it fired). The cause is the stopping test's bias: in noise its z
averages about 1 where a fair test averages 0. A fair stop, in the same kind of run, fires on 14 % instead of 30 % and
shrinks the mark from −0.029 ± 0.012 to −0.005 ± 0.009. But it removes less along real passes and
costs leaks, so the default keeps the old stop. A codec neither hides the mark nor adds to it.

Notebook: [Real backgrounds](EXPERIMENTS.md#real-backgrounds-is-the-score-fair-and-does-the-cloak-leave-a-mark),
[A fair stopping test](EXPERIMENTS.md#a-fair-stopping-test),
[The cloak judges like the attacker](EXPERIMENTS.md#the-cloak-judges-like-the-attacker),
[Real backgrounds through a codec](EXPERIMENTS.md#real-backgrounds-through-a-codec).

## 9. The score is fair, if read against a blind control

On real plane-free audio, nothing cloaked, 1,547 scores give mean u 0.494 (four lines) with 6.1 %
in the top 5 %. But one shape's baseline alone ranges 0.33–0.59, so a set of placements' "before"
wanders, and comparing a cloak with its own "before" mostly measures regression to the mean.
Compare against the same preset blind to the curve, paired by copy and seed.

Notebook: [Real backgrounds](EXPERIMENTS.md#real-backgrounds-is-the-score-fair-and-does-the-cloak-leave-a-mark).

## 10. Most judges are calibrated; T isn't

On plane-free noise (68 clips each; about 3.4 leaks by chance), P0, PL0 and PM0 favour no shape,
and PXL0 one. T gives 13 leaks and favours 5 shapes; P favours 3. No decision changes without each
attacker's favoured shapes. On our sessions, P0/1, PM0/1 and PL0/1 pass calibration (p ≤ 0.05 on
4, 1 and 1 of 36 noise clips). A copy counted as leaked to any of the three has a chance rate of
14 ± 6 %.

Notebook: [Calibration of the attacker
panel](EXPERIMENTS.md#calibration-of-the-attacker-panel-review-2026-11-20), [The two-window cloak on
our sessions](EXPERIMENTS.md#the-two-window-cloak-on-our-sessions-plan-written-before-it-ran).

## 11. On our sessions, attackers have little power, and one line beats four

The best attacker gives the place away on 4 of 18 untouched tuning sessions (P0/1; binomial
p 0.011 against chance, about 1 of 18). Four-line attackers do worse than one-line ones there, the
reverse of the corpus: a session's aircraft are mostly far and faint. Session checks can catch a
change being clearly worse, not show it's better.

Notebook: [The two-window cloak on our
sessions](EXPERIMENTS.md#the-two-window-cloak-on-our-sessions-plan-written-before-it-ran).

## 12. Heavy filling writes its own trace, and decoys hide it

With no plane, 40 strips filled along a curve raise the truth's rank: +0.18 ± 0.07 on white noise,
+0.48 ± 0.03 over steady tones (12 seeds). Filled cells have a fatter upper tail than real noise.
Filling the same strips along 8 decoy curves drawn like the truth takes it to −0.10 ± 0.11 and
−0.07 ± 0.09: no longer measurable. Subtracting the line instead of filling did no better.

Notebook: [Deep filling leaves a trace of its
own](EXPERIMENTS.md#deep-filling-leaves-a-trace-of-its-own), [Subtracting the line
instead](EXPERIMENTS.md#subtracting-the-line-instead-a-negative-result),
[Decoys](EXPERIMENTS.md#decoys-the-same-fill-along-wrong-places-curves).

## 13. One seed is one draw

The same pass's u under two seeds correlates only 0.33–0.61 with one line and 0.60–0.82 with four.
Every comparison needs at least two seeds, and is read by pass as well as by copy.

Notebook: [What real engines
carry](EXPERIMENTS.md#what-real-engines-carry-and-an-attacker-that-adds-them-up).

## 14. A real pass is a few unrelated lines, not a tone and its harmonics

Along the corpus's traced curves, a pass carries a median of two separate lines at z ≥ 4 (none to
six), mostly not harmonics of the strongest and about as strong (0.3–2.4 times its excess). That's
why attackers add up four lines, and why the cloak's ×2 and ×3 fill is off by default.

Notebook: [What real engines
carry](EXPERIMENTS.md#what-real-engines-carry-and-an-attacker-that-adds-them-up).

## 15. How the check finds a moving tone

A real fan tone isn't coherent over long windows, so dechirping barely helps. It's only 6–8 dB up
in any one frame, but unmistakable summed along its path (z 9.5 at 0.13–0.26 s windows). A blind
search for smooth, falling paths plus a flyby shape test finds it, at a price of about 4 dB against
knowing the path. That search ships in the check.

Notebook: [E0](EXPERIMENTS.md#e0--window-length-plain-and-dechirped-done),
[E1](EXPERIMENTS.md#e1--integrating-along-the-path-done),
[E2, round two](EXPERIMENTS.md#e2-round-two--broadband-awareness-sensitivity-and-the-shape-test-done),
[E2 in the check](EXPERIMENTS.md#e2-in-the-check--the-path-search-ships-done).
