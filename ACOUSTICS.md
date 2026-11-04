# Acoustics: finding the tones that give a recording away

Design notes for the **check**: the attacker model behind the page's "what a tracker finds" table,
the spectrogram's outlines and the benchmark gate. It is the security boundary of the project.
Every defense is judged by it, so a check weaker than a real attacker makes the cloak look better
than it is. That is the one failure a privacy tool must not have.

This document collects the theory, the fields that have solved this problem before us, the ways it
goes wrong, and the plan. [PLAN.md](PLAN.md) has the order of work; [THREAT_MODEL.md](THREAT_MODEL.md)
has who the attacker is.

---

## 1. Where we are

The check (`FlybyAnalyzer`) is two detectors whose lines are merged:

- **The frame tracker** (`ToneTracker`) judges each frame on its own: 16,384-sample FFTs, a hop of
  2,048 samples, peaks a threshold above the local median floor, joined across frames into tracks
  of 2 s or more. Two ranges: 40 Hz–1 kHz (10 dB, ±2% matching; the cloak's tone subtraction uses
  this one too) and 1–8 kHz (15 dB, matching within 5% per second of drift, its own peak budget).
  It finds loud lines, including fast Doppler curves, and fits flybys to the curved ones.
- **The line integrator** (`LineIntegrator`, since slice 2) averages over seconds, as an attacker
  would (§3–4): a window close to 1 s at any sample rate, a 0.5 s hop, each frame divided by its
  local median floor; every path drifting up to 1 Hz/s over 3 s and 8 s spans must stand above τ in
  at least half its frames, with τ from the binomial tail for a false alarm budget over the whole
  search; lines must be narrow, and sidelobes are suppressed. Its lines are hum or steady, never
  Doppler. Where both find a line, the tracker's version is kept.

### Measured on synthetic scenes

`DetectionBaselineTests` records these in `Tests/OctaveCamoKitTests/Snapshots/detection.json`.
Strengths are dB over the noise in a 1 Hz band, so they mean the same at any sample rate. Runs (of
3 seeds) that found a steady 20 s tone:

| Tone | 6 dB | 9 dB | 12 dB | 15 dB | 20 dB | Before slice 2 |
|---|---:|---:|---:|---:|---:|---|
| 300 Hz at 16 kHz | 1/3 | 3/3 | 3/3 | 3/3 | 3/3 | found from 12 dB |
| 300 Hz at 48 kHz | 0/3 | 2/3 | 3/3 | 3/3 | 3/3 | found at 20 dB |
| 1.2 kHz at 16 kHz | 2/3 | 3/3 | 3/3 | 3/3 | 3/3 | found at 20 dB |
| 1.2 kHz at 48 kHz | 2/3 | 3/3 | 3/3 | 3/3 | 3/3 | **never** |
| 4.5 kHz at 48 kHz | 0/3 | 2/3 | 3/3 | 3/3 | 3/3 | **never** |

- **Grid harmonics with no fundamental**, 6 dB each: about 16 of 19 found as hum at 16 kHz, 2 at
  48 kHz (before: none); at 9 dB, about 15 at both rates (before: 9 at 16 kHz, none at 48 kHz).
- **Intermittent tones** (4 s on, 6 s off) at 15 dB: found at both rates (before: none at 48 kHz).
- **Drifting tones** (a flyby's curve) are still the weak spot: found at 20 dB in pieces covering
  14–17% of the pass, and at 12 dB not at all at 48 kHz. Curved paths are slice 3 (§4.4).
- **False lines: none** in white, pink, wind or traffic noise at either rate.
- **Not location clues, but lines:** singing and a whistled tune that repeats its notes show many;
  speech a few. Telling music and voices from machines is the risk classes' job (§5).

### Measured on real recordings

Two outdoor phone videos; only the tables and spectrograms are kept, never the audio.

- **Before slice 2,** a 90 s clip: a line near 1.2 kHz from 0:55 to 1:10, plain on the
  spectrogram, wasn't found (it stood perhaps 8–12 dB over loud ambience in any single frame, under
  the 15 dB rule); a faint 3.8 kHz line was found only in 2 s pieces.
