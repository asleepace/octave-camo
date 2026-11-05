# lab

Tools for the experiments in [EXPERIMENTS.md](../EXPERIMENTS.md): a corpus of recorder sessions
with their ADS-B ground truth, the detectors as composable pieces, and one command per experiment.
Python 3 with numpy, scipy, soundfile and matplotlib. Run from the repo root:

```sh
python3 -m lab ingest ~/Downloads/20261104T174102Z_efb8f8.zip   # unpack + index a recorder session
python3 -m lab sessions                                          # sessions and their nearest passes
python3 -m lab e2 all                                            # E2 detector + shape test: synthetic and real
python3 -m lab e2 real --wide                                    # the same up to 8 kHz
python3 -m lab attack <session> full.m4a experimental.m4a        # the known-path attacker, before/after
python3 -m lab plot <session>                                    # spectrogram + ADS-B Doppler curves
```

- **Privacy.** Sessions carry a precise location. They live in `$LAB_DATA` (default
  `~/.octave-camo-lab`), never in the repo or CI. `index.json` keeps only relative quantities
  (closest distance, when a plane is heard, speed, climb), no coordinates; printed tables and saved
  results come from it.
- **Ground truth for free.** `ingest` turns each session's aircraft polls into passes: for every
  airborne aircraft, its closest slant distance, when its sound arrives (sound travel time
  included, speed of sound from the session's temperature), and its predicted Doppler factor over
  the audio (`passes.npz`). A new recording is labelled data as soon as it's ingested.
- **Speed.** The path search runs all windows of a clip at once; whitened spectrograms are cached
  on disk by scene and parameters; scenes run on both cores. Results are saved as JSON in
  `$LAB_DATA/results` and printed as markdown tables ready for EXPERIMENTS.md.
- **Pieces** (`lab/detect.py`): `whiten` (clip-median or running-median reference, optional
  broadband-aware statistic), `search` (smooth falling or any-direction paths), `shape_test`
  (straight-flyby fit), `known_path` (the attacker with the track, searching the unknown rest
  frequency). Synthetic scenes are in `lab/synth.py`.
