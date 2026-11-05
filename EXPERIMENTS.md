# Experiments

A lab notebook for the check (the attacker model the page counts with): what we measured, what it
means, and what to try next. The detector's design is in [ACOUSTICS.md](ACOUSTICS.md), the order
of work in [PLAN.md](PLAN.md). Real recordings are described here only by what they contain; they
never go into the repo.

## The problem

A jet's fan tone on a real indoor phone recording (a climbing airliner about 3 km away, heard
through a closed room) swept from 1.75 to 1.0 kHz in about 25 s, up to ~55 Hz/s. A flyby fit from
the sound alone put its closest approach in the same second as the ADS-B track. The check didn't
see it: modelled, it follows a sweep like this only up to ~1.15 kHz even at 30–40 dB, and only
below 1 kHz at 20 dB. So the page could say "nothing left" with a Doppler clue in the file, and the
`lines` stage, which removes what the check finds, couldn't touch it.

## First principles

- **Coherent gain.** A steady tone gains 3 dB every time the window doubles: its energy piles into
  one bin while noise spreads.
- **Smear.** A tone sweeping s Hz/s moves s·T Hz within a window of length T; a bin is 1/T wide.
  Once s·T > 1/T the tone smears over s·T² bins and the per-bin level falls instead. The best
  plain window is T* ≈ 1/√s: 0.16 s at 40 Hz/s. The check's 1 s window is far past that.
- **Dechirping** (multiplying the frame by the conjugate chirp before the FFT, radio SETI's
  "de-Doppler") would recover the full long-window gain for a tone that stays coherent.
- **Incoherent integration.** Summing energy along a path over n frames raises a detection
  statistic by about 5·log₁₀(n) dB without needing phase coherence (radar's track-before-detect).
- **Per-frame thresholds can't see faint moving tones.** The high band needs 15 dB in one frame.

## E0 — window length, plain and dechirped (done)

Visibility of the tone along its (fitted) path: power on the path's bin over the median of bins
40–150 Hz away, median over 60–82 s. Script: scratch `e0_window.py`.

| window | modelled tone (20 dB/Hz), plain | dechirped | real recording, plain | dechirped |
| ---: | ---: | ---: | ---: | ---: |
| 0.064 s | 7.4 | 7.4 | 5.7 | 5.6 |
| 0.128 s | 9.9 | 9.9 | 6.9 | 6.9 |
| 0.256 s | 12.2 | 12.5 | **8.1** | 7.8 |
| 0.512 s | 12.7 | 15.4 | 6.9 | 7.6 |
| 1.024 s | 11.1 | 18.7 | 5.8 | 7.9 |
| 2.048 s | 9.3 | 21.3 | 6.8 | 9.4 |

The model behaves as the theory says: plain peaks near 0.25–0.5 s, dechirped keeps gaining ~3 dB
per doubling. **The real tone doesn't:** dechirping barely helps, and the best plain window is
0.25 s. The real tone isn't coherent over long windows (turbulence, reflections in the room, the
engine's own wobble), so long coherent windows can't add it up. E3 measures that directly.

## E1 — integrating along the path (done)

Whitened STFT (each bin over its own median in time), log-power summed along the true path over
58–84 s, against the same path shifted ±15–45 s (the null). Script: scratch `e1_pathsum.py`.

| window | per-frame excess | path-sum z | null max z |
| ---: | ---: | ---: | ---: |
| 0.064 s | 6.0 dB | 7.1 | 1.1 |
| 0.128 s | 7.0 dB | **9.5** | 1.4 |
| 0.256 s | 7.9 dB | **9.5** | 1.3 |
| 0.512 s | 7.8 dB | 7.3 | 1.7 |
| 1.024 s | 6.9 dB | 5.5 | 1.8 |

- Per frame the tone is only 6–8 dB up at any window: a frame-by-frame detector with a 15 dB bar
  can't see it, however its window is tuned. It has to be integrated.
- Along its path it's unmistakable, best with 0.13–0.26 s windows.

## The zoom-out: the real attacker isn't blind

E1 *is* the attacker who has ADS-B: given the plane's track, this recording shows it at z 9.5. Our
check searches blind, so it will always be weaker than an attacker with candidate flights; even a
perfect blind check is only an upper bound on what's hidden. The honest bar is **"someone who
knows where the planes were can't find them"**, and we can measure exactly that: the recorder app
logs the real tracks with every session.

## Next experiments

1. **E2 — blind path search.** Short windows (~0.25 s), whitened, then a Viterbi search over paths
   whose slope is limited by physics. Does it find the fan tone with no flight data? How much z
   does searching cost against the known path (the look-elsewhere price)? False alarms on real
   recordings without planes (TV, construction, a fan, speech) and on synthetic noise, music and
   speech.
2. **E3 — coherence time.** How long a real tone stays in phase (indoors vs outdoors, near vs
   far): why dechirping failed indoors, and how much long windows can ever buy.
3. **E4 — the known-path attacker as the metric.** For every recorder session with ADS-B: score
   the original, Full and Experimental outputs against the real flight paths (path sum along each
   aircraft's predicted Doppler curve, with harmonics). The real security number; a CI benchmark
   built from synthetic scenes plus (outside the repo) the real sessions.
4. **E5 — harmonics.** Engines make families of tones (fan blade passing, shaft orders); summing
   their paths could add several dB, for the attacker and for us.
5. **E6 — a physics-shaped blind search.** The flyby curve search extended to 1–8 kHz: the
   strongest blind detector, and the most expensive. Its ceiling, for comparison.

## Where this is heading

Probably two detectors in the check: the existing long-window integrator for steady lines, and a
short-window path search for anything that moves. Removal (`lines`) follows whatever either finds.
Scored, in the end, against the known-path attacker.
