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
existing bar) with 20–300 m/s and at least 50 m (since capped at 30 km: see the tooling review below).

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
bad rows were dropped) the same attacker scores z 9.8 at zero time offset (z 11.1 with the
first version of its null; see "The known-path attacker's null" below).

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
| original | 57–83 s, 1,770 → 984 Hz | 19.4, 4 | z 9.8 (+0.74 dB) |
| Full | the same | 19.4, 4 | z 10.1 (+0.74 dB) |
| **Experimental** | **none** | **12.5, 0** | **z −0.8** (−0.07 dB) |

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
scores it z 7.1 (712 Hz, +1.0 dB) on the original, **6.2 after Full and 5.6 after Experimental**
(+0.64 and +0.57 dB). A faint
pass under 1 kHz that no blind detector finds survives both presets, because removal is driven
by what the blind check sees. The attacker with the tracks will always see more than a blind
check, which argues for removal that uses the same tracks (see PLAN.md).

## The place search on every session (the location re-run)

The independent review's first point: per-flight z says whether one curve fits better at the
right time than at wrong ones; the attacker's question is where the clip was recorded. So the
place search ran on all 21 sessions, then on fresh copies (today's engine: Full with gentle
flattening, Experimental with strong, and Full with removal from the flight archive, the page's
path) of the seven where the original gives the place away. Scoring now runs on a log-frequency
axis (4× faster, unbiased against the direct search). The number is the true point's rank on the
1,089-point grid and **rank bits**, log2((N + 1) / 2 / rank): 0 is a blind guess, 9.1 the truth
ranked first. On the sessions that hear no usable aircraft the truth ranks 42–72 % (one 5 %), so
about ±1 bit is noise. A likelihood-model posterior was tried and dropped: one point's large z
dominates it (values to −28,000 bits).

**Originals:** 14 of 21 give the tone place search nothing (rank near or below a blind guess). Seven
narrow it:

| session | original | Full | Experimental | Full + archive tracks |
| --- | ---: | ---: | ---: | ---: |
| bathroom (efb8f8) | 4.8 (rank 20) | 4.5 (25) | −0.6 | −0.7 |
| 37a954 | 4.9 (18) | **9.1 (1st, 0 m off)** | **9.1 (1st)** | −0.9 |
| 94d99a | 5.0 (17) | 3.8 (40) | 0.3 | 3.8 (nothing filled) |
| af39e1 | 2.3 | 0.4 | 0.9 | −0.7 |
| a2f229 | 2.1 | 2.4 | **7.1 (4th)** | 2.4 (nothing filled) |
| e9a1c3 | 2.1 | 0.0 | 0.0 | 0.0 |
| f8b75a | 1.7 | 1.5 | 1.3 | 0.0 |
| **mean** | **3.3** | **3.1** | **2.5** | **0.6** |

- **Full alone barely moves the place** (3.3 → 3.1 bits). The z work on the blind presets isn't
  moving the number that matters; removal from the flight archive is (0.6, at or below noise on
  five of seven).
- **The presets can make it worse.** On 37a954 a faint 699 Hz pass survives Full, and Full cleans
  everything around it: the excess along the true curve falls (1.05 → 0.74 above the wrong-time
  mean) but the wrong-time spread more than halves (0.14 → 0.06), so the truth goes from 18th to
  first. The review predicted this from the 534 Hz case; here it is in the place, not just in z.
- **a2f229, Experimental: seed luck, not a leak.** The truth's 4th place came from a feature at a
  ~352 Hz rest (curves through 300–400 Hz) that the original doesn't have. Stage by stage (CLI,
  same seed), its excess along the true curve is 0.07 in the original, 0.35 after `hum`, 0.51
  after `lowband` (any flattening) and 0.88 after `lines`; but it's there at wrong times too.
  Over eight seeds the true point's z for that aircraft is −0.5, 0.3, −0.5, −0.3, 0.7, 1.4, 4.0
  (the copy scored above) and −0.4: the original's was 1.2. The cloak puts a steady excess just
  above the regenerated band's 300 Hz edge that every curve dipping there picks up, and on one
  draw it lined up with the truth. Harmless on average, but it means **a cloaked copy's place
  score is one draw: score several seeds** (the page draws a fresh one each run).
- **37a954 is systematic.** Over four seeds Full gives z 12.0–12.2 (original 7.5), and it comes
  from `subtract`: it cancels the room's steady tones, which the wrong-time curves were crossing,
  and only trims the faint moving 699 Hz tone (excess 1.79 → 1.38), so the truth stands out.
- **Where archive removal did nothing** (94d99a, a2f229) every aircraft's z was below TrackFill's
  stopping statistic (2.5), so nothing was filled, but faint evidence summed over the grid still
  ranks the truth in the top 4–10 %. Stopping on per-flight z doesn't bound the place.
- **The search is tone-only.** On 6b838f the 767 that the loudness attacker scores z 5.5 isn't
  found (rank 924): a broadband jet needs the envelope term in the place search too.

## The public corpus: 35 held-out passes (tone removal)

Data: Pathak, P. (2026). *Aeroplane data full analysis and raw files.* Zenodo, record 23424278.
CC BY 4.0. Forty smartphone recordings of aircraft passing one place (May 2026, many light aircraft,
some jets), each with a hand-traced curve of one engine harmonic and the ADS-B track. `python3 -m
lab zenodo` (lab/zenodo.py); the data stays in `$LAB_DATA/external`.

The recorder's position isn't published, and the lab never tries to recover it (the tracks and
published distances could be combined to locate a private person's recording spot, the attack
this project defends against), so this scores **tones, not places**. The traced curve is the
tone's real path, a stronger attacker than any curve predicted from tracks: its shape is scored
like the place search (every rest frequency, against six wrong times). Each recording is the
traced segment plus 5 s either side, which places the curve; 35 of 40 fit that layout (the rest
are left out). Ridge jumps in the traces (one drops to 61 Hz) are dropped first. Scored once;
nothing was tuned on it.

