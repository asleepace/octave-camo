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

## E2, round two — broadband awareness, sensitivity, and the shape test (done)

Scripts: scratch `scenes.py` (synthetic scenes at 48 kHz over pink-ish room noise), `e2d.py`,
`e2e_shape.py`. Null now calibrated on that room noise (z scales differ from round one).

**A broadband-aware statistic** (SOAP's "line-aware" idea, turned around): subtract each frame's
median excess across the band before the search, so a bang or a door, which raises every bin of
its frame, can't feed a path, while a tone, which raises a few, still does. On the recordings:

| recording | plain (E2c) max z | broadband-aware max z |
| --- | ---: | ---: |
| quiet rooms (four sessions) | ≤ 1.5 | ≤ 2.5 |
| TV + construction | 6.0 | 9.5 |
| **bathroom plane pass** | 11.0 | **19.4** |

The plane's margin over the busiest room doubles (about 5 → 10).

**Sensitivity, blind against known path** (modelled fan tone, 1.23 kHz, 141 m/s, 2 km, in room
noise; windows over its 1.0–1.7 kHz sweep):

| tone, dB per Hz | blind max z | known-path z | blind path error |
| ---: | ---: | ---: | ---: |
| 10 | 0.2 | 6.2 | (wrong path) |
| 12 | 1.7 | 9.3 | 4 Hz |
| 14 | 6.6 | 13.8 | 3 Hz |
| 16 | 13.4 | 19.6 | 2 Hz |
| 20 | 31.0 | 33.4 | 2 Hz |

Blind search finds it from ~14–16 dB/Hz; knowing the path, from ~10 dB/Hz: the look-elsewhere
price is about 4 dB. The current check needs ~30 dB and still loses the part above 1.15 kHz: a
gain of about 15 dB.

**But music looks like planes to a path search.** Synthetic singing (held notes, vibrato,
portamento) scored z 36.7, a siren 21.0, a melody 20.2, speech 13.6, against 31.0 for the fan tone
at 20 dB. They're smooth and they fall too. Their paths give them away, though: 1,477 → 604 Hz in
10 s (singing), 1,869 → 604 (siren), 1,799 → 873 (music), while the real pass fell 1,688 → 1,324.

**The shape test** (the attacker's own move): fit a straight flyby, f(t) = f0 / (1 + v·x/(c·r)), to
each window's best path, multi-start; it passes when the rms is under 0.5 % of f0 (the check's
existing bar) with 20–300 m/s and at least 50 m.

| scene | max z | windows passing |
| --- | ---: | ---: |
| singing, music, siren, speech, descending scales | 8.5–36.7 | **0** |
| room noise, construction bangs | ~5 | 0 |
| all five recordings without a plane pass (TV + construction too) | ≤ 9.5 | 0 |
| modelled fan tone, 20 dB/Hz | 31.0 | 13 / 20 (fit: 142 m/s, 1.84 km; truth 141, 2.0) |
| modelled fan tone, 14 dB/Hz | 6.6 | 3 / 20 |
| **bathroom plane pass** | **19.4** | **4** (the pass, 58–68 s) |

Perfect separation on everything we have. Caveat: on the real pass the fitted geometry is off
(85 m/s, 566 m against ADS-B's 141 m/s, 3.1 km): ten seconds of a climbing plane's falling half
can't pin it. Fine for deciding *that* it's a flyby, not for saying where it was; longer spans or
joining windows would help, and a turning or climbing aircraft may fit worse than this one did.

**So the detector design is:** 0.17 s windows → each bin over its running median (±7.5 s) → minus
each frame's broadband median → clipped → Viterbi over smooth falling paths (slope state, penalty
per slope change, ≥ 2 % fall per 10 s) → flyby shape test. Open: more backgrounds (real music and
singing, traffic, outdoors, wind), the band to 8 kHz, harmonics, joining windows into whole passes,
and the cost in Swift.

## E4, first result — the real engine on the real pass (done)

With Swift building locally, the lab cloaks recordings with the exact wasm the site serves
(`python3 -m lab cloak`, byte-identical to CI's build) and scores them (`python3 -m lab e2 files`).
The bathroom pass, blind detector + shape test:

| version | max z | windows passing the shape test |
| --- | ---: | ---: |
| original | 19.4 | 4 |
| **Full** | 19.4 | 4 |
| **Experimental** | 13.9 | 1 (z 12.8, 65 s, 1,559 → 1,125 Hz) |

Full leaves the fan tone untouched; Experimental's `lines` stage removes part of it, but the pass
is still detectable, because `lines` only removes what the check sees, and the check can't follow
this sweep. Exactly the gap PLAN.md's next step closes: once the path search is part of the check,
`lines` will remove what it finds.

**Second session, outdoors on a residential street (schema 2.0 with markers; its context label
said "freeway" by mistake):** in 0.6–2.5 kHz nothing passes the shape test, before or after
cloaking. Up to 8 kHz one window passes: a tone falling 3.6 → 2.8 kHz at 28–38 s, near a "plane"
mark at 31 s. It isn't an aircraft (every aircraft in the ADS-B log was already receding, falling
3–7 % in those 10 s, not 30 %), and it can't be a car's Doppler shift either (30 % in 10 s needs
~45 m/s on a residential street): most likely a vehicle slowing down, its engine or whine pitch
falling with its revs. **So the shape test can be fooled by a source that changes its own pitch**
(a deceleration, a gear change), not only by geometry; the fit put it at 89 m/s and 805 m, a
plausible aircraft. Joining windows into whole passes (a real flyby rises in level and then falls,
and its frequency flattens out at both ends) and checking the level against the pitch should tell
them apart. The tone survives Full and Experimental untouched (the check doesn't see it). The 737
that passed 3.1 km away was closest at ~14 s; the person recording marked it at 31 and 40 s, after
closest approach, as a departure's aft-radiated roar would be (the third session consistent with
the directivity pattern). Oddity: after cloaking, an unrelated non-flyby path at 0–10 s scores
higher (z 8.5 → 16.4); probably an edge effect at the clip start, to check.

**Third session, indoors with the TV and a fan on, window open (the nearest aircraft 5 km away,
a climbing 737-800; there's no trackable tone from it: the known-path attacker, searching its real
track with the rest frequency free and ±6 s of timing, scores z 1.4, and the 30–150 Hz level only
loosely follows the predicted loudness of the three nearest aircraft, r ≈ 0.4–0.5, not
attributable to one):** in 0.6–2.5 kHz nothing passes the shape test, before or after
cloaking (max z 11.8, TV speech). Up to 8 kHz, **seven windows pass, all false**: gentle falls of
10–15 % through the fan's hiss at 4.8–8 kHz, z 5.6–8.6, with implausible fits (24–79 m/s at
61–779 m; the aircraft were 5–14 km away), one riding the band's top edge. A flyby fits almost any
gentle smooth fall, so the shape test only discriminates when the path bends. What the data says
so far: every false pass in either band has z ≤ 8.6 (this hiss; the street's decelerating
vehicle at 6.2), the real pass z 19.4. **A decision threshold of z ≈ 10 plus the shape test**
would separate everything we have, at the cost of the faintest modelled passes (14 dB/Hz, z 6.6).
Also worth adding: an edge guard (no path within a few bins of the band's edges; several of this session's strongest main-band paths start at its 2,500 Hz top edge too), and joining
windows (a real pass bends over 20–30 s; a gentle drift through hiss doesn't).

**The known-path attacker needs geometry tolerance** (later corrected: it didn't; see the next
section). Taking the ADS-B track as given, it barely saw this pass (z ~2), and the sweep seemed
about twice as steep as the geometry predicts. That track came from the session's own polls,
which start with the recording: the plane's track began mid-clip, and a velocity smoothed over
20 s is poor at a track's ends. With the positions from before the first poll (backfill, once its
bad rows were dropped) the same attacker scores z 11.1 at zero time offset.