- **With the integrator,** a 51 s clip with a plane, passing cars and light rain: 39 lines in the
  original, nearly all real on a whitened zoom (a wavering 45–50 Hz line, a V-shaped pass from 45 to
  95 Hz, a slowly rising 180 Hz line, car tones at 500–1,300 Hz, a steady 5 kHz whine). The frame
  tracker alone found 12.
- **The same clip after cloaking** (the decoded saved file): the page said "nothing left a tracker
  can follow"; the integrator found 19 lines. The low band was clean, but the car tones at
  500–950 Hz were untouched: inside tone subtraction's range, too faint for its frame tracker, so
  never targeted. So removal must target what the check finds, at every frequency (§8).

---

## 2. This is a solved problem, elsewhere

Finding a weak, narrow, possibly drifting tone in noise is old work in several fields:

- **Passive sonar (LOFAR).** "Low-frequency analysis and recording": spectrograms averaged over
  time, used to find the steady tones that a ship's machinery and propeller make (blade rate,
  shaft rate, their harmonics). That is our problem with a submarine instead of a plane. Sonar
  also pairs it with **DEMON**, the spectrum of the noise envelope, which finds propeller blade
  rates from broadband cavitation noise. That is relevant to helicopters and propeller planes.
- **Radio SETI: de-Doppler search.** A transmitter on a rotating planet drifts in frequency.
  Averaging frames smears a drifting line, so the search tries many drift rates: for each one it
  shifts each frame by that drift and adds them. **Taylor's tree algorithm** (from pulsar
  dedispersion) does all drift rates at once in about FFT cost. Breakthrough Listen's `turboSETI`
  is a public implementation.
- **Radar: track-before-detect (TBD).** Don't threshold each frame and then join the dots. Add up
  energy along candidate paths first, then decide. Dim targets that never clear a per-frame
  threshold are found this way. **Dynamic programming (Viterbi)** finds the best path through a
  time × frequency grid under a smoothness constraint (Barniv, 1985).
- **Radar: CFAR (constant false alarm rate).** Set the threshold from the false alarm rate you
  accept, using a local noise estimate. Ordered-statistic CFAR uses a rank (like our median)
  rather than a mean, so nearby targets don't inflate the floor (Rohling, 1983).
- **Audio forensics: ENF.** Forensic labs date recordings by the mains frequency's wander
  (Grigoras, 2005). Weak harmonics are **combined**: each harmonic's frequency is divided by its
  harmonic number and the spectra are summed. Many harmonics too weak to see alone become a clear
  trace together (Hajj-Ahmad, Garg & Wu, 2013).
- **Gravitational waves: continuous-wave searches.** These look for a faint, wandering tone from a
  spinning neutron star in years of noise. They use hidden-Markov / Viterbi tracking, the same idea
  as radar TBD (Suvorova et al., 2016).
- **Machine monitoring: order tracking.** Engine tones are followed by their relation to shaft
  speed, so a family of harmonics moves together. A plane's harmonics (and the grid's) do too.

**The lesson:** detect by *integration along a path*, with a threshold *derived* from the false
alarm rate, and treat *families* of harmonics as one source.

---

## 3. The statistics

### Averaging buys sensitivity

For pure noise, the power in one FFT bin is exponentially distributed. The mean of K independent
frames follows a Gamma distribution, which concentrates around the mean as K grows. A steady tone
stays where it is. So the threshold above the mean noise power, for a given false alarm
probability per test, falls with K:

| K independent frames | P = 10⁻⁴ | P = 10⁻⁶ | P = 10⁻⁸ |
|---:|---:|---:|---:|
| 1 | 9.6 dB | 11.4 dB | 12.7 dB |
| 4 | 6.0 dB | 7.3 dB | 8.2 dB |
| 8 | 4.6 dB | 5.6 dB | 6.4 dB |
| 16 | 3.4 dB | 4.3 dB | 4.9 dB |
| 32 | 2.5 dB | 3.2 dB | 3.7 dB |
| 64 | 1.9 dB | 2.3 dB | 2.7 dB |

