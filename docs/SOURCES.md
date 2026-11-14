# Sources

Everything the project relies on or cites, in one place, so a claim can be traced back. Each entry
has a key to cite it by (`[Welch1967]`), where we use it, and how closely we've checked it:
**known** (a standard reference, cited for its well-known content, not re-read for this project),
**summary** (the paper or page fetched and summarised), **abstract** (abstract, project page or a
third-party summary only: check before quoting numbers), or **used** (a data service or tool we run).

Add new sources here when they're first cited. ACOUSTICS.md keeps its own short reference list for
reading in place; RESEARCH.md discusses the recent work.

## Signal processing

- **[Harris1978]** Harris, F. J. (1978). On the use of windows for harmonic analysis with the
  discrete Fourier transform. *Proceedings of the IEEE*, 66(1). — Hann main lobe and sidelobes
  (−31 dB), equivalent noise bandwidth: the line integrator's frame count, `lines` strip widths.
  ACOUSTICS.md §3. *known*
- **[Welch1967]** Welch, P. D. (1967). The use of fast Fourier transform for the estimation of
  power spectra. *IEEE Trans. Audio and Electroacoustics*, 15(2). — Averaging overlapping
  segments; why overlapping frames aren't independent. ACOUSTICS.md §3. *known*
- **[GlasbergMoore1990]** Glasberg, B. R. & Moore, B. C. J. (1990). Derivation of auditory filter
  shapes from notched-noise data. *Hearing Research*, 47. — The ERB scale behind low-band
  regeneration's bands (`ERB` in LowBandSTFT.swift; LowBandTests checks it). *known*
- **[deCheveigne2002]** de Cheveigné, A. & Kawahara, H. (2002). YIN, a fundamental frequency
  estimator for speech and music. *Journal of the Acoustical Society of America*, 111(4). — The
  pitch tracker that keeps voices in the low band and in `lines` (PitchTracker.swift). *known*
- **[Dietz2002]** Dietz, M., Liljeryd, L., Kjörling, K. & Kunz, O. (2002). Spectral Band
  Replication, a novel approach in audio coding. *AES 112th Convention*. — Why HE-AAC can create
  high-frequency content; the case for checking the saved file. ACOUSTICS.md. *known*

## Detecting faint lines

- **[Barniv1985]** Barniv, Y. (1985). Dynamic programming solution for detecting dim moving
  targets. *IEEE Trans. Aerospace and Electronic Systems*, 21(1). — Track-before-detect by dynamic
  programming: the idea behind E2's path search. ACOUSTICS.md, EXPERIMENTS.md. *known*
- **[Rohling1983]** Rohling, H. (1983). Radar CFAR thresholding in clutter and multiple target
  situations. *IEEE Trans. Aerospace and Electronic Systems*, 19(4). — Ordered-statistic CFAR: the
  line integrator's median-based threshold. ACOUSTICS.md. *known*
- **[Taylor1974]** Taylor, J. H. (1974). A sensitive method for detecting dispersed radio emission.
  *Astronomy and Astrophysics Supplement*, 15. — The tree algorithm for drift searches.
  ACOUSTICS.md. *known*
- **[Enriquez2017]** Enriquez, J. E. et al. (2017). The Breakthrough Listen search for intelligent
  life: 1.1–1.9 GHz observations of 692 nearby stars. *The Astrophysical Journal*, 849. —
  De-Doppler (drifting narrowband) search in practice. ACOUSTICS.md. *known*
- **[Suvorova2016]** Suvorova, S. et al. (2016). Hidden Markov model tracking of continuous
  gravitational waves from a neutron star with wandering spin. *Physical Review D*, 93. — HMM/Viterbi
  tracking of a wandering tone. ACOUSTICS.md. *known*
- **[Bayley2019]** Bayley, J., Messenger, C. & Woan, G. (2019). SOAP: A generalised application of
  the Viterbi algorithm to searches for continuous gravitational-wave signals. arXiv:1903.12614. —
  Viterbi on spectrograms, segment summing, a line-aware statistic: E2's closest relative.
  https://ar5iv.arxiv.org/html/1903.12614 — RESEARCH.md §5. *abstract*
- **[Urick1983]** Urick, R. J. (1983). *Principles of Underwater Sound* (3rd ed.). McGraw-Hill. —
  Passive sonar: machinery lines (LOFAR) and modulation (DEMON). ACOUSTICS.md. *known*

## Mains frequency (ENF)

