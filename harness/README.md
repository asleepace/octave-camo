# harness — attackers, defenses and ground truth for octave-camo

Uses a clip's own metadata (iPhone GPS ±5 m and recording time) plus the aircraft's ADS-B track
from OpenSky or Flightradar24 as ground truth. It then checks whether `octave-camo analyze`
recovered the closest approach from the audio alone, and whether `scrub` stops it.

```sh
cd harness
bun install
cp .env.example .env              # add OpenSky and/or Flightradar24 credentials
bun test                          # 88 tests, ~30 s: DSP, modules, attackers, CLI, API edge cases
bun run test:e2e                  # + offline end-to-end verify run (~2 min with the NumPy analyzer)
bun run verify clip.mov --callsign UAL1234 --scrub
```

## Recording a test clip

1. Record **60–90 s**, starting before the plane is loud and stopping after it fades. Keep the
   phone still (propped up), and avoid wind.
2. While recording, screenshot the plane in Flightradar24 to get its **callsign** or registration.
3. Send the original file (AirDrop or Files), **not** a copy re-shared through an app that strips
   metadata; the harness needs the GPS and time tags.

## Finding the aircraft

| Source | Needs | Area search | Lookback |
|---|---|---|---|
| `--source opensky` (default) | free API client (`OPENSKY_CLIENT_ID/SECRET`) | only within **1 hour** of recording | tracks up to 30 days |
| `--source fr24` | paid API token (`FR24_API_TOKEN`) | any time since 2016 | any |
| `--track FILE` | nothing | — | replays a saved or raw track |

- **More than an hour after recording, on OpenSky:** pass `--callsign` or `--icao24`.
- **Saving credits:** use `--save-track run.json` once, then `--track run.json` for every rerun.

## What it compares

| | Ground truth from the track | Tolerance | Why the truth is uncertain |
|---|---|---|---|
| distance | slant closest approach, including altitude | 10 % + 100 m | ADS-B altitude is barometric; weather shifts it about 100 m |
| t0 | closest approach as heard: emission time plus d/c | 2 s | QuickTime timestamps have 1 s resolution |
| speed | 3D speed at closest approach | 15 m/s | ADS-B gives ground speed; the audio sees airspeed (wind) |

**ATTACK WORKS** means both distance and t0 were within tolerance. With `--scrub`, it scrubs the
audio and attacks again at 10, 6 and 3 dB sensitivity. **SCRUB HELD** means none of those
recovered the flyby.

## Background aircraft: the matched attacker

The blind fitter (`verify`) needs a close pass with a full S-curve. A real attacker can do better
with faint, distant aircraft:

1. They pull ADS-B tracks for every aircraft in the area before the post time.
2. For each candidate phone location, they predict the pitch curve each aircraft would produce.
3. They sum spectrogram energy along that curve.

Integrating over the whole clip pulls out tones far below what a per-frame tracker can see.

```sh
bun run verify clip.mov --radius-km 30 --save-track tracks.json   # within 1 h of recording (OpenSky)
bun run matched clip.mov --track tracks.json --out clip.scrubbed.mp4
```

`matched` attacks the clip three times: the original audio, the audio after the standard scrub,
and the audio after **informed cancellation** plus the scrub. Informed cancellation is the defense
that uses the attacker's own advantage: the phone knows its true location and time, so it predicts
each aircraft's exact curve and cancels its tone and harmonics along it.

`bun run bench` measures all three on a synthetic distant jet (5.8 km slant, 150 m/s) at several
levels below the noise. Two decoy aircraft that aren't in the audio check for false detections.

### Notes on the matched attacker

- **It's greedy.** After each detection, that aircraft's path and harmonics are masked out before
  the rest are re-scored, so one loud plane can't make others look present.
- **One straight-flying aircraft can't tell sides apart.** A mirror image across its ground track
  scores the same, so the output reports the error for both the best peak and the nearest of the
  top 3. A second aircraft, or a curved track, resolves it.
- **It's given the exact recording time**, which is the best case for the attacker. Without
  metadata, they would also have to search over the time offset.

## Defenses (modular)

Defenses are modules you chain with `+`. Options go in parentheses, and every option is validated
with Zod, so a typo fails loudly. Run `bun run scrub --list` for the full list with defaults.

```sh
bun run scrub clip.mov out.mp4                          # default: hum+subtract+lowband (offline)
bun run scrub clip.mov out.wav --chain "hum+scurve+lowband"
bun run scrub clip.mov out.mp4 --chain "informed+lowband" --track tracks.json   # online
bun run bench:defenses                                  # compare chains on synthetic clips
```