(Thresholds are on power, relative to the noise mean; the median of one frame is 1.6 dB below it.)

So a 1.2 kHz line 8 dB over the ambience, invisible to a 15 dB per-frame rule, clears a
P = 10⁻⁸ threshold after 8 independent frames.

### Count the looks honestly

- **Overlapping frames aren't independent.** The tracker's frames overlap 87.5%. With a Hann
  window, the effective number of independent averages levels off at roughly twice
  (span / window length), however small the hop (Welch, 1967; Harris, 1978). Using the raw frame count would understate the
  false alarm rate several times over.
- **Multiple comparisons.** A minute of audio searched at ~1 Hz resolution from 40 Hz to 8 kHz,
  with a 0.25 s step and 25 drift rates, is about **5 × 10⁷ tests**. For 0.1 false lines per minute,
  each test needs P ≈ 2 × 10⁻⁹. That is the arithmetic the 15 dB rule did blind. Tests are
  correlated, so this is conservative; requiring a track to persist adds a second, independent
  margin.
- **Define it in physical units.** The window is set in samples today: about 1 s at 16 kHz and
  0.34 s at 48 kHz. Resolution, sensitivity and false alarms all depend on the sample rate. The
  detector should be specified in Hz of resolution and seconds of integration.

### How fast can a real source drift?

At closest approach a passing source's frequency changes fastest, at a fractional rate of about
v² / (c · d) for speed v, distance d and speed of sound c = 343 m/s:

| Source | Speed | Distance | Peak drift |
|---|---:|---:|---:|
| Jet at altitude | 120 m/s | 3 km | 1.4 %/s |
| Jet on approach | 100 m/s | 1 km | 2.9 %/s |
| Propeller plane | 60 m/s | 300 m | 3.5 %/s |
| Helicopter | 50 m/s | 200 m | 3.6 %/s |
| Train | 30 m/s | 50 m | 5.2 %/s |
| Car | 20 m/s | 10 m | 11.7 %/s |

A drift search over ±6 %/s covers aircraft and trains. Close cars sweep faster, but only for a
moment, and give little: the useful part of a car pass is short and loud, so per-frame detection
already finds it.

### The noise floor is an estimate

- A **median** floor is robust to a few lines, but it breaks near dense combs (music, hum families)
  and at band edges, and it lags steep slopes in coloured noise. Ordered-statistic CFAR with the
  cell under test and its neighbours excluded is the standard fix.
- **Digital silence** has a floor of −∞, so any dither becomes a "tone". The floor needs an
  absolute minimum.
- **A strong line leaks.** A Hann window's first sidelobe is −31 dB, so a tone 40 dB over the
  floor shows sidelobe "tones". A dominant peak should mask its own sidelobes.

---

## 4. The detector we want

Status: 1–3 are done (slice 2, `LineIntegrator`), in a simpler form than planned: drifts up to
1 Hz/s by brute force rather than ±6 %/s with a tree search, and a median (count) test rather than
CFAR on the mean, which keeps voices and recurring notes out at a cost of about 0.3 dB. Fast drifts
stay with the frame tracker until the path search (4). 4–6 are slice 3.

1. **A spectrogram in physical units:** about 1 Hz resolution (a ~1 s window) and a 0.25 s step,
   whatever the sample rate.
2. **Integration along drift:** over sliding spans of 2–4 s, sum frames along each drift rate in
   ±6 %/s, using a tree-structured (Taylor) search for speed. Sliding spans, not the whole clip,
   catch intermittent sources such as a compressor cycling.
3. **A derived threshold:** ordered-statistic CFAR on the integrated spectrum, with the threshold
   from the Gamma tail, the effective number of looks and the search size, for a stated budget of
   false lines per minute.
