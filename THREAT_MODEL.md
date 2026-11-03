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
- run unlimited offline compute.

The attacker does **not** have the original file, other clips of the same scene, or anything
about you beyond this post.

## The general attack

Every audio location attack in scope has the same shape:

1. **A source with a public, time-stamped path** (a plane, a train, a ship) emits a narrow tone
   or a loudness pattern.
2. **Propagation encodes your position** in what you hear: the Doppler curve f₀·r(t) (closest
   approach time, distance and speed), the loudness envelope (distance over time), the arrival
   time of a scheduled sound.
3. **The attacker predicts that signature** for each candidate place and time, and integrates
   evidence along it. This is matched filtering: it finds tones far below what a person or a
   blind tracker could see (`harness/src/matched.ts` reaches about −20 dB SNR in tests).

So the defense must destroy the *fine time-frequency structure* the predictor matches against.
Lowering a tone's level is not enough while its curve survives.

## Channels

| Channel | What leaks | Attacker needs | Defense | Status |
| --- | --- | --- | --- | --- |
| Aircraft tones (fan, prop, rotor) | Doppler curve → closest approach, distance, speed | ADS-B tracks | `subtract`, `scurve`, `lowband` | Covered, benched |
| Train wheel and motor tones | Same, along a fixed track (often close to people) | GTFS-RT positions | `subtract`, `scurve`, `lowband` | Covered, benched (synthetic) |
| Ship engines and foghorns | Same, slow and long | AIS | `lowband` | Covered, benched (synthetic) |
| Buses, drones | Same | GTFS-RT, Remote ID | Same family | Expected covered, not benched |
| Mains hum (ENF) in audio | Recording time to the second, grid region | ENF archives | `hum`: both 50 and 60 Hz families notched, notches refilled | Covered |
| A defense's own fingerprint (notch pattern, imprinted lines) | Grid region | – | Both families notched and refilled at a static level; low-band noise shape smoothed over 1 ERB | Covered, tested (below) |
| Multi-mic phase | Direction of arrival | – | `mono` | Covered |
| Extra audio tracks (iPhone spatial audio, APAC, 4 channels) | Direction of arrival | – | Only the main track is read; the rest are dropped | Covered |
| Loudness envelope of a pass | Closest-approach time and d/v | Any of the tracks above | `lowband` smoothing and jitter (partial) | **Open:** no envelope attacker yet |
| Scheduled sounds (bells, horns, foghorns) | Time, plus rough distance from level and echo | Timetables | None | **Open** |
| Room and outdoor acoustics | Place type, not position | – | None | Out of scope |
| ENF as light flicker in video | Recording time, grid region | ENF archives | Optional de-flicker (re-encodes the picture) | Partly covered, see below |
| Picture, speech content, account history | Anything | – | None | Out of scope |

## Evidence

Synthetic clips, AAC 128 kbps round trip, both attackers: the blind tracker (6 dB threshold)
and the matched attacker with the true track plus two decoys. "Truth top N %" is where the true
location ranks on the attacker's map when nothing crosses the detection threshold (lower is
better; 50 % is chance). Low/high Δ are ERB loudness changes below and above 300 Hz.

| Clip | none | `hum+lowband` | `hum+subtract+lowband` | `hum+subtract+scurve+lowband` (default) |
| --- | --- | --- | --- | --- |
| Train, close (120 m) | leak z 12 | leak z 13 | no detection (10 %) | no detection (10 %) |
| Train, distant (900 m, 600 Hz) | leak z 77 | leak z 74 | **leak z 30** | no detection (28 %) |
| Ship (400 m) | leak z 79 | no detection | no detection | no detection |
| Aircraft, distant (5.8 km) | leak z 20 | – | no detection (13 %) | no detection (25 %) |
| Aircraft + speech | leak z 18 | – | no detection (29 %) | no detection (25 %) |
| Aircraft, close (1.5 km) | blind 1.5 km, z 16 | – | no detection (2 %) | no detection (2 %) |

Audio cost for the default: about 3 dB of low-band change (where texture is regenerated) and
0.2–0.4 dB above it. The close aircraft pass costs more (10 dB low, 1.2 dB high), because its
tones are strong and get cancelled. On the speech clip, 80 % of voice energy below 300 Hz is kept.

What this taught us:

- **Trains are the harder case**, not planes. Wheel and motor tones sit above the 300 Hz
  `lowband` cutoff, so regeneration alone never touches them. The blind `scurve` search catches
  what `subtract` misses, which is why it is now in the default chain.
- **Raising the cutoff is the wrong fix.** `lowband(cutoff=1000)` cleared the train clips but
  leaked the ship (z 10) and cost 0.8–1.1 dB above 300 Hz.
- On the close aircraft pass the truth ranks in the top 2 % without crossing the detection
  threshold. That's the thinnest margin in the table, and the first case to recheck on real
  recordings.
- More aircraft chains are in [harness/README.md](harness/README.md).

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
standard dynamic range, so it's opt-in.

Synthetic clips (20 s, testsrc2 scene, readout 50–70 % of the frame period), scan z (detection
above 60):

| Clip | Before | After removal |
| --- | --- | --- |
| 100 Hz bands, 3 % (rolling at 30 fps) | 426 | 32 |
| 120 Hz bands, 3 % (quasi-static) | 273 | 32 |
| 120 Hz bands, 1 % | 65 | 16 |
| No flicker | 36 (nothing removed) | – |
| Real iPhone clip, outdoors (IMG_9829) | 29 (nothing removed) | – |

Through the browser (decode, per-row gains in WebGL, re-encode), the saved file scanned at z 34
against 398 for the input.

## Known gaps

In order of how much we think they matter:

1. **No real ground truth yet.** Every number above is synthetic. Real clips with saved tracks
   are being collected.
2. **Loudness envelope attack.** A pass swells and fades over tens of seconds, and `lowband`'s
   0.75 s smoothing with ±1.5 dB jitter is probably not enough against a whole-envelope match.
   The matched attacker here doesn't use envelopes, so this is untested. Next step: add an
   envelope term, then measure.
3. **Scheduled sounds** are clocks. Removing them is a sound-event problem, not a DSP one, so a
   classifier is the likely route (detect and duck).
4. **Video-side ENF: quasi-static bands.** At 30 fps under 60 Hz lights, the 120 Hz bands barely
   move, and only their slow phase wander carries the clock. With real-grid wander (±0.05 Hz) that
   moving part is too faint to tell apart from a clean scene, so the scan doesn't flag it and
   nothing is removed. Rolling bands (50 Hz grids at 30 fps) and strong wander are found and
   removed (below).
5. **Unknown-time attacker.** We assume the attacker knows the recording time. Searching over the
   time offset would show how much the delay before posting buys.

## Guarantees

None. octave-camo **reduces** location leakage from sound. It doesn't remove it, and it can't
help if the picture, the words spoken or the account give the place away. A delay between
recording and posting is a free, real gain: every hour multiplies the tracks an attacker must
try.
