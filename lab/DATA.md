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

On the public corpus's holdout, the rank stop with 8 decoys leaked 4 of 36 against the default's 7.
To tell leak rates that close apart (about 11 % against 19 %) at 80 % power, a paired test needs
roughly 100–300 held-out passes. It's nearer 300 if the two cloaks fail on unrelated passes, and
fewer if they fail on the same hard ones. Each session has several passes, but only the ones whose
original gives the place away count. Working out passes per session from the tuning half turns
this into a session target; that's the first job once new data arrives.

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