## E2 in the check — the path search ships (done)

`PathSearch` (Swift) is E2 round two inside the check: 0.17 s windows over 500 Hz–4 kHz, each bin
over its running median (median of 1 s block medians over ±7.5 s), minus each frame's median,
clipped to −3…12 dB; smooth falling Viterbi paths (0–2 bins a frame, 2 dB per slope change) in
10 s spans every 2.5 s, at least 2 % of fall, clear of the band's edges by 3 bins; z ≥ 10 against
the same search on 60 s of white noise. Spans are joined where their paths agree, each frame takes
the median bin, the ends are trimmed while the excess along the path (over ±0.5 s) is under what
the search collects per frame from noise plus 2 dB, and the pass must last 12 s (longer than one
span). The check then keeps it only if its flyby fit passes; `lines` fills what it keeps.

**Synthetic.** The modelled fan tone (1,234 Hz, 141 m/s, 2 km): found from 14 dB/Hz at 16 kHz and
16 dB/Hz at 48 kHz (as in the lab), and the fit recovers it (1,234.6 Hz, 140.6 m/s, 1.98 km). The
frame tracker alone never sees it above 1.1 kHz. Speech, singing, whistling, birdsong, held notes,
steady tones, hum and white or pink noise give no pass; a descending scale and a siren are found
and rejected by the fit. The detection baseline's drifting 1.2 kHz pass is now covered whole at
20 dB (was 14–17 %).

