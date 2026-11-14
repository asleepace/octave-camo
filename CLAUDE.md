# Working on octave-camo

Rules for anyone (person or agent) working in this repo. The project is a research codebase: the
science moves in [docs/EXPERIMENTS.md](docs/EXPERIMENTS.md), and the open questions are in
[OPEN_QUESTIONS.md](OPEN_QUESTIONS.md).

## Every session

- **Start:** read [STATUS.md](STATUS.md), `git log --oneline -15`, and the open issues
  (`gh api repos/asleepace/octave-camo/issues`).
- **End:** update STATUS.md (numbers, what's in flight, decisions waiting, next steps), and leave
  everything committed and pushed.
- Colin (the maintainer) checks in periodically, often from his phone. STATUS.md and the issues are
  how he catches up, so keep them current and short.

## Privacy (hard rules)

- **No locations, ever.** Recorder sessions carry precise GPS. Nothing in the repo, docs, issues,
  PRs or commit messages may name, describe or let anyone reconstruct where a recording was made.
  Describe a recording's surroundings only as far as a result needs ("outdoors, road noise"), and
  never say what a place is or whose it is.
- **Aggregates only.** Print and publish distances, ranks, counts and scores, never coordinates or
  per-session positions. `index.json` keeps only relative quantities; keep it that way.
- **Never commit media or session-derived data:** clips, WAVs, spectrogram images of sessions,
  `$LAB_DATA` contents, results JSON. Plots can be sent to Colin privately, but never committed.
- **Real recordings never go to CI or GitHub runners.** CI uses synthetic scenes only.
- **The public corpus** (Pathak 2026, CC BY 4.0, Zenodo record 23424278, in
  `$LAB_DATA/external/zenodo-23424278`): use the curve shapes only, never reconstruct the recorder's
  position, and cite it.
- **Don't get around network blocks.** If the proxy refuses a host, say so and stop; don't retry it
  through another tool.

## Science discipline

- **Holdouts are spent once.** The corpus's holdout half has been scored and is spent. Session
  holdouts are chosen by `lab.corpus.is_holdout`: never use them to pick a threshold, parameter or
  stopping rule. Write the decision rule in EXPERIMENTS.md, commit it, and only then score the
  holdout, once.
- **Compare against a blind control, not "before".** Regression to the mean has misled us twice
  (OPEN_QUESTIONS.md, "Pitfalls"). Pair by copy and seed.
- **At least two seeds** for any comparison. One pass's u under two seeds correlates only 0.3–0.8.
- **Report ± se and the n.** Say what isn't settled.
- **The tuning half is worn.** Its numbers are optimistic; prefer new data for any new decision.

## Environment

- Swift: `export PATH=/opt/swift/swift-6.4.2-RELEASE-ubuntu24.04/usr/bin:$PATH`. The lab drives the
  release CLI (`swift build -c release --product octave-camo`).
- 2 CPUs, a fixed disk allowance, and background jobs capped at 2 h. Workers killed mid-run leave
  `/tmp/tmp*` directories behind: delete them.
- **Long runs must be resumable:** append one JSON line per job, keyed by a unique per-job index,
  and skip keys already written. (A key shared by several jobs once made a resume skip work.)
- The full Swift debug suite doesn't finish locally within 2 h. Rely on CI for it, and run the
  targeted tests and the lab tests locally.
- `$LAB_DATA` (default `~/.octave-camo-lab`) is local to one workspace and can disappear. How to
  rebuild it is in [lab/DATA.md](lab/DATA.md).

## Process

- **Code changes go through a PR.** CI runs on pull requests (about 25 min). Fast-forward main once
  it's green. Lab-only and docs-only changes may go straight to main.
- Run CI only for PRs and big changes, not on every push.
- Don't delete branches.
- `gh`'s GraphQL is blocked here. Use REST: `gh api repos/asleepace/octave-camo/...`, e.g.
  `commits/<sha>/check-runs` for CI status.
- Commits and PR bodies end with the attribution lines the session provides.
- Tests: see [CONTRIBUTING.md](CONTRIBUTING.md). Add a test that fails without your change.

## Backlog

GitHub issues, labelled:

- `science`: an experiment or a question;
- `custodial`: code, tests, docs and organisation, with no real data needed;
- `needs-data`: blocked on new recordings;
- `decision`: waiting on Colin.

The weekly scheduled run takes one open `custodial` issue with no open PR, does it, and opens a PR.
It never merges, never touches `$LAB_DATA`, and comments on the issue with what it did.

## Writing

- Plain language, short sentences, numbers with their uncertainty.
- New sources go in [docs/SOURCES.md](docs/SOURCES.md).
- Each finding gets a CHANGELOG entry under its milestone.