4. **Paths, not dots:** join detections with a Viterbi path search that limits how fast frequency
   may change, so curved Doppler paths and lines that fade in and out stay one track.
5. **Families:** combine 50 and 60 Hz harmonic families, normalised by harmonic number, into one
   grid-frequency trace per family. Test whether a high line drifts in proportion to the rest.
6. **Classify by risk** (section 5) and report each line's time, frequency path, strength and class.

The current tracker stays as it is for the cloak's tone subtraction. The new detector becomes the
check, and later feeds removal.

---

## 5. Not every line is the same risk

| Kind | What it reveals | Examples |
|---|---|---|
| **Moves like Doppler** | place and time, matched against ADS-B, AIS or rail positions | jet fan whine, propeller and rotor tones, tyre tread tones, train wheel squeal, drones |
| **Locked to the grid** | time, from the ENF record; and which grid (50 or 60 Hz, which interconnect) | hum and its high harmonics, lights buzzing at 100/120 Hz, transformers, switch-mode power supplies |
| **Steady, not grid-locked** | **that two videos were made in the same place** (a room fingerprint) | fridge, HVAC fan blade rate, computer fans, coil whine |
| **Musical or vocal** | usually nothing by itself | singing, instruments, held notes |

**Grid-locked lines at any frequency.** If a line's drift, divided by its frequency, matches the
hum family's drift divided by its own, the line is grid-locked, whatever its frequency. Phones
often cut the 50/60 Hz fundamental, so the grid may only show at 120, 180 … or 4,500 Hz. High
harmonics carry the grid's wander *magnified* by the harmonic number, which helps an attacker.

**Linkability is a separate threat.** A steady fridge tone reveals no location by itself, but it
can tie an anonymous video to a known one filmed in the same room. The page should say so rather
than call it harmless.

---

## 6. Sounds that aren't the scene

- **The codec.** Phone video audio is AAC.
  - At low bitrates, quantisation leaves spectral holes and short tonal artifacts ("birdies").
  - High-efficiency AAC (HE-AAC) uses spectral band replication: the encoder sends the low band and
    the decoder synthesises the top band by copying it up. The crossover is often between 5 and
    8 kHz, right at our edge. Copied harmonics can look like new high tones.
  - Encoding the cloak's output can add or hide lines. **The check must run on the decoded saved
    file**, as the picture's flicker check already does, not only on the cloak's float output.
- **The phone itself:** coil whine, the image-stabilisation motor, display refresh harmonics, and
  the 217 Hz buzz of GSM radios (TDMA bursts). They give no location, but they are a device
  fingerprint.
- **Things that move the floor:** wind gusts, automatic gain control pumping, clipping (which makes
  harmonics), handling noise.
- **Stereo to mono.** Content in opposite phase on the two channels cancels in the mix. The cloak
  outputs mono and the check analyses that same mono, so they agree. Keep it that way.

---

## 7. Clues outside this tool's reach

The cloak handles tones and the grid. These also date or place a recording, and the page should
say they exist:

- **Broadcasts:** a radio or TV in the background. Song recognition plus station playlists give
  the time to the minute.
- **Scheduled sounds:** church bells, the call to prayer, school bells, foghorns, timetabled trains.
- **Country-specific signals:** siren patterns, train horns, accessible pedestrian signals
  (crossing beeps and ticks), ring and dial tones.
- **Wildlife:** cicadas (4–7 kHz) and birds are regional and seasonal. A cricket's chirp rate gives
  the air temperature (Dolbear, 1897).
- **The room:** reverberation is a fingerprint of the space.
- **Language and accent.**

---

## 8. Removing what the check finds (step 2)

- **Every frequency, not only above 1 kHz.** On a real clip the faint car tones at 500–950 Hz
  survived the cloak because tone subtraction only removes what its own frame tracker sees (§1).

- **Fill, don't just subtract, above 1 kHz.** Replace a narrow strip around each track with noise at
  the local floor's level, crossfaded in time and frequency.
