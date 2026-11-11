# Threat model

What octave-camo defends against, what it doesn't, and the evidence for each claim.

## Setting

You post a video. Metadata is already stripped (most sites do this; octave-camo's remux also
drops it). Nothing the picture shows gives the place away. The attacker wants **where** (and, as a
stepping stone, **when**) it was recorded, using only the published sound and the picture's
incidental signals (light flicker).

The attacker can:

- get the clip at the platform's quality (usually AAC around 128 kbps);
- bound the recording time by the post time (hours to days earlier);
- query public telemetry for that window: ADS-B for aircraft, GTFS-realtime for trains and buses,
  AIS for ships, grid-frequency (ENF) archives;
- run unlimited offline compute, e.g. score every candidate location in an area by the Doppler
  curves it predicts for every logged aircraft (shown publicly to work to ~100 m with Python and
  ADS-B, [YT-UytYrhYLOKI] in SOURCES.md).

The attacker does **not** have the original file, other clips of the same scene, or anything
about you beyond this post.

## The attacker every result is scored against

The setting above is the threat. For measuring, one stronger attacker stands in for it, and
every number that decides a design is about this one (docs/EXPERIMENTS.md and the lab use it):

- **Has:** the posted audio; the recording time **exactly** (stronger than the post time, see
  gap 5); a candidate area (a city-sized box, here 16 × 16 km); the **exact tracks** of every
  aircraft (full ADS-B traces, not the few-seconds-stale archive the page can use); this
  repository, the preset and its settings (everything but the random seed: the defense is
  assumed known).
- **Asks:** which candidate place the audio fits best. At each place it predicts every audible
  aircraft's Doppler curve (sound travel included) and scores the mean whitened excess along it
  at every rest frequency (100 Hz–3.5 kHz), within ±6 s of timing, plus the fit of the loudness
  swell; it adds the aircraft up. Per aircraft it **adds up the best four separate lines** along
  the curve (`locate.Scene.lines_of`): every line an engine makes follows the same Doppler factor,
  harmonic or not, so lines too faint to stand out one at a time still add up. (The best single
  line, the lab's first statistic, is a weaker attacker: on the public corpus's passes cloaked with
  the fixed stop it found 3 leaks in 34 where the four-line one finds 12. Four is a choice, not an
  optimum: eight finds about as many, OPEN_QUESTIONS.md.)
- **Wins** if the true place stands out from the places that carry no information about it, in
  either direction:
  - **a leak:** the truth ranks in the top 5 % (p ≤ 0.05 against the no-information baseline);
  - **a hole:** the truth ranks in the bottom 5 %. An attacker who knows the defense removes
    evidence can look for the place that looks most cleaned, so a cloak that leaves its truth
    unusually empty can give the place away too. (How well a real attacker could use a hole isn't
    measured; it's counted as a loss to be safe.)
- **Doesn't yet:** weight the lines (a learned or likelihood-ratio statistic would beat a plain
  sum); use silence (a place that should have heard a plane the audio doesn't have); average
  several renders; search over the time (gap 5). Each is a way this attacker is weaker than a real
  one. The place search (`lab locate`) still uses one line; the corpus and null-test scores use
  both.

### The score

Three things get measured and they aren't the same claim: that a detected line is removed
(a harmonic's z falls), that a known track's score falls, and that the *place* is protected. Only
the last is the goal; the first two are steps toward it, and a result about one isn't evidence
about the others.

One number decides: **where the truth ranks among wrong answers, p**, read from both ends.
Over a set of clips, the cloak is working when its p values look like those of clips with no
plane in them: about 5 % in each 5 % tail, mean 0.5. A design is better if it has fewer leaks
without more holes; sound change above 300 Hz breaks ties. What the wrong answers are depends on
what's known about the clip:

| Clips | Truth | Wrong answers | Lab command |
| --- | --- | --- | --- |
| Our own sessions (place known, never published) | the true place | every grid point over 2 km away, redrawn per aircraft (`locate.null_bits`) | `lab locate` |
| The public corpus (Pathak 2026; position not published and **never reconstructed**) | the pass's own traced curve | the other passes' traced curves, put at this clip's closest approach ±6 s: the shapes other places would give | `lab zenodo` |
| Synthetic scenes | the inserted pass's curve | the same curve at 28 other times, each on its own stretch | `lab nulltest` |
| Our own sessions, a curve nothing follows (holes) | a corpus shape placed where no tracked aircraft is near | the other shapes at that moment ±6 s; scored against the same preset blind to the curve | `lab blank` |

The corpus can't be scored by place without its position, so it's scored on the one question the
place search asks of each aircraft: does this curve, rather than a curve from somewhere else, fit
the audio. The three sets of wrong answers differ, so a number from one row isn't directly
comparable with another's: the corpus's keeps wrong places' closest approach within ±6 s of the
truth's (real wrong places in a 16 km box can be tens of seconds off), and a geometry close to the
truth's scores about as well as the truth. Both make it a narrower question than the place
search's; which way that biases it isn't measured (OPEN_QUESTIONS.md).

Other numbers in the notebook are diagnostics, not verdicts: the engine's own z (TrackFill's
stopping test), the known-path z (`lab attack`, one aircraft against wrong times), the benchmark
gate's leak rule (CI's regression test on synthetic clips), detection rates. A z with few wrong
answers is especially loose: the corpus's first score used six, and put one pass at 20.8 that
ranks simply first among 144 wrong curves.