- **[Grigoras2005]** Grigoras, C. (2005). Digital audio recording analysis: the electric network
  frequency criterion. *International Journal of Speech, Language and the Law*, 12(1). — ENF dating
  of recordings. ACOUSTICS.md, THREAT_MODEL.md. *known*
- **[HajjAhmad2013]** Hajj-Ahmad, A., Garg, R. & Wu, M. (2013). Spectrum combining for ENF signal
  estimation. *IEEE Signal Processing Letters*, 20(9). — Combining harmonics: why the hum notch
  covers whole harmonic families. ACOUSTICS.md. *known*
- **[Chuang2013]** Chuang, W.-H., Garg, R. & Wu, M. (2013). Anti-forensics and countermeasures of
  electrical network frequency analysis. *IEEE Trans. Information Forensics and Security*.
  doi:10.1109/TIFS.2013.2285515 — Removing ENF, and detecting that it was removed. RESEARCH.md §2.
  *abstract*
- **[Ngharamike2025]** Ngharamike, E., Ang, L.-M., Wang, M. & Seng, K. P. (2025). Intra-grid
  location estimation of smartphone videos using ENF extraction and an improved super-pixel
  technique. *Scientific Reports*, 15, 19614. https://pmc.ncbi.nlm.nih.gov/articles/PMC12137870 —
  ENF from video flicker as a *location* clue within a grid. RESEARCH.md §2. *summary*

## Locating recordings from sound

- **[LocUS2026]** IARPA. LocUS (Location Using Sound) programme. https://www.iarpa.gov/research-programs/locus
  — Funded audio-visual video geolocation. RESEARCH.md §1, THREAT_MODEL.md. *summary*
- **[NGA2020]** NGA Soundscapes competition (2020). Defense One:
  https://www.defenseone.com/technology/2020/10/nga-offers-cash-prizes-tech-can-identify-location-its-sound/169535/ ;
  C4ISRNET: https://c4isrnet.com/intel-geoint/2020/10/23/the-ambient-audio-in-your-video-could-give-away-its-location-this-intelligence-agency-wants-to-use-that
  — City from background sound. RESEARCH.md §1. *summary*
- **[Zhang2026]** Zhang, R., Liu, Z., Sun, L., Zhu, T. & Lv, W. (2026). The Sonar Moment:
  Benchmarking audio-language models in audio geo-localization. arXiv:2601.03227. Summary:
  https://ai-search.io/papers/the-sonar-moment-benchmarking-audio-language-models-in-audio-geo-localization
  — AGL1K; audio-language models geolocate, language dominates. RESEARCH.md §1. *abstract*
- **[Chasmai2025]** Chasmai, M., Liu, W., Maji, S. & Van Horn, G. (2025). Bioacoustic geolocation.
  arXiv:2505.18726. https://arxiv.org/abs/2505.18726v1 — Species ranges as a location signal.
  RESEARCH.md §1. *abstract*