| | original | Full | Experimental | Full + the traced curve as its expected pass |
| --- | ---: | ---: | ---: | ---: |
| median z along the traced curve | 3.7 | 4.0 | 3.6 | 1.8 |
| passes at z ≥ 3 (of 35) | 22 | 20 | 18 | 12 |
| passes at z ≥ 5 | 13 | 14 | 15 | 8 |
| blind check finds a flyby | 33 | 1 | — | — |
| change above 300 Hz (median / max) | | 0.5 / 1.5 dB | 0.6 / 2.3 dB | 0.7 / 2.2 dB |

- **The blind presets fool the blind check, not the tone.** The engine's own check finds a flyby
  in 33 of 35 originals and 1 after Full, yet the traced tone's z doesn't fall: Full raises it by
  more than 1 on 14 passes and lowers it on 13 (Experimental: 10 and 16). The same cleanup effect
  as 37a954, now on independent data: "the check sees nothing" is not "the tone is gone".
- **Removal with a perfect curve helps but doesn't finish.** It halves the median and takes the
  strong passes (13 at z ≥ 5) to 4. Two causes, both in TrackFill:
  - **the eight-tone cap**: 10 of 35 passes stop at eight filled tones with z still up (light
    aircraft and props make many harmonics);
  - **its statistic disagrees with the attacker's** on some passes: N451EE_R51 scores −2.0 by
    TrackFill's own test (nothing filled) and 8.6 by the lab's.
- **Cost stays small:** under 1 dB median above 300 Hz for every variant.

## Removal's stopping test against the attacker's (public corpus, split)

The corpus is now split by a hash of each case id (`zenodo.half`): 17 passes for tuning, 18 held
out (`lab zenodo --holdout`), chosen after the one look above. Everything below was tuned on the
tuning half and our own sessions, then the held-out half was scored once.

**Why removal stopped early.** After removal its own test scores a pass near 0 while the attacker
still finds it: on N4004R_R19 removal filled the 288 Hz harmonic and stopped at z 0.9, and the
attacker's best match moved to a 440 Hz harmonic it never touched. Two causes: the eight-tone cap
(10 of 35 passes hit it), and resolution: removal tests with 0.17 s windows (5.9 Hz at 48 kHz),
the attacker with 85 ms windows and ±2 of its 11.7 Hz bins.

Tuning half, z along the traced harmonic after Full + the traced curve as its expected pass (two
seeds where shown):

| removal | median z | z ≥ 3 | z ≥ 5 | change above 300 Hz, median / max |
| --- | ---: | ---: | ---: | ---: |
| cap 8 (was shipped) | 2.5 | 7 | 6 | 0.69 / 1.7 dB |
| cap 24 | 1.7 / 1.7 | 4 / 2 | 3 / 1 | 0.7 / 1.9 dB |
| cap 24, ±24 Hz slack | 2.7 | 7 | 6 | 0.6 / 1.7 dB |
| cap 24, ±24 Hz and 2 % slack | 4.3 | 10 | 7 | 0.5 / 1.8 dB |
| cap 24, windows 0.17 + 0.085 s | 0.7 / 0.7 | 5 / 2 | 1 / 2 | 0.8 / 3.5 dB |

- **Slack backfires:** widening what counts as on the curve raised the wrong-time scores more
  than the real tone's, so removal filled less. Not shipped (options, off).
- **The second window works on the corpus and fails on our sessions.** Same seed, our sessions:
  on e9a1c3 it made 7 fills where one window makes none, and left a hole (the truth 1,045th of
  1,089, p 0.000 from the bottom; one window: p 0.51); 37a954's place got easier (p 0.49 → 0.14
  and 0.61 → 0.45 over two seeds). Fills aren't clean enough to fill on weaker evidence: a filled
  strip is a faint mark along the exact curve. Not shipped (option `--track-windows`).
- **The cap is shipped at 24.** On our sessions it changes nothing (none reaches 8 tones).

Held-out half, scored once (18 passes):

| | original | Full | cap 8 | cap 24 |
| --- | ---: | ---: | ---: | ---: |
| median z | 4.5 | 3.8 | 0.95 | 0.89 |
| z ≥ 3 | 11 | 10 | 5 | 4 |
| z ≥ 5 | 8 | 7 | 2 | 2 |
| change above 300 Hz, median / max | | | 0.77 / 2.2 dB | 0.80 / 2.5 dB |

A modest confirmation: three passes improve (N9658K_R24 5.0 → 1.8, N2933A_R08 2.3 → 0.0, N394FX_R20
2.5 → 1.5), none get worse. The next lever is the fill itself: until a filled strip is
indistinguishable from the background around it, removing more means marking more.

## Two noisy outdoor walks

