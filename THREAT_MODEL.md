# Threat model

What octave-camo defends against, what it doesn't, and the evidence for each claim.

## Setting

You post a video. Metadata is already stripped (most sites do this; octave-camo's remux also
drops it). Nothing in the picture gives the place away. The attacker wants **where** (and, as a
stepping stone, **when**) it was recorded, using only the published audio.

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
| Mains hum (ENF) in audio | Recording time to the second, grid region | ENF archives | `hum` notches | Covered |
| Multi-mic phase | Direction of arrival | – | `mono` | Covered |
| Loudness envelope of a pass | Closest-approach time and d/v | Any of the tracks above | `lowband` smoothing and jitter (partial) | **Open:** no envelope attacker yet |
| Scheduled sounds (bells, horns, foghorns) | Time, plus rough distance from level and echo | Timetables | None | **Open** |
| Room and outdoor acoustics | Place type, not position | – | None | Out of scope |
| ENF as light flicker in video | Recording time | ENF archives | None (video side) | **Open** |
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

Audio cost for the default: 2.8–2.9 dB low-band change (where texture is regenerated) and
0.2–0.4 dB above it.

What this taught us:

- **Trains are the harder case**, not planes. Wheel and motor tones sit above the 300 Hz
  `lowband` cutoff, so regeneration alone never touches them. The blind `scurve` search catches
  what `subtract` misses, which is why it is now in the default chain.
- **Raising the cutoff is the wrong fix.** `lowband(cutoff=1000)` cleared the train clips but
  leaked the ship (z 10) and cost 0.8–1.1 dB above 300 Hz.
- Aircraft results (distant jet, speech over a jet, close pass) are in
  [harness/README.md](harness/README.md).

## Known gaps

In order of how much we think they matter:

1. **No real ground truth yet.** Every number above is synthetic. Real clips with saved tracks
   are being collected.
2. **Loudness envelope attack.** A pass swells and fades over tens of seconds, and `lowband`'s
   0.75 s smoothing with ±1.5 dB jitter is probably not enough against a whole-envelope match.
   The next step is to add an envelope term to the matched attacker, then measure.
3. **Scheduled sounds** are clocks. Removing them is a sound-event problem, not a DSP one, so a
   classifier is the likely route (detect and duck).
4. **Video-side ENF** (rolling-shutter flicker bands) survives audio scrubbing.
5. **Unknown-time attacker.** We assume the attacker knows the recording time. Searching over the
   time offset would show how much the delay before posting buys.

## Guarantees

None. octave-camo **reduces** location leakage from sound. It doesn't remove it, and it can't
help if the picture, the words spoken or the account give the place away. A delay between
recording and posting is a free, real gain: every hour multiplies the tracks an attacker must
try.