Rules that keep the score honest: every cloaked copy is one random draw, so a design is scored on
at least two seeds; settings are tuned on the tuning sessions and the corpus's tuning half, and
the held-out sessions and half are scored once, when a change is settled.

## The general attack

Every audio location attack in scope has the same shape:

1. **A source with a public, time-stamped path** (a plane, a train, a ship) emits a narrow tone
   or a loudness pattern.
2. **Propagation encodes your position** in what you hear: the Doppler curve f₀·r(t) (closest
   approach time, distance and speed), the loudness envelope (distance over time), the arrival
   time of a scheduled sound.
3. **The attacker predicts that signature** for each candidate place and time, and integrates
   evidence along it, over every event in the clip at once (their gaps are fixed, so one time
   offset serves them all), and counts silence too: a place that should have heard a plane that
   isn't in the audio is ruled out. This is matched filtering: it finds tones far below what a person or a
   blind tracker could see (`harness/src/matched.ts` reaches about −20 dB SNR in tests).

So the defense must destroy the *fine time-frequency structure* the predictor matches against.
Lowering a tone's level is not enough while its curve survives.

## Channels

| Channel | What leaks | Attacker needs | Defense | Status |
| --- | --- | --- | --- | --- |
| Aircraft tones (fan, prop, rotor) | Doppler curve → closest approach, distance, speed | ADS-B tracks | `subtract`, `scurve`, `lowband`; optionally `TrackFill` from adsb.lol's archive (the known-path attacker's own test, removed until it fails) | Covered, benched; known-path attacker beaten on three real passes |
| Train wheel and motor tones | Same, along a fixed track (often close to people) | GTFS-RT positions | `subtract`, `scurve`, `lowband` | Covered, benched (synthetic) |
| Ship engines and foghorns | Same, slow and long | AIS | `lowband` | Covered, benched (synthetic) |
| Buses, drones | Same | GTFS-RT, Remote ID | Same family | Expected covered, not benched |
| Mains hum (ENF) in audio | Recording time to the second, grid region | ENF archives | `hum`: both 50 and 60 Hz families notched below 400 Hz (to the clip's edges), notches refilled; `lowband` below 300 Hz; `subtract` for lines it can follow above | Covered |
| A defense's own fingerprint (notch pattern, imprinted lines) | Grid region | – | Both families notched and refilled at a static level; low-band noise shape smoothed over 1 ERB | Covered, tested (below) |
| Multi-mic phase | Direction of arrival | – | `mono` | Covered |
| Extra audio tracks (iPhone spatial audio, APAC, 4 channels) | Direction of arrival | – | Only the main track is read; the rest are dropped | Covered |
| Data inside the video packets (H.264/HEVC SEI: encoder settings, camcorder date and GPS, drone telemetry) | Device, time, place | – | SEI removed from copied packets and from the HEVC configuration | Covered for H.264/HEVC; AV1 metadata units are copied |
| The source's own timestamps (a TS stream starting hours in, a recorder's clock) | Time | – | Timestamps rebased to zero | Covered |
| Loudness envelope of a pass | Closest-approach time and d/v | Any of the tracks above | `lowband` flattening: swells slower than 10 s (Full) or 5 s (Experimental) | **Covered below 300 Hz at a few km** (lab envelope attacker: a 767 at 3 km, z 5.5 → 0.2); a close pass's quicker swell partly survives Full; above 300 Hz open (a 737 MAX: 4.1 → 2.3–2.9) |
| Time between events (two passes, a pass and a bell) | One time offset locks every event together, multiplying the evidence | Any of the tracks above | Removing each event's signature; `wobble` warps time by a little | **Open:** measured by `lab locate`; cuts would break it |
| Silence: no pass where one was due | Rules out places under busy routes; a clean clip still says "nothing audible from t₁ to t₂" | ADS-B | – | **Open:** inherent to removal; decoys would blur it |
| Scheduled sounds (bells, horns, foghorns) | Time, plus rough distance from level and echo | Timetables | None | **Open** |
| Room and outdoor acoustics | Place type, not position | – | None | Out of scope |
| ENF as light flicker in video | Recording time, grid region | ENF archives | Optional de-flicker (re-encodes the picture) | Partly covered, see below |
| Picture, speech content, account history | Anything | – | None | Out of scope |