**The recorder sessions, through the real wasm** (`python3 -m lab check`): the bathroom pass is
the only pass the path search reports on any of the eight sessions, original audio. A first
version without the duration rule also reported two single-span falls, 2.7–3.9 kHz: one through
the TV session's sound, one created at the end of the bathroom clip by Experimental's fill. Both
fit a flyby (rms under 0.5 % of f0) but lasted one span.

| bathroom session | check: flyby passes | lab blind detector: max z, windows passing | known-path attacker (B38M, real track) |
| --- | --- | --- | ---: |
| original | 57–83 s, 1,770 → 984 Hz | 19.4, 4 | z 11.1 |
| Full | the same | 19.4, 4 | z 11.3 |
| **Experimental** | **none** | **12.5, 0** | **z −1.2** |

So the page now tells the truth about this clip under Full (one flyby left), and Experimental
removes it for every detector we have, including the attacker who knows where the plane was. The
TV and street sessions report no pass before or after cloaking. Cost: on the 108 s, 48 kHz clip the
check takes 12 s instead of 8 s.

**Its z is not the lab's.** Real rooms score far above white noise: on the bathroom clip,
plane-free spans reach z 30 (a broadband transient makes a steep "path"), the pass 62. The lab's
z (null on synthetic room noise, 600–2,500 Hz) put the same pass at 19.4. So the threshold mostly
sets the sensitivity on clean backgrounds; on real ones the duration rule and the fit decide.
Calibrating against the clip's own span scores is an option if false passes show up.

**Lab fixes found on the way.** The whitened-spectrogram cache was keyed by file name, so a
re-cloaked file was scored from its old spectrogram (E4's Experimental row was computed before any
re-cloak, so it stands). And the adsb.lol 10 s archive has rows that aren't positions (latitudes
far outside ±90°); about 15 % of the backfilled rows in the first six sessions were such rows, and
one of them in a track turned its smoothed velocity, and so its Doppler curve, into NaN. Both are
fixed (the cache key includes the audio; rows are range-checked when fetched and when indexed).

## The place search (first result)

`python3 -m lab locate`, after the video in SOURCES.md: a 500 m grid over 16 × 16 km around the
true position (1,089 points), then 100 m grids around the best point and the truth. At each point,
each aircraft's Doppler curve is predicted from its real track (sound travel included), scored
along the whitened spectrogram with the rest frequency free and against the same curve at six
wrong times; aircraft beyond 10 km of a point count 0; all aircraft are summed on one timeline. The
recording time is given exactly (a stronger attacker than one who knows the post time). Silence
isn't modelled yet. Distances only.

