/**
 * Informed cancellation: the defense that uses the attacker's own advantage. The phone knows
 * exactly where and when it recorded, so it can fetch the same ADS-B tracks, predict each
 * aircraft's Doppler curve at the true location, find the engine tone along it, and cancel the
 * tone and its harmonics along exactly that curve. No pitch games, no audible drift.
 */
import type { ClipInfo } from "./clip.ts";
import { type MatchedConfig, type Spectrogram, defaultMatchedConfig, maskPath, pathScore, ratioCurve } from "./matched.ts";
import { median } from "./dsp.ts";
import { type FlightTrack, TrackPath } from "./track.ts";

export type CancelConfig = {
  harmonics: number;
  /** Amplitude low-pass length, s. The curve is predicted exactly, so this can be long: a narrow
   *  band (≈ ±1/length Hz) means little surrounding noise is removed, so no trough is left behind. */
  lowpassSeconds: number;
  /** Skip aircraft whose best tone along the true-location curve is weaker than this (robust z over f0). */
  minZ: number;
  /** Search the engine tone at a finer step than the attacker's grid, Hz. */
  f0RefineStepHz: number;
};

export const defaultCancelConfig: CancelConfig = { harmonics: 4, lowpassSeconds: 1.0, minZ: 4, f0RefineStepHz: 0.05 };

export type CancelReport = { id: string; callsign?: string; cancelled: boolean; f0: number; z: number };

/** Robust z of the best f0 against the score distribution over all f0 for one curve. */
function bestTone(spec: Spectrogram, ratio: Float64Array, cfg: MatchedConfig, refineStep: number) {
  const scores: number[] = [];
  for (let f0 = cfg.f0Range[0]; f0 <= cfg.f0Range[1]; f0 += cfg.f0StepHz) {
    scores.push(pathScore(spec, ratio, { ...cfg, f0Range: [f0, f0] }).score);
  }
  const coarse = pathScore(spec, ratio, cfg);
  const fine = pathScore(spec, ratio, { ...cfg, f0Range: [coarse.f0 - cfg.f0StepHz, coarse.f0 + cfg.f0StepHz], f0StepHz: refineStep });
  const m = median(scores), mad = median(scores.map((s) => Math.abs(s - m))) * 1.4826 || 1e-12;
  return { f0: fine.f0, z: (fine.score - m) / mad };
}

/** Box filter, centered, via prefix sums. */
function boxFilter(x: Float64Array, length: number): Float64Array {
  const n = x.length, h = (length - 1) >> 1, out = new Float64Array(n), pre = new Float64Array(n + 1);
  for (let i = 0; i < n; i++) pre[i + 1] = pre[i]! + x[i]!;
  for (let i = 0; i < n; i++) {
    const lo = Math.max(i - (length - 1) + h, 0), hi = Math.min(i + h, n - 1);
    out[i] = (pre[hi + 1]! - pre[lo]!) / length;
  }
  return out;
}

/** Heterodyne-and-subtract one tone with a known instantaneous frequency (Hz per sample). */
function cancelTone(y: Float32Array, freq: Float64Array, sampleRate: number, lowpass: number): void {
  const n = y.length, zr = new Float64Array(n), zi = new Float64Array(n), c = new Float64Array(n), s = new Float64Array(n);
  let phase = 0;
  for (let i = 0; i < n; i++) {
    phase += (2 * Math.PI * freq[i]!) / sampleRate;
    c[i] = Math.cos(phase); s[i] = Math.sin(phase);
    zr[i] = y[i]! * c[i]!; zi[i] = -y[i]! * s[i]!;
  }
  const L = Math.max(2, Math.round(lowpass * sampleRate));
  const ar = boxFilter(boxFilter(zr, L), L), ai = boxFilter(boxFilter(zi, L), L);
  for (let i = 0; i < n; i++) y[i]! -= 2 * (ar[i]! * c[i]! - ai[i]! * s[i]!);
}

/**
 * Cancels every aircraft found along its true-location curve, strongest first, masking each from
 * the analysis spectrogram so its harmonics aren't mistaken for another aircraft.
 * `audio` is full-rate mono and is modified in place.
 */
export function informedCancel(audio: Float32Array, sampleRate: number, analysis: Spectrogram,
                               tracks: FlightTrack[], clip: ClipInfo,
                               cfg: CancelConfig = defaultCancelConfig,
                               mcfg: MatchedConfig = defaultMatchedConfig): CancelReport[] {
  const spec: Spectrogram = { ...analysis, data: analysis.data.slice() };
  const here = { east: 0, north: 0 };
  const curves = tracks.map((t) => ({ track: t, path: new TrackPath(t, clip.location) }))
    .map((c) => ({ ...c, ratio: ratioCurve(c.path, clip, spec.times, here) }));
  const reports: CancelReport[] = [];
  let remaining = curves;
  while (remaining.length) {
    const ranked = remaining.map((c) => ({ c, tone: bestTone(spec, c.ratio, mcfg, cfg.f0RefineStepHz) }))
      .sort((a, b) => b.tone.z - a.tone.z);
    const { c, tone } = ranked[0]!;
    if (tone.z < cfg.minZ) {
      for (const r of ranked) reports.push({ id: r.c.track.id, callsign: r.c.track.callsign, cancelled: false, f0: r.tone.f0, z: r.tone.z });
      break;
    }
    // Full-rate ratio: compute on a 20 ms grid and interpolate.
    const step = 0.02, gridTimes = Float64Array.from({ length: Math.ceil(audio.length / sampleRate / step) + 2 }, (_, i) => i * step);
    const gridRatio = ratioCurve(c.path, clip, gridTimes, here);
    for (let h = 1; h <= cfg.harmonics; h++) {
      const freq = new Float64Array(audio.length);
      for (let i = 0; i < audio.length; i++) {
        const g = i / sampleRate / step, k = Math.floor(g), w = g - k;
        const r0 = gridRatio[k]!, r1 = gridRatio[Math.min(k + 1, gridRatio.length - 1)]!;
        const r = Number.isFinite(r0) && Number.isFinite(r1) ? r0 + w * (r1 - r0) : 1;
        freq[i] = h * tone.f0 * r;
      }
      cancelTone(audio, freq, sampleRate, cfg.lowpassSeconds);
    }
    maskPath(spec, c.ratio, tone.f0, mcfg);
    reports.push({ id: c.track.id, callsign: c.track.callsign, cancelled: true, f0: tone.f0, z: tone.z });
    remaining = ranked.slice(1).map((r) => r.c);
  }
  return reports;
}