Two phone recordings made on a walk outdoors (traffic, footsteps, a tow truck), with jets
overhead: 196 s (nearest aircraft 2.9 km) and 42 s (3.4 km). The listener moved (about 130 m and
15 m); the lab treats them as standing at the start point (walking shifts a tone by about 0.3 %,
inside the search's slack).

| place p (tones; tones + loudness) | original | Full | Experimental | Full + archive tracks |
| --- | ---: | ---: | ---: | ---: |
| 196 s walk | 0.89; 0.92 | 0.66; 0.90 | 0.16; 0.39 | 0.54; 0.79 |
| 42 s walk | 0.54; 0.36 | 0.40; 0.47 | 0.43; 0.50 | 0.23; 0.41 |

Nothing places either walk, before or after. The planes were 3–5 km off, under a loud broadband
street. One thing worth knowing: on the 196 s walk the known-path attacker's z for one jet (5.3 km)
goes from 0.0 in the original to 2.0 after Full and 5.8 after Experimental. Not from the cuts
(putting every cut cell back leaves 2.2): the cleanup quiets the background, and a faint real
harmonic stands out more. The place search doesn't pick it up (p 0.16, one aircraft of four),
but it's the same effect as 37a954's: a cleaner background sharpens what survives.

Also found: two lab jobs fetching the same archive half hour at once read a half-written file
(12 bogus passes, 99 fills). The cache is now written atomically, and a half hour fetched before
it's complete isn't cached as final.

## Review of the place-scored work, and the loudness term in the place search

**Review.** Re-read the fast scoring, ranks, baseline, benchmark, cache lock, holdout guard and
the z-1 stop. One flaw: the no-information draws took "wrong places" from every other point,
including those within 2 km of the truth, which share its evidence; that made p conservative.
They're now left out (p moved by about 0.01). One worry checked: after archive removal the truth
often sat in the bottom 10–20 % of the grid, which would be a hole an attacker could look for.
Scored from the bottom against the same baseline, p 0.05–0.96 over the seven sessions' archive
copies (two seeds): none significant. **But 6b838f** (the 767, scored later with the loudness
term) gives p 0.016 from the bottom after Full and 0.017 after archive removal (0.19 for the
original): several aircraft each a little below their wrong-time null (sum −6.6). One such p among
about twenty low-side tests is about what chance gives; it needs more seeds before it's called a
hole.

**94d99a.** Archive curves against the exact-track curve: 1.0–2.3 % apart in factor around the
closest approach, 0.7 % after the best timing and swing scale (37a954, where removal worked:
0.3–2 %). A relative slack in the removal's search (best within 0.3–1 % of the frequency, on top
of ±2 bins) lifted its z for that aircraft from −2.8…−1.2 to about 0, still below the stop; even
the exact tracks give 0.3. What's left is a z ≈ 1 feature that only the place search's statistic
sees (p 0.046 / 0.052). Not shipped: no benefit shown.

