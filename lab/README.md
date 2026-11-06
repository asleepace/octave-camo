# lab

Tools for the experiments in [EXPERIMENTS.md](../docs/EXPERIMENTS.md): a corpus of recorder sessions
with their ADS-B ground truth, the detectors as composable pieces, and one command per experiment.
Python 3 with numpy, scipy, soundfile and matplotlib. Run from the repo root:

```sh
python3 -m lab ingest ~/Downloads/20261104T174102Z_efb8f8.zip   # unpack + index a recorder session
python3 -m lab backfill all                                      # fetch positions from before the first poll
python3 -m lab sessions                                          # sessions and their nearest passes
python3 -m lab e2 all                                            # E2 detector + shape test: synthetic and real
python3 -m lab e2 real --wide                                    # the same up to 8 kHz
python3 -m lab cloak <session> full experimental                 # cloak with the real wasm build
python3 -m lab check <session> full.wav experimental.wav          # the page's check (real wasm), before/after
python3 -m lab attack <session> full.wav experimental.wav        # the known-path attacker, before/after (z and dB)
python3 -m lab locate <session> full.wav experimental.wav         # the place-searching attacker (slow: ~5 min each)
python3 -m lab trackfill <session> full experimental             # flight-track removal (the CLI's --expect)
python3 -m lab trackfill <session> full --archive                 # the page's path: curves from adsb.lol's archive
python3 -m lab plot <session>                                    # spectrogram + ADS-B Doppler curves
python3 -m lab bench                                             # the curve benchmark (~45 min on 2 cores)
python3 -m lab ml data && python3 -m lab ml train && python3 -m lab ml report   # the learned detector (needs jax, optax)
python3 -m unittest discover -s lab/tests -t .                   # invariants (synthetic, no sessions; CI runs them)
```

`trackfill` needs the CLI: `swift build -c release --product octave-camo`.

- **Privacy.** Sessions carry a precise location. They live in `$LAB_DATA` (default
  `~/.octave-camo-lab`), never in the repo or CI. `index.json` keeps only relative quantities
  (closest distance, when a plane is heard, speed, climb), no coordinates; printed tables and saved
  results come from it.
- **Ground truth for free.** `ingest` turns each session's aircraft polls into passes: for every
  airborne aircraft, its closest slant distance, when its sound arrives (sound travel time
  included, speed of sound from the session's temperature), and its predicted Doppler factor over
  the audio (`passes.npz`). A new recording is labelled data as soon as it's ingested.
- **Backfill.** A recording started in a hurry has no pre-roll, so planes heard early have no
  positions from before the first poll. `backfill` fetches them from adsb.lol for every aircraft
  the session's polls saw within 40 km: today's full-resolution traces for a session from today
  (UTC), else the 10 s archive. Downloads are cached in `$LAB_DATA/adsb`; the extra positions sit
  beside the session (`adsb_backfill.jsonl`) and are merged into its index. `label` fixes a
  session's context labels locally. The archive also holds rows that aren't positions; rows
  outside ±90°/±180° or 60,000 ft are dropped when fetched and when indexed.
- **Speed.** The path search runs all windows of a clip at once; whitened spectrograms are cached
  on disk by scene, parameters and the audio's own bytes (a re-cloaked file keeps its name);
  scenes run on both cores (the cache only grows: delete `$LAB_DATA/cache` any time). Results are saved as JSON in `$LAB_DATA/results` and printed as
  markdown tables ready for the notebook.
- **The place search** (`lab/locate.py`, after the video in [SOURCES.md](../docs/SOURCES.md)): every point of a grid
  around the true position gets each aircraft's predicted Doppler curve from its real track,
  scored against the audio with the rest frequency free and against the same curve at wrong
  times; the aircraft are summed on one timeline. It reports the true point's rank, how far the
  best guess is, and the area scoring near the best: distances only, never positions.
- **The curve benchmark** (`lab/passes.py`, `lab/bench.py`): synthetic passes with what makes real
  ones messy, in real and synthetic backgrounds; every detector scored by strength and false
  alarms per hour. Per-clip results are cached in `$LAB_DATA/results/bench*.jsonl`, so a rerun only
  computes new clips.
- **The learned detector** (`lab/ml.py`): log-frequency features, a small dilated CNN in JAX, the
  path search and flyby fit on its output. Training backgrounds and test backgrounds are split by
  session; the real passes are test only. Its data and weights live in `$LAB_DATA/ml`.
- **Pieces** (`lab/detect.py`): `whiten` (clip-median or running-median reference, optional
  broadband-aware statistic), `search` (smooth falling or any-direction paths), `shape_test`
  (straight-flyby fit), `known_path` (the attacker with the track, searching the unknown rest
  frequency). Synthetic scenes are in `lab/synth.py`; the spectrogram cache, aligning a cloaked
  copy with its original and saving results are in `lab/common.py`.
