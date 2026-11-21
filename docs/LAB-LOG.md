# Lab log

What the lab measured, newest first: findings, holdouts and the rules they were scored by. Moved
out of [CHANGELOG.md](../CHANGELOG.md) (#21), which now lists what changed in the page, the CLI and
the engine. The short version is [FINDINGS.md](FINDINGS.md); the full tables are in
[EXPERIMENTS.md](EXPERIMENTS.md).

Older findings, from before the split, are still in the CHANGELOG entries they shipped with.

## The two-window cloak holds on our recordings; the new holdout's rule (finding)

- **Session calibration (#14):** joint-draw p from the place search is calibrated on plane-free
  noise. Three judges qualify (whole-clip median at 0.17, 0.34 and 0.68 s, one line). Any of the
  three gives a false place on 14 ± 6 % of noise clips.
- **Both cloaks hide the place on our sessions.** The judges find 4 of 18 untouched sessions and
  none of their copies, default or `--track-windows 0.17,0.68` (two seeds).
- **w68 passes the session and real-background checks** written beforehand (#29). +0.08 ± 0.03 dB
  over the default on sessions.
- **The #16 holdout rule:** w68 against the default, on non-inferiority. It's scored once at 20
  held-out sessions with a scorable aircraft.
- **Recording target (#15):** about 45 new recordings. The session, not the pass, is the unit.
- docs/EXPERIMENTS.md, "The two-window cloak on our sessions" and "The new holdout"; lab/DATA.md.

## Testing at 0.68 s too halves the leak to held-back attackers (finding)

- Why the finer-resolution attacker wins: the cloak removes a plane's strongest lines, but narrower,
  weaker ones it leaves gain more from finer bins than the background does. At 0.17 s the truth sits
  at the wrong curves' median; at 0.68 s it's 1.1–3.2 SDs above.
- `--track-windows 0.17,0.68`, scored by the rule written beforehand on the corpus tuning half: the
  deciding attackers (0.34 s and 1.36 s frames, held back from the cloak) go from 16 and 17 leaks of
  34 to 6 and 8. Every attacker with power loses leaks. +0.36 ± 0.09 dB sound change.
- Not the default yet: sessions and a new holdout first.
- New panel attackers PM0 and PXL0.
- docs/EXPERIMENTS.md, "The default testing at 0.68 s too"; issue #29.

## A finer-resolution attacker; the whole-clip reference fails (finding)

- The lab's attacker panel (`lab/zenodo.py` `ATTACKERS`, `panel()`): P, T, P0, PL0 (0.68 s frames)
  and PF (no per-bin reference).
- On the corpus tuning half, PL0 catches 18 of 34 default copies, against the old scorer's 12. PF
  has no power (1 of 17 untouched).
- `--track-reference S` (experimental, #28): the cloak's own whitening reference.
- Scored by the rule written beforehand, a whole-clip reference (`0`) made the default leak more to
  every presence attacker (PL0 26 of 34) and fill less (−0.09 dB). The default keeps 15 s.
- docs/EXPERIMENTS.md, "The default's line finder with a whole-clip reference"; issue #29.

## The rank stop's advantage is the attacker's (finding)

- The presence score P has two weaknesses:
  - its 15 s running-median whitening leaves a shadow beside a slow line and absorbs a loud one;
  - its four-line sum lets a similar wrong curve count one loud line twice.
- On the corpus tuning half, the rank stop with decoys leaks 1 of 34 copies to P but 7–10 to
  whole-clip-median attackers, level with the default (10). The rank stop optimises against P, and
  only P had scored it.
- The whole-clip-median attacker catches 16 of 17 untouched passes, against P's 14.
- docs/EXPERIMENTS.md, "Attackers the cloak doesn't model"; issue #27.

## Holes give nothing away; a second attacker does (finding)

- Corpus tuning half, 17 passes × seeds 7 and 8: a hole (the truth in the presence score's bottom
  5 %) gives an attacker nothing.
  - Under the rank stop the truth's rank is spread like chance.
  - A deficit attacker and an either-score attacker rank the hole copies' truth low.
- The deficit score T reads the shadow whitening leaves beside a line. *Corrected in review:* T is
  shape-biased (it favours 5 of 17 shapes on plane-free noise). On the shapes where it's
  calibrated, it catches lines the presence score misses on only 2 and 1 of 24 copies, about
  chance. Against the best of P and T, the rank stop leaks 4 of 34, against the default's 12,
  but see the finding above: against attackers it doesn't model, the two are level.
- docs/EXPERIMENTS.md, "Do holes help an attacker?"; THREAT_MODEL.md, Known gaps 13; issues #13 and
  #27.

## Scores survive the export (finding)

- `lab/codec.py` re-encodes as the page's export (mono AAC, 160 kbps) and then a platform-like
  AAC 128k, AAC 64k or Opus 96k.
- On the corpus tuning half, untouched passes leak 14 of 17 after every chain, so a codec is no
  defence.
- The default stop and the rank stop with decoys keep their leaks and holes to within 2 of 34.
  docs/EXPERIMENTS.md, "After the export".
- `lab blank --codec page,aac64,…` scores each copy and its blind control through the same chain.
  On real backgrounds (91 placements), the cloak's mark is unchanged by every chain: the default
  −0.016 to −0.024 (raw −0.026), the rank stop about −0.011.
- `lab blank` gives one shape per session (all of a session's placements share it); the docs said
  one per placement. The behaviour is now explicit and unchanged.

## Holdout: the default stays (finding)

- The rank stop with 8 decoys, scored once on the corpus's held-out half against the rule written
  beforehand: 4 leaks of 36 against the default's 7, sound change +0.47 dB, but 3 holes against 0,
  one more than the rule allowed. The default stays; the rank stop and decoys stay experimental.
  Its u is spread like chance (mean 0.50), the default's sits high (0.70). docs/EXPERIMENTS.md,
  "The holdout for the rank stop with decoys".

## Deep filling leaves a trace (finding)

- With no plane present, filling 40 strips along a curve raises the attacker's rank (+0.18 on white
  noise, +0.48 over steady tones): independently drawn fill cells are spikier than real noise to the
  attacker. Light filling is unaffected. docs/EXPERIMENTS.md, "Deep filling leaves a trace of its own".
- **`--track-fill-level shift`**, experimental: copies the same bins from another moment of the
  recording. It clears the steady-tones case but not white noise.
- The rank stop's summary now says why it stopped short ("out of fills", "out of lines").
