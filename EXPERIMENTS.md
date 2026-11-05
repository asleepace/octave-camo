# Experiments

A lab notebook for the check (the attacker model the page counts with): what we measured, what it
means, and what to try next. The detector's design is in [ACOUSTICS.md](ACOUSTICS.md), the order
of work in [PLAN.md](PLAN.md), related work in [RESEARCH.md](RESEARCH.md). Real recordings are described here only by what they contain; they
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

## E2 — blind path search (done, first pass)

No flight data. 0.17 s windows, hop 43 ms; each bin whitened; in every 10 s window (every 2.5 s) a
Viterbi search for the best path through the 0.6–2.5 kHz band; scored as z against white noise
through the same pipeline. Scripts: scratch `e2_viterbi.py`, `e2b_falling.py`, `e2c_smooth.py`.
Run on all six recorder sessions (quiet bedrooms, a departure heard indoors, TV with construction
outside, and the bathroom pass).

1. **Any path, whitened against each bin's median over the clip (E2a).** It finds the fan tone
   blind and traces it to within 5–17 Hz of the true curve from 60 to 83 s (z 35–49). But real
   rooms aren't white noise: windows with no plane score z 20–40, a TV clip has a median of 25,
   and a steady 1,008 Hz room line scores 60. Raw z against noise is no threshold.
2. **Only falling paths (E2b).** Physics: a straight pass is always heard with falling pitch,
   while voices wander and hums stay flat. Requiring a ≥ 2 % fall within the window helps (TV
   median 25 → 17), but paths cheat: they ride a steady hum and drop at the end, or hop between
   unrelated features.
3. **Smooth, falling, against a running median (E2c).** Two more physics priors: whiten each bin
   against its own running median over ±7.5 s, so a steady hum *is* the reference and vanishes
   (hums are the integrator's job) while a moving tone never sits in one bin long enough to become
   it; and track slope as well as frequency, paying for each change of slope, so a path has to
   bend gently like a real Doppler curve. With the recorder's own calibration chirps excluded:

   | recording | typical z | max z |
   | --- | ---: | ---: |
   | quiet bedrooms, indoor departure, spatial test | ~0 | 1.2–1.8 |
   | bedroom at night | 0.4 | 6 |
   | TV + construction (the hardest background) | 4.6 | 7.4 |
   | **bathroom with the plane pass** | 3.8 | **13.5** (the pass, 58–68 s) |

   A blind detector that ranks the plane first in its recording, about 6 z above the busiest
   background we have, from three pieces of physics: tones move, they fall, and they bend gently.

Open: the threshold needs far more backgrounds (music, singing, speech up close, traffic, wind,
outdoors); the two fainter passes in other sessions (an arrival 3.6 km away, a departure 4 km
away) weren't found in this band, which may be right (no audible tone) or not; harmonics (E5)
could add more; the cost in Swift should be small (a few bins of state per frame).

## The zoom-out: the real attacker isn't blind

E1 *is* the attacker who has ADS-B: given the plane's track, this recording shows it at z 9.5. Our
check searches blind, so it will always be weaker than an attacker with candidate flights; even a
perfect blind check is only an upper bound on what's hidden. The honest bar is **"someone who
knows where the planes were can't find them"**, and we can measure exactly that: the recorder app
logs the real tracks with every session.

## Next experiments

1. **E2, continued:** false alarms on music, singing, close speech, traffic and outdoor clips; the
   look-elsewhere price (blind z against the known-path z on the same pass); the band up to 8 kHz.
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
short-window path search for anything that moves (E2c's: running-median whitening, smooth falling
paths). Removal (`lines`) follows whatever either finds.
Scored, in the end, against the known-path attacker.
