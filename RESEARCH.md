# Research survey

Recent work on recovering where and when a recording was made, on hiding it, and on the signal
processing underneath, read for what it means for octave-camo. Surveyed November 2026; several
entries are summarised from abstracts and project pages only (marked), so check the papers before
leaning on a number. Experiments of our own are in [EXPERIMENTS.md](EXPERIMENTS.md).

## 1. The threat is real, funded and multimodal

- **IARPA LocUS ("Location Using Sound")**, solicited in 2026: geolocate previously unseen video
  clips, indoors and outdoors, "maximally leveraging audio and visual information", better than
  imagery alone, over search areas from neighbourhoods to continents. Proposers' day January 2026.
  This is a funded programme to build exactly the attacker we defend against.
- **NGA Soundscapes competition (2020):** machine learning to say which of several cities a
  recording came from, from non-speech background sound alone. Small prizes, but a clear signal of
  interest.
- **Audio-language models as geolocators** ("The Sonar Moment", January 2026, AGL1K: 1,444
  clips from 72 countries, 16 models; from the abstract): closed models clearly outperform open
  ones, and **spoken language often dominates the prediction**. The cheap attacker is now a chat
  window.
- **Bioacoustic geolocation** (Chasmai et al., 2025): species ranges make wildlife sound a
  location signal at country, state or city level; combining species range prediction with
  retrieval works best (from the abstract).

**For us:** the attacker who matters most may be one that fuses picture, speech and background,
not a lone Doppler fitter. Our scope stays the background, but the page should say plainly that
voices, language and the picture are outside it. And birdsong, which we treat as harmless (it's no
Doppler or hum clue), is a *region and season* clue: worth a line in the threat model and the
"outside this tool's reach" note.

## 2. Mains frequency (ENF) keeps getting stronger

- **Intra-grid location from smartphone video** (Ngharamike et al., Scientific Reports, 2025):
  ENF extracted from the flicker of indoor lighting in phone videos (rolling-shutter CMOS, about
  30 fps, aliasing handled), correlated with recordings from 12 substations, then triangulated:
  better at a region than a point, but it narrows *where within the grid*, not just when.
- **ENF anti-forensics and their countermeasures** (Chuang, Garg and Wu, IEEE TIFS 2013, and
  follow-ups): removing or replacing ENF is possible, and so is detecting that it was removed.

**For us:** light-flicker removal matters even more than we thought (it's a location clue, not
only a clock). And our hum notch + refill should be checked against the countermeasure side: does
the cloaked file show the signature of "ENF removed"? The README already says a cloaked file is
recognisable as processed; this would say so specifically.

## 3. Rooms are identifiable

- **EnvId** (Moussa, Hirsch and Riess, 2024; TIFS 2025): few-shot identification of *unseen*
  recording environments from reverberation, by metric learning. 10-way accuracy 0.81–0.96 across
  four room-impulse-response sets; 0.92 after double compression; 0.76 at 0 dB SNR with unseen
  real noise.
- **RevRIR** (2024): joint embeddings of reverberant speech and room impulse responses, used to
  classify room shape.