- **[YT-UytYrhYLOKI]** YouTube video on geolocating a clip from aircraft Doppler, ~29 min
  (title and creator not yet recorded). https://www.youtube.com/watch?v=UytYrhYLOKI — The post
  that inspired this project. Method (2:37–20:57): one day of ADS-B for the continental US, jets
  removed (propeller aircraft only); a 200 m grid, each point's sound-delayed closest-approach
  times (slant distance, terrain from a DEM) to find where one plane is heard and another exactly
  920 s later; the audio's Doppler curves (the drop gives speed, its rate the closest distance);
  a silence filter (no other aircraft audible between the two); then each candidate's exact curve
  from the real, non-linear tracks, scored against the spectrogram with both events locked to one
  timeline. Located to ~100 m. Ending (26:09–29:12): a high-pass filter fails (the tones overlap
  the voice band, and an attenuated tone is recovered by boosting it), talking over it fails, and
  phone codecs and noise suppression leave the signature reconstructible; intentional cuts that
  break the time offset between events would help. RESEARCH.md §1, THREAT_MODEL.md, `lab/locate.py`.
  *abstract* (from a third-party summary of the transcript; the page couldn't be fetched here)

## Rooms and devices

- **[Moussa2024]** Moussa, D., Hirsch, G. & Riess, C. (2024). EnvId: a metric learning approach for
  forensic few-shot identification of unseen environments. arXiv:2405.02119 (IEEE TIFS 2025).
  https://ar5iv.labs.arxiv.org/html/2405.02119 — Rooms identified from reverberation. RESEARCH.md
  §3. *summary*
- **[RevRIR2024]** RevRIR: joint reverberant speech and room impulse response embedding using
  contrastive learning, with application to room shape classification. arXiv:2406.03120.
  https://arxiv.org/pdf/2406.03120 — RESEARCH.md §3. *abstract*
- **[Das2014]** Das, A., Borisov, N. & Caesar, M. (2014). Fingerprinting smart devices through
  embedded acoustic components. arXiv:1403.3366. https://arxiv.org/pdf/1403.3366.pdf — Microphones
  and speakers identify a device. RESEARCH.md §8. *abstract*

## Aircraft acoustics

- **[Downward2023]** Downward, B. & Nordby, J. (2023). The AeroSonicDB (YPAD-0523) dataset for
  acoustic detection and classification of aircraft. arXiv:2311.06368. https://arxiv.org/pdf/2311.06368
  — ADS-B-triggered aircraft recordings; a candidate test set (check the licence). RESEARCH.md §4.
  *summary*
- **[MartinRoman2014]** Martín Román, S.-R., Genescà Francitorra, M., Romeu Robert, J. & Arcos
  Villamarín, R. (2014). Passive acoustic method for aircraft states estimation based on the
  Doppler effect. *IEEE Trans. Aerospace and Electronic Systems*, 50(2), 1330–1346.
  doi:10.1109/TAES.2013.120176 — RESEARCH.md §4. *abstract*

## Audio privacy and generative filling

- **[Zhu2026]** Zhu, J. et al. (2026). IO-RAE: information-obfuscation reversible adversarial
  example for audio privacy protection. AAAI 2026; arXiv:2601.01239. https://arxiv.org/pdf/2601.01239
  — RESEARCH.md §6. *summary*
- **[VoicePrivacy2024]** The third VoicePrivacy challenge: preserving emotional expressiveness and
  linguistic content in voice anonymization. arXiv:2601.11846. https://arxiv.org/abs/2601.11846v1
  — RESEARCH.md §6. *abstract*
- **[Inpaint2023]** Diffusion-based audio inpainting. arXiv:2305.15266.
  https://arxiv.org/pdf/2305.15266 — RESEARCH.md §7. *abstract*
- **[TokenInpaint2025]** Token-based audio inpainting via discrete diffusion. arXiv:2507.08333.
  https://arxiv.org/html/2507.08333v4 — RESEARCH.md §7. *abstract*
- **[Moradi2025]** Moradi, M. & Gannot, S. (2025). Transient noise removal via diffusion-based
  speech inpainting. arXiv:2508.08890. https://arxiv.org/html/2508.08890 — RESEARCH.md §7.
  *summary*
- **[AppleExclaves2026]** Apple Security Research (2026, November 12). Secure Exclaves.
  https://security.apple.com/blog/secure-exclaves/ — Isolated runtimes for always-on camera and
  microphone processing; only narrow signals leave until a secure indicator shows. THREAT_MODEL.md
  "Related work". *summary*

## Natural history

- **[Dolbear1897]** Dolbear, A. E. (1897). The cricket as a thermometer. *The American Naturalist*,
  31. — Temperature from chirp rate: background sound carries weather. ACOUSTICS.md. *known*

## Data and services used in experiments

- **[adsb.lol]** adsb.lol: live aircraft near a point (`api.adsb.lol/v2/point/…`), each aircraft's
  trace for the day, and the `globe_history` archive (positions every 10 s, half-hour files). The
  attacker's data in the blind start-time search and the recorder app's polling. *used*
- **[Open-Meteo]** Open-Meteo forecast API (`api.open-meteo.com/v1/forecast`): temperature and wind
  at recording time, for the speed of sound. The recorder app. *used*
- Flightradar24 and FlightAware were allowed for the experiments; Flightradar24 refused automated
  requests (HTTP 403) and was left alone.

## Tools

- **[SwiftWasm]** Swift 6.4.2 with swift.org's WebAssembly SDK (`swift-6.4.2-RELEASE_wasm`): builds
  the scrubber. README "Development". *used*
- **[binaryen]** binaryen's `wasm-opt` (npm `binaryen` 131.0.0, pinned in `tools/wasm-opt`): shrinks
  release builds. *used*
- **[mediabunny]**, **[browser_wasi_shim]**: decoding and muxing in the browser; running the WASI
  module. `web/package.json`. *used*
- Apple platform documentation consulted for the recorder app (titles; check the links in Apple's
  developer site): "Capturing stereo audio from built-in microphones"; `AVCaptureDeviceInput
  .multichannelAudioMode` / `AVCaptureMultichannelAudioMode`; WWDC25 session 251 on spatial audio
  capture. *abstract*