| Module | Tier | Idea |
|---|---|---|
| `hum` | basic | Notch the mains harmonics. Removes the grid-frequency (ENF) clock. |
| `subtract` | basic | Track tones frame by frame and cancel them. Catches loud, close passes whose harmonics reach above `lowband`'s cutoff. |
| `lowband` | basic | Below `cutoff` (default 300 Hz), regenerate the band as noise matching each critical band's loudness, slowly smoothed and re-gained. Tracked voice harmonics are kept. `mode=highpass` just removes the band. |
| `scurve` | offline | Search the whole family of straight-flyby pitch curves (engine tone, speed, time scale, closest-approach time) with no flight data. Cancel the best candidates, erring toward over-cancelling. |
| `decoy` | experimental | Inject fake flyby curves just above the background in a 1 Hz band (a machine sees them) but far below it in a critical band (a listener doesn't). `mode=spoof` uses real tracks to fake a wrong location. |
| `informed` | online | Cancel each nearby aircraft along its exact curve at the true location. Needs `--track`. |
| `legacy` | basic | The original scrub: tracker subtraction plus pitch wobble. |

**Why `lowband` works without detecting anything.** The attacker follows a tone's pitch to about
0.5 Hz for tens of seconds. A listener hears background in critical bands about 35 Hz wide at
100 Hz. Regenerating the band keeps what you hear (loudness per band, slowly varying) and throws
away the fine structure the attacker integrates. Steady machine-like tones aren't mistaken for
voice: voiced runs that hold the same pitch for more than 1.5 s are treated as engines.

### Results (synthetic clips, after a 128 kbps AAC re-encode)

The attackers are the blind tracker (6 dB) and the matched attacker with ADS-B (the real track
plus 2 decoy tracks). A "leak" means the true location was recovered.

| Chain | Distant jet (5.8 km, −25 dB) | Same + speech | Close pass (1.5 km) | Low-band loudness change | Above 300 Hz |
|---|---|---|---|---|---|
| none | **leak** (0 m) | **leak** (0 m) | **leak** (both attackers) | 0 | 0 |
| `legacy` (old scrub) | **leak** | **leak** | safe | 2.5–12 dB | 0.5–1.5 dB |
| `hum+lowband` | safe | safe | **leak** (harmonics above the cutoff) | 3–3.5 dB | 0.2 dB |
| `hum+scurve` | **leak** | safe | **leak** | 1–7 dB | 0.2–0.6 dB |
| `hum+subtract+lowband` (default) | safe | safe | safe | 3–10 dB* | 0.2–1.2 dB |
| `informed+…` (online) | safe | safe | partial | | |

\* 10 dB on the close clip is mostly the plane itself being removed.

- **`scurve`** finds faint curves without flight data, but its 2 s windows are too coarse to
  cancel fast, close sweeps. Use it as an add-on for faint tones above `lowband`'s cutoff.
- **Random `decoy`s** made the matched attacker report a wrong place (7–12 km off) on the distant
  clips. Treat that as promising but unproven: a real attacker sees hundreds of flights and can
  notice inconsistent solutions.
- **Voice detail below 300 Hz**, measured as correlation with the clean voice: 96 % untouched,
  53 % with `keepVoice` (the default), 38 % without. Above 300 Hz, where intelligibility lives,
  nothing changes.

### Adding a module

1. Create `src/defense/<name>.ts` exporting `defineDefense({ name, summary, tier, options, create })`.
   `options` is a Zod object with defaults. `create` returns `{ process(x, ctx) }`, taking full-rate
   mono in and returning it out.
2. Add it to the list in `src/defense/index.ts`.

## Caveats

- **OpenSky's `/tracks` endpoint** is marked experimental and its waypoints can be sparse. The
  harness interpolates between them linearly, and flags gaps over 20 s at closest approach (⚠).
- **Flightradar24's `bounds` order** isn't documented anywhere I could confirm. The default is
  north,south,west,east. If an area search for a busy time comes back empty or 400s, set
  `FR24_BOUNDS_ORDER=swne`.
- **Analyzer.** The harness calls `../.build/release/octave-camo`. Until the Swift build is
  verified, set `OCTAVE_CAMO_CMD="python3 ../reference/analyze_json.py"` to use the NumPy
  reference, which speaks the same CLI and JSON.

## Layout

```
src/cli.ts              verify flow and output
src/clip.ts             ffprobe metadata (ISO 6709 location, creation time), audio extraction
src/geo.ts              WGS-84 → local east/north/up
src/track.ts            track interpolation, ground truth, predicted Doppler curve
src/sources/            opensky.ts, fr24.ts, file.ts (all responses validated with Zod)
src/analyzer.ts         runs the analyzer CLI and validates its JSON
src/matched.ts          matched attacker: whitened spectrogram, location grid, greedy masking
src/cancel.ts           informed cancellation along true-location curves
src/matched-cli.ts      before/after on a real clip
bench/distant.ts        synthetic distant-aircraft benchmark
src/report.ts           tolerances, comparison, printing
src/defense/            modular defenses: hum, lowband (+ pitch.ts), scurve (+ flyby.ts), decoy,
                        informed, legacy; index.ts = registry, chains; signal.ts = STFT/ERB helpers
src/quality.ts          what a defense costs: ERB-band loudness change, voice retention
src/scrub-cli.ts        apply a chain to a clip
bench/defenses.ts       chains × synthetic clips × both attackers, after an AAC re-encode
test/                   unit tests, fixtures, offline end-to-end test
```