**For us:** linking two videos to the same room is a practical attack, robust to compression. Our
room-fingerprint observation (the same steady lines in every recording from one room) is one half;
the reverberation is the other. Ideas: the "unlink" option (remove a room's steady lines) and,
harder, randomising the apparent reverberation (dereverberate, then add a different synthetic
room). Measure with an EnvId-style embedding before and after.

## 4. Aircraft acoustics

- **AeroSonicDB (YPAD-0523)** (Downward and Nordby, 2023): 12.4 h of audio, 625 aircraft
  recordings from 301 aircraft, recorded on demand when ADS-B showed a plane within 1–3 km and
  "silence" only when none was within 10 km; 22.05 kHz. CNNs on MFCCs reach 99 % mean average
  precision on held-out sessions but 91 % on realistic urban soundscapes. It's our recorder app's
  idea, done as a public dataset: a source of labelled passes for testing the check (check its
  licence first).
- **Passive Doppler state estimation** (Martín Román et al., IEEE TAES 2014; abstract): seven or
  more microphones around an airport, relative Doppler shifts, position and speed solved to about
  the size of an aircraft (in simulation).

**For us:** the field mostly does *detection* ("is there a plane?") with ML, or localisation with
arrays. A single phone recording matched against ADS-B, which is our threat, gets little academic
attention; our known-path attacker (E4) may be closer to the front than the literature.

## 5. Finding faint lines: SOAP

- **SOAP** (Bayley, Messenger and Woan, 2019): the Viterbi algorithm for continuous gravitational
  waves. Each spectrogram bin is a state, tracks move at most one bin per step, power from short
  segments is summed to raise SNR, and the search runs on a **line-aware statistic**: the log-odds
  of *signal* against *noise or an instrumental line* (power in one detector but not the other).
  Orders of magnitude cheaper than template banks, at a modest loss of sensitivity, and model-free.
  Later work adds a CNN to vet the tracks Viterbi finds.

**For us:** independent confirmation that E2's design is the right family. Things to borrow:
- the line-aware statistic (our running-median whitening does the same job: a steady line is
  "instrumental"; we could make it explicit as a three-way model);
- summing short segments before the search (E1 showed 0.13–0.26 s windows are right; summing a few
  of them gives a cheaper, smoother state space);
- a learned veto on Viterbi tracks: the natural first ML piece, judging "plane, voice, music or
  room" for each path.

## 6. Privacy defences in audio

- **IO-RAE** (AAAI 2026): reversible adversarial examples that make speech recognisers transcribe
  chosen wrong words for sensitive keywords (96 % targeted success, 100 % untargeted; transfers to
  Whisper and others and to Google's API), while an authorised holder can remove the perturbation.
- **The third VoicePrivacy challenge** (2024; preprint January 2026): anonymising a speaker's voice
  while keeping words and emotion.

**For us:** adversarial perturbations are effective against a *specific learned model* and
fragile against others; a physics attacker (Doppler, ENF) isn't fooled by them, so they don't
replace removal. They could complement it against learned geolocators (the audio-language models
above), which is an open question nobody seems to have published on. Voice anonymisation is a
natural partner for an "aggressive mode", not something to build ourselves.

## 7. Generative filling

- **Diffusion audio inpainting** (2023 onward), **token-based inpainting via discrete diffusion**
  (2025), and **phoneme-guided diffusion inpainting** of speech hidden by door slams or hammer
  strikes (Moradi and Gannot, 2025: word error falls from about 40 % to 5 % with phoneme guidance
  for 1 s gaps).

**For us:** where we fill with noise today (the low band, the strips around removed lines),
generative fill could sound more natural. Cautions: it mustn't invent new clues (a generated
engine, a generated hum), its texture may itself be detectable, and it's heavy for a browser.
Later, and only behind the same check.

## 8. Device fingerprints

- Phones' microphones and speakers have individual frequency responses that identify a device from
  its recordings (Das, Borisov and Caesar, 2014, and later work).

**For us:** out of scope for location, but it links videos to one phone. Our mono re-encode and
regenerated low band blur some of it; the rest of the response is untouched. A line in the threat
model.

## What to take from this

1. **Add to the threat model:** fused audio-visual geolocation (LocUS), audio-language models,
   bioacoustics as a region/season clue, ENF as a *location* clue within a grid, room
   reverberation (EnvId), device fingerprints. Most are outside the tool's reach; the page should
   say so.
2. **The check:** E2 is in the SOAP family; borrow its line-aware statistic, segment summing, and
   a learned veto later.
3. **Tests and data:** AeroSonicDB as labelled real passes (licence permitting), alongside the
   recorder sessions; an EnvId-style room embedding to measure "unlinking".
4. **Open ground:** defending video audio against geolocation (rather than speech content) seems
   unpublished, and matching one phone recording against ADS-B gets little attention. Both are
   where this project already works.

## Sources

Every source here is also in [SOURCES.md](SOURCES.md), the project's bibliography, with a key to cite it by.


- IARPA, LocUS: https://www.iarpa.gov/research-programs/locus
- Defense One, "Mapping Agency Wants to ID Locations by Sound" (2020): https://www.defenseone.com/technology/2020/10/nga-offers-cash-prizes-tech-can-identify-location-its-sound/169535/
- C4ISRNET, "The ambient audio in your video could give away its location" (2020): https://c4isrnet.com/intel-geoint/2020/10/23/the-ambient-audio-in-your-video-could-give-away-its-location-this-intelligence-agency-wants-to-use-that
- Zhang et al., "The Sonar Moment: Benchmarking Audio-Language Models in Audio Geo-Localization" (arXiv 2601.03227, 2026), summary: https://ai-search.io/papers/the-sonar-moment-benchmarking-audio-language-models-in-audio-geo-localization
- Chasmai et al., bioacoustic geolocation (arXiv 2505.18726, 2025): https://arxiv.org/abs/2505.18726v1
- Ngharamike et al., intra-grid location of smartphone videos using ENF (Scientific Reports, 2025): https://pmc.ncbi.nlm.nih.gov/articles/PMC12137870
- Chuang, Garg and Wu, "Anti-Forensics and Countermeasures of Electrical Network Frequency Analysis" (IEEE TIFS, 2013): https://unpaywall.org/10.1109%2FTIFS.2013.2285515
- Moussa, Hirsch and Riess, EnvId (arXiv 2405.02119, 2024): https://ar5iv.labs.arxiv.org/html/2405.02119
- RevRIR (arXiv 2406.03120, 2024): https://arxiv.org/pdf/2406.03120
- Downward and Nordby, AeroSonicDB (arXiv 2311.06368, 2023): https://arxiv.org/pdf/2311.06368
- Martín Román et al., passive acoustic aircraft states estimation (IEEE TAES, 2014): https://upcommons.upc.edu/entities/publication/9ae18a41-e532-4d46-95ea-581283c44d9e
- Bayley, Messenger and Woan, SOAP (arXiv 1903.12614, 2019): https://ar5iv.arxiv.org/html/1903.12614
- Zhu et al., IO-RAE (AAAI 2026; arXiv 2601.01239): https://arxiv.org/pdf/2601.01239
- The third VoicePrivacy challenge (arXiv 2601.11846, 2026): https://arxiv.org/abs/2601.11846v1
- Diffusion-based audio inpainting (arXiv 2305.15266): https://arxiv.org/pdf/2305.15266
- Token-based audio inpainting via discrete diffusion (arXiv 2507.08333): https://arxiv.org/html/2507.08333v4
- Moradi and Gannot, transient noise removal via diffusion-based speech inpainting (arXiv 2508.08890): https://arxiv.org/html/2508.08890
- Das, Borisov and Caesar, "Fingerprinting Smart Devices Through Embedded Acoustic Components" (arXiv 1403.3366, 2014): https://arxiv.org/pdf/1403.3366.pdf