- **Strip width** must cover the track's uncertainty, the window's main lobe (±2 bins for Hann)
  and the drift within a frame. Strong lines also need their sidelobes and harmonics treated.
- **Check again on the decoded file,** and repeat for anything left.
- **Cloaking stays detectable.** Filled noise is statistically a little too clean, so someone could
  tell a clip was processed. That reveals nothing about place or time. Hiding the processing is not
  a goal, and THREAT_MODEL.md should say so.

---

## 9. How we'll know it works

- **Detection vs false alarms.** Plot the probability of detecting a tone against its strength,
  and false lines per minute on clue-free scenes, and choose the operating point deliberately.
  Target: under 0.1 false lines per minute, and detection by the strength at which a line is
  visible on the spectrogram (about 6 dB over ambience, sustained).
- **New test scenes:**
  - tones at a ladder of strengths (0–15 dB over the floor), steady and drifting;
  - an intermittent tone (on 4 s, off 6 s);
  - grid harmonics with no fundamental, each too weak alone;
  - noise only: white, pink, wind gusts, traffic;
  - music, speech, birdsong;
  - an AAC round trip at a low bitrate (web end-to-end, since Swift can't encode).
- **Attacker parity.** The benchmark gate and the behaviour snapshot use the new detector, so the
  cloak is scored by the strongest check we have.
- **Real clips** where available, kept private: report the table and spectrogram, never the audio.

---

## 10. Open questions

- **The operating point:** how many false lines per minute will users tolerate on the page before
  it stops meaning anything?
- **Music:** more sensitivity finds more held notes. Show them as "musical, low risk", hide them,
  or let the user decide?
- **Envelope attacks:** the loudness swell of a distant pass also carries its geometry
  (IDEAS.md). DEMON-style envelope spectra would catch propeller and rotor blade rates too.
- **Cost on long clips:** 5 minutes × 8 kHz × 25 drift rates, in a browser worker. The tree search
  should keep it near FFT cost, but it needs measuring.

---

## References

- Barniv, Y. (1985). Dynamic programming solution for detecting dim moving targets. *IEEE Trans.
  Aerospace and Electronic Systems*, 21(1).
- Dietz, M., Liljeryd, L., Kjörling, K. & Kunz, O. (2002). Spectral Band Replication, a novel
  approach in audio coding. *AES 112th Convention*.
- Dolbear, A. E. (1897). The cricket as a thermometer. *The American Naturalist*, 31.
- Enriquez, J. E. et al. (2017). The Breakthrough Listen search for intelligent life: 1.1–1.9 GHz
  observations of 692 nearby stars. *The Astrophysical Journal*, 849.
- Grigoras, C. (2005). Digital audio recording analysis: the electric network frequency criterion.
  *International Journal of Speech, Language and the Law*, 12(1).
- Hajj-Ahmad, A., Garg, R. & Wu, M. (2013). Spectrum combining for ENF signal estimation. *IEEE
  Signal Processing Letters*, 20(9).
- Harris, F. J. (1978). On the use of windows for harmonic analysis with the discrete Fourier
  transform. *Proceedings of the IEEE*, 66(1).
- Rohling, H. (1983). Radar CFAR thresholding in clutter and multiple target situations. *IEEE
  Trans. Aerospace and Electronic Systems*, 19(4).
- Suvorova, S. et al. (2016). Hidden Markov model tracking of continuous gravitational waves from a
  neutron star with wandering spin. *Physical Review D*, 93.
- Taylor, J. H. (1974). A sensitive method for detecting dispersed radio emission. *Astronomy and
  Astrophysics Supplement*, 15.
- Urick, R. J. (1983). *Principles of Underwater Sound* (3rd ed.). McGraw-Hill.
- Welch, P. D. (1967). The use of fast Fourier transform for the estimation of power spectra.
  *IEEE Trans. Audio and Electroacoustics*, 15(2).
