# Status

_Updated 2026-11-20. Start here when checking in. Rules for working on the project are in
[CLAUDE.md](CLAUDE.md), and the backlog is in the
[issues](https://github.com/asleepace/octave-camo/issues)._

## Where it is

- **Shipped:** 0.1.1. The page ([asleepace.github.io/octave-camo](https://asleepace.github.io/octave-camo/))
  and the CLI cloak a clip offline, in the browser, with Swift compiled to wasm.
- **The leak it targets:** aircraft Doppler curves in a video's sound. On the public corpus
  (Pathak 2026), 14 of 17 untouched tuning passes give the true flight away (u ≥ 0.95).
- **The default cloak** (the Full preset): on the corpus's held-out half, 7 leaks of 36 copies,
  0 holes. Where nothing passed, it leaves a small mark: it fills on 27 % of real
  backgrounds, with an effect of −0.026 ± 0.012.
- **The rank stop with 8 decoys** (experimental): 4 leaks of 36, but 3 holes. That is one hole more
  than the rule written before the holdout allowed, so it didn't replace the default. It costs
  +0.47 dB more sound change.
- **Holes give nothing away** (#13, tuning half). Under the rank stop the truth's rank is spread
  like chance, and attackers looking for a missing line rank the hole copies low. That was the only
  thing against the rank stop.
- **The rank stop's advantage is an artefact of the attacker it's scored by** (#27, tuning half).
  It optimises against the presence score P, and only P has scored it, the holdout included.
  Against attackers it doesn't model, it's level with the default: a whole-clip-median attacker
  catches 7–10 of 34 copies of each. That attacker is also stronger than P on untouched audio (16
  of 17 against 14).
- **The cloak leaks more than every earlier table said.** A finer-resolution attacker (PL0, 0.68 s
  frames) catches 18 of 34 default copies on the tuning half, against 12 for the old scorer (#29).
  Giving the cloak's line finder a whole-clip reference made it worse (26 of 34).
- **A fix that works, on the tuning half:** letting the cloak's stopping test look at 0.68 s as
  well as 0.17 s (`--track-windows 0.17,0.68`) roughly halves its leak to the attackers held back
  to judge it: 16–17 to 6–8 of 34 copies. It costs +0.36 dB of sound change. It isn't the default
  yet; sessions and the new holdout come first (#29).
- **Reviewed 2026-11-20:**
  - Every figure was recounted from the raw results, the default's output was regenerated
    byte-for-byte, and the panel was calibrated on plane-free noise.
  - The new judges are calibrated, and the #27 and #29 decisions stand.
  - The deficit attacker T is shape-biased, so #13's "T catches lines P misses" is withdrawn.
    "Holes give nothing away" stands.
  - Four small figures were corrected.
- **Posting doesn't change any of this.** The page's AAC export, followed by AAC 128k, AAC 64k or
  Opus 96k, leaves leaks, holes and the mark on real backgrounds where they were.
- **Data:** 23 recorder sessions (21 tuning, 2 holdout). The public corpus has 35 passes; its
  holdout half is **spent**. The tuning half is worn.

## In flight

Nothing is running. Colin is collecting new recordings. New sessions are split into tuning and
holdout automatically as they're ingested ([lab/DATA.md](lab/DATA.md)).

## Decisions waiting on Colin

- [#25](https://github.com/asleepace/octave-camo/issues/25) **Where the session zips live.** They're
  the only lab data that can't be rebuilt, and they exist only in one workspace that can be wiped.
  Recommended: your bucket, with its host allowed in the environment's network settings.
- [#26](https://github.com/asleepace/octave-camo/issues/26) **`lab blank` shapes.** Recommended:
  keep one shape per session, as it is now.

## Next, by impact

1. [#29](https://github.com/asleepace/octave-camo/issues/29) **Check the two-window cloak on real
   recordings.**
   - Real backgrounds (`lab blank`) and the tuning sessions, scored by the attacker panel. An
     earlier extra window made one session's place easier.
   - If it holds, it's the candidate for the new holdout.
2. [#15](https://github.com/asleepace/octave-camo/issues/15) **A recording target:** how many
   sessions the next held-out decision needs. The rough figure is 100–300 held-out passes.
3. [#14](https://github.com/asleepace/octave-camo/issues/14) **Re-score the place search on our
   sessions** against the stronger attacker, with calibrated p-values. This matters for the docs'
   credibility.
4. [#16](https://github.com/asleepace/octave-camo/issues/16) **The new holdout** (needs data):
   score against attackers the cloak doesn't model. Keep holes as a diagnostic, not a loss.
5. [#30](https://github.com/asleepace/octave-camo/issues/30) **Calibrate the corpus score per
   shape,** and gate new attackers on it.
6. Loudness normalisation
   ([#17](https://github.com/asleepace/octave-camo/issues/17)), the pink-noise hole against a blind
   control ([#19](https://github.com/asleepace/octave-camo/issues/19)), native encoders
   ([#18](https://github.com/asleepace/octave-camo/issues/18)).

**Custodial** (the weekly run picks these up, one PR each): a findings summary
([#20](https://github.com/asleepace/octave-camo/issues/20)), the CHANGELOG
([#21](https://github.com/asleepace/octave-camo/issues/21)), PLAN.md
([#22](https://github.com/asleepace/octave-camo/issues/22)), resumable runs
([#23](https://github.com/asleepace/octave-camo/issues/23)), `lab fetch-corpus`
([#24](https://github.com/asleepace/octave-camo/issues/24)).

## Check-in loop

1. **Read this page**, answer any `decision` issues, and review the week's PR.
2. **New recordings:** attach the zips (or put them wherever #25 decides) and say "ingest these".
3. **Pick the next science item,** or let the list above decide.