**The loudness term** (`locate --envelope`): each point's predicted level swell fitted to the
band levels over the whole clip against the envelope attacker's 34 wrong times; alone, and
combined with the tones (each aircraft's better z of the two). p against the scene's baseline:

| session | audio | tones | loudness (truth z) | combined |
| --- | --- | ---: | ---: | ---: |
| 6b838f (767, 3 km) | original | 0.82 | 0.10 (4.3) | 0.31 |
| | Full / + archive | 0.99 / 0.98 | 0.10 / 0.10 | 0.47 / 0.46 |
| efb8f8 (737 MAX) | original | 0.002 | 0.11 (2.8) | 0.002 |
| | Full | 0.001 | **0.04** (4.1) | 0.001 |
| | Full + archive | 0.78 | 0.08 (3.7) | **0.08** |
| 37a954 | original | 0.01 | 0.10 (2.0) | 0.01 |
| | Full + archive | 0.41 | 0.09 (3.5) | 0.12 |

(94d99a, a2f229, e9a1c3: no loudness evidence at the truth.)

- **One swell barely places a recording.** The 767's swell scores z 4.3 at the truth, yet the
  place stays at p 0.1: a single pass's loudness fixes only the distance from its track, a band
  many points share. It matters as an addition to other evidence.
- **Archive removal leaves the mid-band swell, and Full sharpens it.** On efb8f8 the loudness z
  rises 2.8 → 4.1 after Full (the same cleanup effect as 37a954's tone), and with the tones gone
  the combined place goes from p 0.78 (tones only) to 0.08. Borderline, not a leak at 0.05, but
  it's the next thing to close: flatten swells above the regenerated band too (PLAN's
  "mid-band swells").

## The holdout

From the review: every threshold here was chosen on the sessions it was then reported on. Two of
the seven sessions whose original gives the place away (af39e1, f8b75a; `corpus.HOLDOUT`) are
now held out: the lab's scoring commands refuse them without `--holdout`, and they're scored only
once a change is settled, with the result reported as it comes. They were picked after one look at
their place-search numbers above, which is the only contamination. The public 40-flight corpus
joins the holdout when it's ingested.

## Stopping track removal (calibrated place scores)

**The rank bits needed a baseline first.** The truth always hears the aircraft passing it, while
many grid points hear none and score exactly 0, so any positive noise at the truth beats all of
those: on 94d99a one aircraft at z 1.2 ranked the truth 40th of 1,089 ("3.8 bits") with nothing
there. `locate.null_bits` redraws the truth's z for each aircraft it hears from what wrong places
score for that aircraft; each result now carries that baseline and **p**, how often audio with no
information about the truth scores as well.

Track removal (Full + the flight archive, the page's path) stopped once each pass's z was below
2.5. Sweep on the five tuning sessions, two seeds each (p; lower is a leak):

| session | original | Full | stop 2.5 | stop 1 | stop 0 |
| --- | ---: | ---: | ---: | ---: | ---: |
| efb8f8 | **0.004** | **0.003** | 0.81 / 0.85 | 0.80 / 0.85 | 0.80 / 0.56 |
| 37a954 | **0.02** | **0.002** | 0.92 / 0.52 | 0.42 / 0.89 | 0.57 / 0.80 |
| a2f229 | 0.08 | 0.12 / 0.06¹ | 0.12 / 0.06 | 0.35 / 0.21 | 0.31 / 0.46 |
| 94d99a | **0.02** | **0.05** | 0.05 / 0.05 | 0.05 / 0.05 | 0.05 / 0.05 |
| e9a1c3 | 0.11 | 0.37 | 0.37 / 0.89 | 0.94 / 0.89 | 0.36 / 0.61 |

¹ Nothing filled at 2.5, so the same as Full.

Mean third-octave level change above 300 Hz against the original (dB): Full 0.4–1.4; stop 2.5
adds 0–1.3 (one session's large fills); stop 1 adds 0.1–0.3 more; stop 0 roughly doubles it.

- **Calibrated, Full alone leaks on three sessions** (efb8f8, 37a954, 94d99a); with the archive,
  on none but 94d99a at either stop.
- **Stop 1 is settled** (TrackFill.stopZ, was 2.5): the borderline session clears, little cost; 0
  costs twice the sound for nothing more. The evidence is one session, so it was checked on the
  holdout once:

| holdout | original | Full | stop 2.5 | stop 1 | change above 300 Hz, stop 2.5 / 1 |
| --- | ---: | ---: | ---: | ---: | ---: |
| af39e1 | 0.07 | 0.40 | 0.87 / 0.95 | 0.87 / 0.95 | 0.42 / 0.45 dB |
| f8b75a | 0.06 | 0.10 | 0.38 / 0.27 | 0.21 / 0.26 | 0.42 / 0.43 dB |

  Both holdout originals turn out borderline once calibrated, and both stops clear them: no gain
  shown, no harm. Recorded as is.
- **94d99a is a curve problem, not a stopping one.** With the archive's curves TrackFill scores
  its aircraft z −1.2 to −3.4 (nothing to remove, at any stop); with the exact tracks the lab
  attacker uses, 0.3 on the same audio, and the place search 0.8–1.2. Stale archive positions put
  the predicted curve off the tone, while an attacker with exact tracks finds it.

## Track-driven removal: the leak closed

`TrackFill` (Swift, CLI `scrub --expect passes.json`, lab `python3 -m lab trackfill`) takes each
aircraft's predicted Doppler factor at the recording position and runs the known-path attacker's
own test on the audio: the best mean excess along f0·factor(t − offset) over every rest frequency
(100 Hz–3.5 kHz) and ±6 s of timing, around the closest approach, against the same search with
the curve moved 20–60 s (a z). While that z is at least 2.5, it fills the best tone with noise
along its curve and tests the filled audio again.

| session | attacker z, original | Full | **Full + tracks** | Experimental | **Experimental + tracks** |
| --- | ---: | ---: | ---: | ---: | ---: |
| indoors, window open (climb-out, 3.9 km) | 7.0 | 6.3 | **0.8** | 5.7 | **0.6** |
| bathroom (B38M, 3.1 km) | 9.8 | 10.1 | **−2.5**¹ | −0.8 | – |
| outdoors on a deck (climb-out, 2.8 km) | 4.8 | 2.8 | **−0.2** | 3.5 | **0.0** |

¹ the engine's own score (9.5 → −2.5 after one fill at 1,109 Hz); the lab's attacker gave the
Full output 10.1. The effect along the best curve after removal is +0.03 dB or less.

On the window-open session it filled four tones (699, 539, 805, 635 Hz): the family that defeated
the first version, which stopped after the tones it liked and left the rest more detectable. On
the plane-free sessions it fills nothing (scores −1.6 to 2.3, below the bar), except the street
session, where it scored a 737 at 4.0 (the lab's attacker: 2.3) and filled two tones.

Getting there took three fixes, each a gap between this test and the attacker's:
- **Its statistic.** The first version scaled each rest frequency against its neighbours; the
  attacker compares the best over all rest frequencies with the same at wrong times. Removing some
  of a plane's tones then made a tone it missed (534 Hz) more detectable, z 6.2 → 12.0 with less
  evidence left: the wrong-time curves had been crossing the other tones, and with those gone the
  null tightened. Partial removal is worse than none; it now stops only when the attacker's score
  is low.
- **Curves off the band's edge.** It averaged a curve over whatever frames stayed inside the band;
  the attacker only counts curves inside it throughout. Half-outside curves, averaged over fewer
  and noisier frames, pushed the nulls' best up and hid the real tone (z 4.1 where the attacker
  scores 6.3).
- **The running median.** Its whitening matched the lab's emulation to 0.002 dB, but medians of
  1 s blocks are coarser than the attacker's exact 15 s median: it scored the real pass 5.2 and
  stopped after two of four tones. Quarter-second blocks score it 6.4.

Also measured: on white noise the fill sits about +0.3 dB above its surroundings at the curve's
centre and −0.3 dB at the strip's edges (48 kHz, along a 36 s curve). After removal the attacker
sees ≤ 0.03 dB along its best curve, so this hasn't shown up as a trace yet; it's worth fixing
before relying on a single long fill.

**Bugs the invariant tests caught.** After finding a tone, an earlier search masked its curve
before looking for the next one: first with the spectrogram's floor, which lowered the nulls of
other rest frequencies whose wrong-time curves cross it (a Doppler factor spans ~0.7–1.7, so 605 Hz
shifted in time meets 1,225 Hz): ghosts at 605 and 292 Hz on a synthetic pass. Then with the
average, which left a loud tone's shoulders (±2–3 %) and ghosts at 607 and 299 Hz at 40 dB. It now
fills and tests again.

**Two more sessions.** In the bathroom with the tap running and construction outside (a 737
4.1 km away): nothing for any detector (attacker z −0.1). The recorder's new build fixes the mains
estimate: 60 Hz grid, 59.981 ± 0.010 Hz (was "50 Hz", ±0.2), a realistic ENF trace; the ultrasonic
band is still empty. On the deck, an aircraft climbing out 2.8 km away (148 m/s, 7,800 ft; the
person recording marked it at 57 s, closest heard at 67 s): the third row above.

## Removal from the archive alone (the page's path)

The page can't fetch flight data (adsb.lol sends no CORS headers, and the page makes no requests),
so the user downloads adsb.lol's half-hour archive: every aircraft's position about every 10 s,
worldwide. Can curves predicted from it alone drive removal that beats an attacker holding the
exact tracks (the app's polls plus full traces)?

**Staleness.** Each archive position carries its block's time, not its own: matched against the
full traces, positions are about 2 s old on average, spread 1–3 s (up to 6 s). At 140 m/s that
is up to ~800 m along track, so velocity from interpolated positions jumps 100 → 180 m/s between
blocks and the curve's shape depends on how it's smoothed. Scored by the attacker on the original
audio, one aircraft's curve under different smoothings ranged 3.9–6.5 (bathroom), 5.3–14.4 (window
open) and 1.5–6.6 (deck); no single estimate was best everywhere.

**One curve per aircraft** (interpolated, velocity over 20 s): removal left the exact-track
attacker at −1.6, 0.8 and **2.8** (the deck pass: its archive curve scored 1.9, under the bar, so
nothing was filled). **Four curves per aircraft** (interpolated over 10 s and 20 s, a ±30 s
straight-line fit, and one anchored to the archive's ground speed), each tested against its own
null: **−1.6, −0.5, −0.2**. Synthetic check (60 s at 16 kHz, positions uniformly 0–5 s stale, the
fan-tone pass at 13–20 dB/Hz, 12 cases on four noise draws): the attacker after removal at most
1.1. The ground-speed curve is the closest (within 2.5 % of the truth after the timing slip), the
interpolated ones the furthest (up to 13 %), and the ensemble beats any one of them.

**What else had to change.** Fills reach the timing slack beyond the searched window (an attacker
whose track puts the closest approach a few seconds elsewhere centres its window there) and widen
by 1 % of frequency (a strip that half-covers a tone leaves its edge). A ridge search, and filling
along warped copies of the curve, did no better than the wider strip and were dropped. The search
now scores every rest frequency at once on a log-frequency axis and shares timings between offsets
and null shifts: a 4-curve synthetic case went from 71 s to 4 s; a 3-minute 48 kHz clip with ten
aircraft (40 curves) costs Full + 16 s in wasm.

**Plane-free sessions:** six of eight had nothing filled; one filled a tone at 2.5 kHz and one four
tones at 2–2.6 kHz. On the busy indoor session (TV, fan) one run filled two tones near 200 Hz that
a predicted curve fitted at z 8 (most likely the TV's sound): a false fill, narrow and harmless to
the cloak, but a sign that the null curves don't capture non-stationary audio. A related caution
for the attacker's own threshold: on one of three white-noise draws the best of ~45,000 rest and
timing combinations along a fixed curve scored z 4.4 with nothing there.

## The envelope attacker (a jet's roar, not its tones)

The short bedroom clip heard a receding 737-800 as broadband roar with no tone, which the tone
attackers can't see. `lab envelope` asks whether a recording's slow level follows a flight's
predicted level. Each band's quiet level (20th percentile within each second, 2.5 s trimmed from
each end; 40–150, 150–500, 500–1,500 Hz and all of it) is fitted as a steady background plus the
flight at its predicted level, added as power: −20 log r minus air absorption at the band's
centre, heard with the travel time. The plane's level and the background's are free, the shape and
its size in dB are not. The score is R², best over bands and ±6 s, z against the same at 34 wrong
times.

**A first version used a correlation, and a review found it couldn't see much.** A flyby's level
changes slowly, so the same prediction 20 s off still correlates well with it: a perfect synthetic
match scored only z 3.4 (r 1.00), and the corpus topped out at 1.6, which said more about the
statistic than the audio. A correlation also accepts any size of change (a 1 dB drift matched a
predicted 10 dB fade). Holding the size to the physics, the same synthetic pass scores z 7–13, and
the room alone, a drifting room, a pass at the wrong time or the wrong way round, taps, and a gain
on the audio all leave it where it should be (invariant tests in `lab/tests`).

**On the corpus (111 aircraft scored across 21 sessions, 8 too flat to judge):**

| Pass | Original | Full | Experimental | Full + tracks (archive) |
| --- | ---: | ---: | ---: | ---: |
| 767 freighter, 3.1 km, window open, TV and fan (40–150 Hz) | **5.5** | **5.2** | 0.3 | **5.2** |
| 737 MAX, 3.1 km, bathroom (500–1,500 Hz) | **4.1** | **2.9** | **2.6** | 2.3 |

The 767's is plain to see: the room's 40–150 Hz quiet level rises about 4 dB to a peak within 2 s
of the predicted closest approach and falls back, and the fit follows it (R² 0.30). That clip had
no tone for any attacker (best 0.0) and the recorder's own check called it not heard. **Full keeps
the swell:** its low band is regenerated noise that follows the original's loudness, so the slow
rise and fall come through (5.2). Track removal fills tones, not loudness (5.2). **Experimental's
flatten removes it** (0.3). The 737 MAX's swell is in the mid band, above anything that's
regenerated: every preset lowers it (tones removed) but none takes it below the bar for certain.

Elsewhere: a 777 10 km away scores 3.4 and a Phenom 300 at 6.7 km 2.8, against 1.7 and 0.8 for
the window-open pass and the short clip's 737-800 (whose fade fits it, R² 0.71, but fits wrong
times about as well). With 111 scored, a 3.4 on a far aircraft is probably the tail of the null, as
with the tone attacker: the bar for this statistic wants calibrating before it's trusted alone.

**Flattening, gentle and strong.** The low band's slow loudness, flattened over a window: on the
767 (envelope z, unflattened 5.2) every window from 5 to 30 s gives 0.2–0.7; the 60–250 Hz level
it costs against none is 0.5/0.4/0.3 dB (5/10/20 s) on that session and 3.7/2.6/1.4 dB on the
bathroom's. A plane closer in swells quicker, and synthetic passes show where a long window stops
working (correlation of what's left with the swell; 0.98 unflattened):

| Pass | 20 s | 15 s | 10 s | 5 s |
| --- | ---: | ---: | ---: | ---: |
| 3 km, 120 m/s | 0.34 | 0.17 | 0.04 | −0.06 |
| 2 km, 120 m/s | 0.42 | 0.27 | 0.11 | −0.02 |
| 1 km, 90 m/s | 0.50 | 0.38 | 0.22 | 0.05 |
| 0.5 km, 120 m/s | 0.69 | 0.61 | 0.50 | 0.30 |

So Full is gentle at 10 s (a plane at a few km, bass movement quicker than that kept) and
Experimental strong at 5 s; both named, swappable per preset.

**What it reveals:** the moment of closest approach, within a couple of seconds, and from the
swell's width and size a rough distance; with the flight logs that's a time-and-distance match,
like the video's two-event method but from loudness. Guards that matter: predictions must swing
1.5 dB over the clip, at least 20 wrong times must count, their spread is floored at 0.05 (a far
aircraft's predictions at different times can be near copies: z 3 from nothing), heard times that
would run backwards (position glitches) are dropped, and bands past Nyquist are left out.

## The known-path attacker's null

The lab's known-path attacker (`python3 -m lab attack`) scored each aircraft as a z against the
same search with the curve moved to eight wrong times, summing the excess along the curve. Two
problems, fixed: a sum reads a curve that runs off its track's span (fewer frames) as less
evidence, so it now uses the mean; and eight nulls make a fragile spread: when a cloak removed
tones that the wrong-time curves happened to cross, the spread shrank and z could jump with less
evidence left. It now uses 34 wrong times (20–60 s either side; the session's curves are stored
±120 s around the audio) and reports the effect in dB beside z. Re-measured: the bathroom pass
11.1 / 11.3 / −1.2 (original / Full / Experimental) → 9.8 / 10.1 / −0.8; the ninth session
6.5 / 4.7 / 4.1 → 7.1 / 6.2 / 5.6. Conclusions unchanged; the ninth session's leak is larger than
first measured. Earlier numbers in this notebook used the first version.

**A tenth session**, indoors with construction outside and the TV on, no aircraft within 12 km
while it was audible (the recorder's new sensors: a mains-hum estimate, on-device sound labels,
an ultrasonic band, impulse responses at both ends): the check reports no flyby, and track removal
has no expected pass to work on. A plane-free control with construction, as intended.

**An eleventh, outdoors with construction (190 s):** two aircraft passed 5.3 and 6.2 km away while
it ran; the known-path attacker finds neither (z ≤ −1, all six nearest under 1). The check reports
one 2 s Doppler-shaped piece from the frame tracker (420 Hz, construction), no path-search pass.
The recorder build was the same as the tenth session's, so its mains-hum estimate still reports a
50 Hz grid (median 50.26 Hz, ±0.28 Hz) beside a clean 60 Hz line, and the ultrasonic band is
still empty.

## The curve benchmark, and a first learned detector

**The benchmark** (`python3 -m lab bench`, lab/passes.py, lab/bench.py): synthetic passes mixed into
a minute of background at a set strength, 16 per strength. A pass is an engine, not a tone: a
fundamental with up to four harmonics and often a second family; spherical spreading, air
absorption, a directivity lobe, the ground reflection sweeping through the tones (Lloyd's mirror),
the engine's speed wandering and turbulence scintillating the level, and half of them heard
through a window. Strength is the strongest tone at closest approach over the background's noise
at that frequency, in dB/Hz. Backgrounds: the nine plane-free recorder sessions (local only) and
six synthetic scenes; each background alone is a negative. A detection counts when it follows one
of the pass's tones; anything else is a false alarm.

| strength (dB/Hz) | check (the page) | blind E2 | known path (z ≥ 5) |
| ---: | ---: | ---: | ---: |
| 6 | 19 % | 6 % | 19 % |
| 9 | 44 % | 25 % | 44 % |
| 12 | 44 % | 19 % | 56 % |
| 15 | 75 % | 38 % | 62 % |
| 18 | 62 % | 56 % | 75 % |
| 21 | 100 % | 81 % | 88 % |

False alarms: the check 2 in 13 min of real plane-free audio (9/h) and 6/h beside passes; E2 none.
The known-path "ceiling" sits below the check at some strengths: a slow or distant pass's curve is
nearly flat, and a flat curve moved in time still matches it, so its z stays low. It's the right
metric for an attacker who has the track, not a bound on blind detection.

**A learned detector** (`python3 -m lab ml data|train|report`, lab/ml.py). Input: the check's kind
of picture (each frequency over its running median, each frame over its own median), on a log
frequency axis (a Doppler curve's shape is then the same at any engine frequency, only shifted)
at 64 ms frames. Model: six 3×3 convolutions dilated along time (receptive field ~8 s), residual,
14 k parameters, trained in JAX on CPU (1,500 steps, 35 min) to mark every pixel on a passing tone,
from 2,400 synthetic examples in training backgrounds only: five of the plane-free sessions and the
synthetic scenes with other seeds. The other four sessions and the three real passes are never
trained on. Passes come out the way the check makes them: the best smooth falling path through
the model's log-odds in each 10 s window, its frequency placed between log bins from the model's
own probabilities and smoothed (2 % bins alone fail the flyby fit's 0.5 %), kept when the fit
accepts it, and joined into passes of at least two windows. Threshold: about one false pass an
hour on 60 min of pass-free training backgrounds (mean probability 0.74).

Held-out backgrounds only:

| strength (dB/Hz) | clips | check | blind E2 | **learned** | known path |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 6 | 11 | 18 % | 0 % | **18 %** | 9 % |
| 9 | 12 | 33 % | 17 % | **58 %** | 33 % |
| 12 | 11 | 45 % | 18 % | **64 %** | 55 % |
| 15 | 12 | 75 % | 42 % | **67 %** | 58 % |
| 18 | 12 | 58 % | 42 % | **83 %** | 75 % |
| 21 | 11 | 100 % | 91 % | **91 %** | 91 % |

False alarms on the same clips: the check 1 (4/h) and the learned detector 2 (9/h) in 14 min of
backgrounds alone; 3.5/h and 4.3/h beside passes. With 11–12 clips per row each is ±15 %, so the
honest reading is "better from about 9 to 18 dB/Hz, by roughly 3 dB", not a precise curve.

On the real recordings (never trained on):

| recording | check | learned |
| --- | --- | --- |
| bathroom pass (1.77 → 0.98 kHz) | found | found (55–85 s, 0.96–1.76 kHz) |
| window-open climb-out (z 7 for the attacker) | **missed** | **found** (55–75 s, 0.51–0.75 kHz) |
| deck climb-out | a 5 s piece | found (55–80 s, 0.60–0.87 kHz) |
| four plane-free test sessions (9.6 min) | – | **6 false passes** (5 in the outdoor construction session) |

So it finds the faint pass the check can't, and the right one each time, but on real
construction audio it calls falling engine and beeper sounds passes far more often than the
synthetic negatives promised (about 38/h on those 9.6 minutes, against ~1/h calibrated). After
cloaking it is mixed: nothing left on the bathroom pass after Experimental or track removal; on
the window-open pass a falling piece at 650–760 Hz remains after track removal, where the
known-path attacker scores 0.8 (a residual the attacker's curve misses, or a false pass: to look
into); on the deck clip, Full's output shows two more falling tones (2.7–3.1 kHz and 0.57–0.66 kHz)
than the original did.

**A walk outdoors** (133 s, walking 133 m along streets: cars, voices; nearest aircraft a helicopter
3.7 km and an A321neo 7.3 km away): the check and E2 report nothing; the known-path attacker finds
nothing (z ≤ 1.8). The learned detector reports one pass, 395 → 343 Hz at 75–87 s, while the
A321neo was closest (81 s); but that plane's predicted curve through those frequencies falls more
steeply (408 → 322 Hz) and the attacker, searching 300–450 Hz along it, scores 0.5. Most likely a
car: one more false pass in traffic. (The corpus places the listener where the recording started;
133 m is under 4 % of these distances, but a walking recording near a close source would need the
location track.) The recorder's mains estimate now reports no grid outdoors, as it should.

**A second walk, at night** (90 s, walking about 110 m, wind most of the way; nearest aircraft
12.4 km, heard at the very end): nothing anywhere. The check finds no flyby, the learned detector
no pass, and the known-path attacker scores −0.1 and −0.5 on the two aircraft whose sound reached
the clip. A clean negative, and the first one in wind. On the recorder side it confirms a bug: its
per-second analyses (the ultrasonic scan and the new low-band level behind its aircraft check)
wrote no rows again, while the mains track, which takes audio in any block size, did.

**Indoors, window open, fan, TV and appliances** (190 s; a Boeing 737 MAX's closest approach,
2.8 km, heard 15 s in; four more aircraft within 8 km): no plane in the audio. The known-path
attacker scores 0.6 on the 737 and at most 2.3 on the others, under its bar; the learned detector
finds no pass. The check calls two short falling tones flybys (2–3 s, around the TV's music); they
don't follow the nearest aircraft's predicted curve (a 1.6 % fall where its curve falls 4 %), so
two false alarms, which cost only a harmless extra removal. The recorder's fixed analyses now
write their rows, and show two things. Its aircraft check marks all nine nearby aircraft "heard":
a 6 dB rise in broadband level anywhere within 20 s is easy to get with appliances, doors and wind
(the loudest rise near the 737 is a two-second thump). And its ultrasonic scan finds a steady tone
from something in the room for three quarters of the clip, which Full passes through unchanged:
a room fingerprint above the band anything in the cloak looks at.

**The same room again, wind outside** (190 s; stereo was asked for and iOS gave mono again; a
737 MAX 9 at 2.2 km whose closest approach reached the phone 8 s before recording began): the
attacker scores 0.5 on its receding half, the check and the learned detector find nothing. Wind
gusts fill the clip, and still raise no false pass.

**Again with the window open, TV and fan** (190 s; a Boeing 767 freighter at 3.1 km heard 64 s in,
seven more aircraft within 7 km including an Embraer 175): no plane in the audio. The attacker's
best on the eight is 0.8, the check finds no flyby, the learned detector no pass, and removal from
the archive (32 curves) fills nothing: the TV's tones fitted no curve this time. The recorder's
broadband check called three of the seven heard again.

**The same room, with a helicopter** (175 s; an Embraer 170 at 4.0 km heard 16 s in and a
Eurocopter EC135 at 4.1 km heard 31 s in): nothing found. The attacker scores −0.5 and −0.6 on
them, the check and the learned detector find nothing, and below 120 Hz the only lines are a
steady pair near 55–65 Hz present all clip long (not the rotor: no Doppler, and an EC135's main
rotor would sit near 26 Hz, which the cloak's low band replaces anyway). Removal from the archive
filled one tone at 1.9 kHz along one of 22 curves: a false fill in the TV's sound, the second.

**A 30 s clip in the same room**, started 11 s after a Boeing 737-800's closest approach (4.5 km):
its receding half scores 0.8 and removal from the archive fills nothing, but the recorder heard
it. Without any detector (raw spectrogram, quiet-percentile band levels per second): no tone at
all, yet 40–500 Hz falls by about 4.5 dB from 3 s to 25 s, where spreading alone from 4.8 to
6.8 km predicts 3.1 dB (plus a little air absorption and the jet's rearward lobe fading). The next
clip, 6 s later in the same room, is flat within ±1 dB in those bands for 52 s, so the background
isn't drifting. A jet's roar is broadband: the tone attackers can't see it, and the cloak leaves
its slow envelope above the low band. Whether a loudness envelope matched to candidate flights
gives an attacker anything is untested.

**And 52 s right after it**, with a Boeing 737 at 5.0 km heard 42 s in and a Challenger 350 at
10 km: the attacker scores 1.4 and 0.4, the check finds nothing, removal from the archive fills
nothing.

**Verdict:** worth pursuing, not yet worth porting (step 3 was "only if it clearly wins"). It wins
on sensitivity and loses on real-world false alarms. Next: harder negatives in training (vehicles
slowing down, reversing beepers, more real outdoor backgrounds: the construction session is where
it fails), a pass-level score that uses the whole curve, more clips per strength, and the real
passes that only more recordings can supply.

## Tooling review (lab detectors and tests)

- **The lab's flyby fit left out the sound's travel time.** `detect.flyby` used receive time as
  emission time; on a modelled 1,234 Hz, 141 m/s, 2 km pass a 10 s window fit 1,317 Hz and 1.7 km.
  It now solves τ + r(τ)/c = t as the Swift `FlybyGeometry` does, and recovers the pass exactly.
  Pass/fail didn't change on any scene or session (E2 re-run: only the bathroom pass passes, now
  fit at 93 m/s and 712 m, was 85–89 m/s and 566–621 m; a 10 s window still constrains the
  geometry poorly). Speeds and distances quoted from the lab's shape test before this were biased.
- **Heights against ADS-B.** ADS-B altitude is barometric (pressure altitude); the corpus measured
  aircraft heights from the phone's GPS height (±3–80 m vertically, and off by the day's sea-level
  pressure, ~40 m on the bathroom day). It now uses the phone's own pressure read the same way,
  which cancels the weather; GPS only when a session has no pressure. Closest distances moved by
  ~1 % (bathroom pass 3.11 → 3.14 km).
- **The check called a looped footstep a flyby.** Its 80 Hz thud, drifting 2 %, fit a "pass"
  3·10¹⁷ m away at 48 m/s whose closest approach lay after the clip. The flyby fit now also needs a
  distance under 30 km (an engine tone is inaudible well before). Found by running the harmless
  scenes four times over: at 10–15 s they were too short for the path search to be tested at all.
- **Tests that couldn't fail:** the falling-notes test now also requires the search to find the
  sweeps (else the shape test is never exercised); one assertion that restated another was
  replaced by a real one; the lab gained tests for the shape test (a propagated pass recovered,
  a scale and a siren rejected), the blind search (follows a 20 dB pass), and pressure altitude.

## The zoom-out: the real attacker isn't blind

E1 *is* the attacker who has ADS-B: given the plane's track, this recording shows it at z 9.5. Our
check searches blind, so it will always be weaker than an attacker with candidate flights; even a
perfect blind check is only an upper bound on what's hidden. The honest bar is **"someone who
knows where the planes were can't find them"**, and we can measure exactly that: the recorder app
logs the real tracks with every session.

## One attacker, one score (foundation review)

Different tests here had drifted into different attackers and leak rules: the place search's
calibrated p, the known-path z against 34 wrong times, the corpus's z against six, the null
test's percentile, the engine's own z, the benchmark gate's rule. THREAT_MODEL.md now names the
attacker every design decision is scored against, and one score: **where the truth ranks among
wrong answers**, read at both ends (top 5 % a leak, bottom 5 % a hole).

**The corpus's score changes.** Its z compared the traced curve with the same curve moved 24–40 s,
six times; with 75 s curves in 85 s clips the moved copies keep under half the swing, and six
values make a fragile spread. It's now scored by **u**: the traced curve's rank among wrong
places' curves, the other passes' traced shapes with their closest approach at this clip's ±6 s
(144 per pass on the tuning half). With no plane (synthetic room noise, music, pink noise, 17
shapes each) u averages 0.53, 0.52 and 0.52, with one or two of 17 in each tail: calibrated.
Untouched, the corpus's tuning half averages 0.92 (11 of 17 at u ≥ 0.95): the planes are there,
as they should be. One lesson from the test: a geometry close to the truth's (fall 0.35 deep
against 0.30) scores as well as the truth. Nearby places do, so u asks "this pass or a different
geometry", not "this exact place".

**The removal variants, re-scored** (tuning half, Full + the traced curve, one seed):

| | mean u | leaks (u ≥ 0.95) | u ≥ 0.9 | holes (u ≤ 0.05) | mean z (six wrong times) |
| --- | ---: | ---: | ---: | ---: | ---: |
| original | 0.92 | 11 | 13 | 0 | 6.16 |
| fixed stop | 0.63 | 2 | 6 | 1 | 2.02 |
| null target | 0.67 | 2 | 4 | 0 | 3.10 |
| null target, no raising | 0.69 | 4 | 6 | 0 | 2.66 |

No information gives 0.50 ± 0.07 and about one in each tail.

- **The variants are closer than z said.** z put the fixed stop well ahead (2.0 against 3.1) on
  large values like N788BM's 11.5; by rank the three are within noise of each other (17 passes,
  one seed). Raising still makes N788BM worse (u 0.26 → 1.0), but the fixed stop has two leaks of
  its own (N913TC 0.99, N231DT 0.99) that z had at 2.9 and 0.0. z and u agree on order (Spearman
  0.73) and not on size.
- **None is clean.** Every variant leaves the truth above a no-information draw on average
  (0.63–0.69). What's left is common to all three, so the next lever is what removal leaves
  behind (the many lines a real engine has, the fill itself), not where it stops.
- Decisions between these variants need more seeds, or the holdout once settled.

## Next experiments

0. **The place as the metric** (envelope term, holdouts, stopping, the public corpus and the
   tone cap done): make a filled strip indistinguishable from its surroundings (it marks the
   curve, so removing on weaker evidence leaves a hole); flatten mid-band swells and score the
   combined place; why cleanup sharpens a faint survivor.
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
