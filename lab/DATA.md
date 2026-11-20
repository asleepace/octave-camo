# Lab data: intake, rebuild and what to record

The lab's data lives in `$LAB_DATA` (default `~/.octave-camo-lab`), never in the repo. A cloud
workspace's copy can be wiped after a long idle, so everything here can be rebuilt from two
sources: the recorder's session zips, and public downloads.

## What's in `$LAB_DATA`

| Path | What | If lost |
| --- | --- | --- |
| `sessions/` | ingested recorder sessions (audio, polls, `index.json`) | **Rebuild from the session zips only.** Keep the zips. |
| `adsb/` | adsb.lol downloads for `backfill` | `python3 -m lab backfill all` |
| `external/zenodo-23424278/` | the public corpus (Pathak 2026, CC BY 4.0) | Download it again (below) |
| `ml/` | the learned detector's data and weights | `python3 -m lab ml data && python3 -m lab ml train` (hours) |
| `cache/`, `cloaked/` | spectrogram and cloak caches | Rebuilt on demand; delete any time |
| `results/`, `plots/` | raw results and plots | Rerun the experiment. The tables are in docs/EXPERIMENTS.md |

The session zips are the only thing that can't be downloaded again. Store them somewhere private
that the workspace can reach (see "Storage").

## Rebuild

```sh
export LAB_DATA=~/.octave-camo-lab
for z in /path/to/zips/*.zip; do python3 -m lab ingest "$z"; done   # each prints (tuning) or (holdout)
python3 -m lab backfill all
python3 -m lab sessions                                              # check: every session listed
```

The public corpus: `files.tsv` in the record lists each file's URL and md5. Download them into
`$LAB_DATA/external/zenodo-23424278/raw/`, check the md5s, and unzip each into `extracted/`. The
record is https://zenodo.org/records/23424278.

The holdout is decided by the session id (`lab.corpus.is_holdout`), so a rebuild gives the same
split.

## Intake: new recordings

1. **Ingest every new zip** as above. Sessions recorded from 2026-11-15 (UTC) on are split as they
   arrive: half go to the holdout, by a hash of the id. Nobody chooses, and nothing about the
   recording is looked at first. The two older holdout sessions stay held out.
2. **Backfill** (`lab backfill all`), then `lab sessions` to see that they're indexed.
3. **Use only the tuning half** for anything that picks a threshold, parameter or rule. Scoring
   commands refuse holdout sessions unless `--holdout` is given.
4. **Before scoring the holdout, write the decision rule** in docs/EXPERIMENTS.md (what's compared,
   which numbers decide, what counts as a pass), and commit it. Then score once and report the
   result whichever way it goes.
5. Update STATUS.md: sessions added, tuning/holdout counts.

## How much data a decision needs

**Target: about 45 new recordings like the current ones.** That's about 23 held out, and about 20
of those with a scorable aircraft, which is what the #16 rule needs (docs/EXPERIMENTS.md, "The new
holdout"). Half of new recordings go to tuning, which is useful too.

How that was worked out (issue #15, from the 21 tuning sessions, 2026-11-20):

- **The unit is the session, not the pass.** The place search scores a session's aircraft
  together. Per aircraft, originals don't stand out: 2–3 of 45 scorable aircraft clear the noise's
  95th percentile, about what chance gives. So the corpus's figure of 100–300 passes doesn't carry
  over.
- **Sessions with a scorable aircraft:** 18 of 21 (86 %), with 2.1 aircraft each.
- **Sessions that count** (the original found by any of the three judges): 4 of 18 (22 %). Both
  cloaks hide all 4, so on sessions the decision is non-inferiority (no worse), not superiority.
- **Power for the #16 rule:**
  - "No lean toward the truth": per-session sd of a cloak's excess bits is 0.6–1.2. It catches a
    lean the size of an untouched original's at 80 % with 6–13 sessions under PL0/1 and PM0/1.
  - "No more leaks": copies leak at 0–3 %, and the cloaks differ on 1 session in 18, so a margin
    of 2 copies trips by chance about 1 % of the time at 20 sessions.
- **The security claim** (copies hidden where the original was found) needs about 5 counting
  sessions to reach p < 0.05 with a sign test (all 5 hidden: p 0.03). At 22 % that's about 23
  held-out sessions. Beating the blind control too would take several times more, depending on how
  often the blind preset already hides them (not measured on sessions yet).

The corpus figure was a different question: telling a leak rate of about 11 % from 19 % over its
passes needed 100–300 held-out passes.

## What to record

The most useful sessions, for the decisions that are open:

- **Clear passes.** Planes you can hear rise and fall over 20 s or more, near and far. A
  recording whose original gives the place away is what the cloak gets tested on.
- **Plane-free stretches,** to test the cloak's own mark where nothing passed (`lab blank`).
- **Variety:**
  - times of day and traffic;
  - window open and closed, indoors and out;
  - wind, voices, music, road noise;
  - jets, propeller planes and helicopters.
- **Start recording before the plane is audible,** so its track has a pre-roll. `backfill` covers
  gaps, but polls during the recording are better.
- **Several places help,** if you're comfortable: the data never leaves the lab, and results are
  published as aggregates only.

## Storage

Today the zips reach a workspace by being attached to a session. The workspace's network allows
GitHub, the package registries, zenodo.org and adsb.lol; a DigitalOcean Spaces bucket was refused.
Options:

- a bucket whose host is added to the environment's allowed domains, with `lab backup` /
  `lab restore` reading credentials from the environment;
- a private GitHub repository with the zips as release assets.

Whichever is chosen, the zips carry precise locations: keep them private.