### Flight-track removal and what it reveals

Removal driven by flight logs needs the place and time, which the page reads from the file before
dropping its metadata (or takes typed in), and adsb.lol's archive for the half hour. The page
never fetches it: the user follows a link and adds the file. That download is one worldwide file
per half hour, so adsb.lol learns the time (and the user's IP address), never the place; a user who
wants to hide even that can fetch it elsewhere or later, or fetch several. The place and time stay
in the browser and are never written to the saved file. The archive's positions are a few seconds
stale, so the page's curves are less exact than an attacker's could be (live feeds, full traces);
four estimates per aircraft and fills widened by the timing slack cover that on the passes we have,
three real and a synthetic set, which is still a small sample.

## Evidence

`cd harness && bun run bench:gate` (run by CI on pull requests). Synthetic clips; the default
chain, implemented in the harness and in the Swift pipeline the app ships; a 160 kbps AAC round
trip (the page's save); then both attackers: the blind tracker (6 dB threshold) and the matched attacker with the
true track, two decoy tracks and the exact recording time. Before judging a clip, the matched
attacker is calibrated: three renders of the same scene with no source give its noise floor, and
only a detection clearly above that floor (z more than 3 above it, and above 7) within 1 km of the
truth counts as a leak. Low/high Δ are the mean absolute ERB-band level
change below and above 300 Hz between the posted original and the posted cloak (both through the
same AAC, so the codec's own loss doesn't count); a level difference, not a listening test.

| Clip | Uncloaked | Cloaked (default chain); true location's rank on the grid | Low Δ | High Δ |
| --- | --- | --- | --- | --- |
| Aircraft, distant (5.8 km, −25 dB) | matched: leak, 0 m (z 18) | no detection; top 70 % | 3.1 dB | 0.4 dB |
| Aircraft + speech | matched: leak, 0 m (z 18) | no detection; top 49 %; voice spectrum below 300 Hz correlates 0.68 with the original | 3.2 dB | 0.3 dB |
| Aircraft, close (1.5 km) | both: leak (z 15) | no detection, but top 1 %* | 10.3 dB | 1.3 dB |
| Train, close (120 m) | matched: leak, 0 m (z 12) | no detection; top 43 % | 3.3 dB | 1.3 dB |
| Train, distant (900 m, 600 Hz) | both: leak (z 73) | no detection; top 21 % | 3.1 dB | 0.8 dB |
| Ship (400 m, 6 m/s) | matched: leak, 0 m (z 57) | near the truth at the noise floor (z 7)* | 3.2 dB | 1.0 dB |

The Swift pipeline the app runs gives the same results within a few tenths of a dB (the ranks
differ between the two: separate implementations of each stage). A rank near 50 % is a blind guess; below the threshold is not
the same as hidden.

\* On the close pass the true location still ranks in the matched attacker's top 1 %, below its
threshold: the thinnest real margin. On the ship it means little: a 6 m/s source's Doppler
curve is nearly flat, so it matches steady residue anywhere, and on renders with no ship at all the
attacker reached z ≈ 10 within 250 m of the truth. That's why leaks are judged against each
scene's noise floor: measured z 4.4 for both aircraft scenes, 0 for the close pass, 3.4 and 4.0
for the trains, and 9.5 for the ship (at 160 kbps).

The close pass costs more sound (10 dB low) because its tones are loud and get cancelled.

What this taught us:

- **Trains are the harder case**, not planes. Wheel and motor tones sit above the 300 Hz
  `lowband` cutoff, so regeneration alone never touches them; without the blind `scurve` search,
  the distant train leaked (z 30). `hum+lowband` (the web app's Light preset) still leaks both
  train clips, which is why the app calls it partial.
- **Raising the cutoff is the wrong fix.** `lowband(cutoff=1000)` cleared the train clips but
  leaked the ship and cost 0.8–1.1 dB above 300 Hz.
- **An attacker needs calibrating as much as a defense does.** A fixed detection threshold made a
  slow source look found in silence.

## The cloak's own fingerprint

A defense can add clues of its own. The first version notched only the 60 Hz family: on a real
iPhone clip the output had clean 7 dB dips at 120, 240 and 300 Hz where the original had none,
which says "processed assuming 60 Hz mains", that is, the Americas.

Now `hum` notches both families and refills each notch with noise at the neighbouring bands'
long-term level, and `lowband` smooths the spectral shape of its noise over one ERB, so nothing
narrow (a notch hole, a steady motor tone) is copied into it. Two details mattered:

- **Without the refill**, notching the extra family carved the slow ship's tone each time it
  drifted through a notch, and the dips' timing let the matched attacker place it.
- **A refill that followed its neighbours' level over time** re-imprinted the same timing; the
  benchmark gate caught it. The refill level is static.
- **Filters start cold.** A zero-phase notch (a forward pass, then a backward one) lets the hum
  through for a time constant at each end, where one of its passes starts: a fraction of a second
  of the local grid's hum at the clip's edges, which says which grid it was. The invariant tests
  caught it (the line stayed 5–17 dB above its neighbours). Near each edge both passes now run in
  from inside the clip, already settled, and cross-fade into the zero-phase result; that shifts
  phase by a few degrees there, which isn't audible.

Tests (harness and Swift) check that after the cloak, harmonics of only one family (100, 150, 200,
250, 350 vs 120, 180, 240, 360 Hz) differ by less than 1.5 dB on average, that a wandering mains
line is removed without leaving a hole, and that a steady 87 Hz tone doesn't come back as a narrow
line in the regenerated noise. Measured on noise: plain notches leave −38 to −50 dB dips; refilled,
every harmonic is within the noise's own ±3 dB.

## Light flicker in the picture

Lights on mains power flicker at twice the grid frequency, and a rolling shutter turns that into
faint horizontal bands whose drift is the grid timestamp. The web app scans every frame's row
profile (median over column strips, static part removed, each temporal frequency whitened across
spatial frequency) for a line at 100 or 120 Hz, the way an attacker would. If it finds one, the
user can divide the estimated band out of each row on the GPU. That re-encodes the picture in
standard dynamic range, so the user can untick it (it's on when flicker is found; if it's unticked,
the page warns that the flicker is kept).

Synthetic clips (20 s, testsrc2 scene, readout 50–70 % of the frame period), scan z (detection
above 60). The 120 Hz rows are the hard, common case (60 Hz lights at 30 fps): the bands barely
move, and only their slow phase wander carries the clock. With a wander much larger than real
grids show they're found; with a realistic one they aren't.

| Clip | Before | After removal |
| --- | --- | --- |
| 100 Hz bands, 3 % (rolling at 30 fps) | 426 | 32 |
| 120 Hz bands, 3 %, grid wander ±0.25 Hz | 273 | 32 |
| 120 Hz bands, 1 %, grid wander ±0.25 Hz | 65 | 16 |
| 120 Hz bands, 3 %, real-grid wander ±0.05 Hz | 16–30: **not detected** (see gap 4) | – |
| No flicker | 36 (nothing removed) | – |
| Real iPhone clip, outdoors (IMG_9829) | 29 (nothing removed) | – |

Through the browser (decode, per-row gains in WebGL, re-encode), the saved file scanned at z 34
against 398 for the input.

A picture the scan can't judge is reported as "not checkable", never as clean: under one 4 s
segment of frames, or a frame rate so high (about 200 fps and up) that a 100/120 Hz band is under half a
cycle per frame and looks like a gradient.

## Known gaps

Open questions about the measurements themselves (is the score fair on real plane-free audio, is
the fill neutral, is the engine's stop fair) are in [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md).

In order of how much we think they matter:

1. **Little real ground truth.** The Evidence table above is synthetic. Real scores now come from
   about twenty of our own sessions with saved flight tracks and a public corpus of 35 passes
   (docs/EXPERIMENTS.md), which is still a small sample, mostly of one listener's surroundings and
   one corpus's place. The synthetic pass the null test inserts (a tone and two harmonics) is
   simpler than real engines, which carry many lines, and it has favoured a design the real
   passes then rejected.
2. **Loudness envelope attack.** Measured now (`lab envelope`, docs/EXPERIMENTS.md): a 767's
   low-band swell at 3 km passed through regeneration alone (z 5.2) and is gone with flattening
   (0.2), which Full now does over 10 s and Experimental over 5 s. Still open: a close pass's
   quicker swell under Full, and swells above the low band, which nothing flattens.
3. **Scheduled sounds** are clocks. Removing them is a sound-event problem, not a DSP one, so a
   classifier is the likely route (detect and duck).
4. **Video-side ENF: quasi-static bands.** At 30 fps under 60 Hz lights, the 120 Hz bands barely
   move, and only their slow phase wander carries the clock. With real-grid wander (±0.05 Hz) that
   moving part is too faint to tell apart from a clean scene, so the scan doesn't flag it and
   nothing is removed. Rolling bands (50 Hz grids at 30 fps) and strong wander are found and
   removed (below).
5. **Unknown-time attacker.** We assume the attacker knows the recording time. Searching over the
   time offset would show how much the delay before posting buys.
6. **Hum above 400 Hz** is only removed when `subtract`'s tone tracker sees it (10 dB over the
   noise), and a notch removes a steady line outright but a wandering one only partly (about
   25–30 dB at the fundamental with typical grid wander). Higher harmonics are usually far weaker,
   but an attacker integrating for minutes can use faint ones. Narrow notches up to 1 kHz were
   tried and dropped: they barely touch a wandering line there (the wander grows with the
   harmonic number), and they carved gaps into train tones that broke `subtract`'s tracking, so
   the benchmark gate's close train leaked.
7. **High-frame-rate video** (slow motion) can't be checked for flicker, and AV1 metadata units
   are copied with the picture.
8. **Faint tones, and any above 1 kHz, are counted but not removed.** Tone subtraction removes
   only what its own frame tracker sees: lines at least 10 dB over the noise in a single frame,
   below 1 kHz. The check also averages over seconds (the line integrator) and looks up to 8 kHz,
   so it finds more than the cloak removes; the page counts those lines and outlines them on the
   spectrogram. On a real outdoor clip, 19 lines survived the cloak: faint car tones at
   500–950 Hz, a few at 1–1.3 kHz and a steady 5 kHz whine (ACOUSTICS.md §1). Removing what the
   check finds is the next step (PLAN.md).
9. **The check can still miss weak curved lines.** It averages along slow drifts (the line
   integrator, up to 1 Hz/s) and, since the path search, along falling passes over 0.5–4 kHz that
   last over 12 s and fit a flyby (a jet's fan tone is found from about 14–16 dB/Hz). Still missed:
   fainter passes, passes below 500 Hz too weak for the frame tracker, short ones, and rising or
   wandering lines. An attacker who knows the flight paths integrates along the exact curve and
   sees more (on a real recording, before cloaking, the check and that attacker both found the
   pass). Only Experimental removes what the path search finds.
10. **Steady sounds can link videos.** A fridge, an air conditioner or a computer fan gives no
    location on its own, but its tones can tie an anonymous video to a known one made in the same
    room. So can the room's reverberation.
11. **Music, voices and the cloak's own lines.** Held musical notes are removed like engine tones.
    Singing and a repeated tune show many lines, and speech a few, which the page counts like any
    other until lines are classed by risk. In about half of runs, cloaked speech shows a "long
    tone" at the speaker's own pitch; and a cloaked scene of footsteps gains a steady line near
    100 Hz, classed as hum (likely the hum notch's refill). Neither is a location clue, but both
    raise the counts.
12. **Cloaking is detectable.** Regenerated and refilled noise is statistically cleaner than a real
    recording, so someone could tell a clip was processed. That says nothing about where or when
    it was made, and hiding it is not a goal.

## Guarantees

None. octave-camo **reduces** location leakage from sound. It doesn't remove it, and it can't
help if the picture, the words spoken or the account give the place away. A delay between
recording and posting is a free, real gain: every hour multiplies the tracks an attacker must
try.