| bathroom session | true point's rank | best guess off by | area within 3 of the best |
| --- | ---: | ---: | ---: |
| original | 22 of 1,089 (top 2 %) | 8.5 km | 2.0 km² |
| Full | 26 (top 2.3 %) | 2.5 km | 0.25 km² |
| **Experimental** | **888** (bottom 19 %) | 8.2 km | 0.75 km² |

One plane in 108 s narrows the place to the top few percent of the box but doesn't pin it:
another aircraft's chance match elsewhere beats it, and a single pass only fixes a band at the
right distance from the track. A clip with two or more passes is where the video's locked scoring
would pin it. Full leaves the evidence (the B38M's z at the true point stays 6.9); Experimental
removes it (−2.1).

**A ninth session, indoors with the window open and the TV on**, an aircraft climbing out 3.9 km
away: the blind check sees only three 5 s pieces (550–620 Hz) and no pass; the known-path attacker
scores it z 6.5 (712 Hz) on the original, **4.7 after Full and 4.1 after Experimental**. A faint
pass under 1 kHz that no blind detector finds survives both presets, because removal is driven
by what the blind check sees. The attacker with the tracks will always see more than a blind
check, which argues for removal that uses the same tracks (see PLAN.md).

## Track-driven removal (in progress, `track-fill` branch)

`TrackFill` (Swift, CLI `scrub --expect passes.json`, lab `python3 -m lab trackfill`) takes each
aircraft's predicted Doppler factor at the recording position and, around its closest approach,
searches every rest frequency (0.2 % steps) and ±6 s of timing for tones following the curve:
each rest frequency's best mean excess minus the same at four wrong times, scaled by its
neighbours' spread (±25 %). Then it fills the tones it finds with noise along their curves.

**What worked:** on the ninth session it finds, with no blind detection at all, the tone the
known-path attacker uses (698 Hz), plus 782 and 887 Hz. The search is the same with or without
the low band regenerated, and the statistic cancels artefacts that sit still in time (the first
version, which took the best of all rest frequencies for its null, was thrown by the low band's
crossover and found nothing).

**What didn't, yet:** the attacker's z after removal went *up* (Full 4.7 → 6.2), on a fourth tone
at 534 Hz the fill never touched (0.00 dB change along it): removing the three strongest tones
cleaned the attacker's null, so the next one stood out more. The plane carries a family of tones
(about 490, 534, 698, 782, 887, 993 Hz); one at a time, each is marginal against ~1,800 rest
frequencies (z 2–4 locally, 0.9–1.4 dB). Also measured: the noise fill sits about +0.3 dB above
its surroundings at the curve's centre and −0.3 dB at the strip's edges (white noise, 48 kHz,
averaged along a 36 s curve). Against a matched filter whose nulls vary by ~0.1 dB, even that
could become a trace.

**Next:** search engine-tone families together (E5: sum the evidence of related tones, as an
attacker would), fill all of a pass's tones down to a low bar, and make the fill's level unbiased
along the curve, then score again with the known-path attacker and the place search.

## The zoom-out: the real attacker isn't blind

E1 *is* the attacker who has ADS-B: given the plane's track, this recording shows it at z 9.5. Our
check searches blind, so it will always be weaker than an attacker with candidate flights; even a
perfect blind check is only an upper bound on what's hidden. The honest bar is **"someone who
knows where the planes were can't find them"**, and we can measure exactly that: the recorder app
logs the real tracks with every session.

## Next experiments

1. **E2, continued:** real music, singing, traffic, wind and outdoor clips against the check's
   path search (now in Swift, with joined passes); level against pitch to tell a slowing vehicle
   from a flyby; the band up to 8 kHz; a faster search (one forward pass shared by the spans).
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

Two detectors in the check: the long-window integrator for steady lines, and a short-window path
search for anything that moves (running-median whitening, a broadband-aware statistic, smooth
falling paths, a flyby shape test that keeps music out; shipped for falling passes, see above).
Removal (`lines`) follows whatever either finds. Scored, in the end, against the known-path
attacker, which now runs on every session with backfilled tracks.
