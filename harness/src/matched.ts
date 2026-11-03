/**
 * The stronger attacker: no blind curve fitting. Given real ADS-B tracks, predict the Doppler
 * pitch curve each aircraft would produce at every candidate phone location, then measure how
 * much energy the spectrogram has along that curve. Integrating along a predicted path over a
 * whole clip recovers tones far below what a per-frame tone tracker can detect, including the
 * slow, partial drift of distant background aircraft.
 */
import type { ClipInfo } from "./clip.ts";
import { fft, hann, median } from "./dsp.ts";
import { SPEED_OF_SOUND, type Vec3 } from "./geo.ts";
import { type FlightTrack, TrackPath } from "./track.ts";

export type MatchedConfig = {
  /** Analysis rate; aircraft tones that carry far are low (< ~700 Hz). */
  sampleRate: number;
  /** STFT window (samples) and hop: 8192 @ 4 kHz ≈ 2 s windows, 0.49 Hz bins, 0.5 s hop. */
  window: number;
  hop: number;
  /** Range of the unknown engine tone f0, Hz. */
  f0Range: [number, number];
  f0StepHz: number;
  /** Candidate phone locations: square grid around the search center. */
  radiusM: number;
  coarseStepM: number;
  fineStepM: number;
  /** A per-aircraft map counts as a detection when its peak z-score exceeds this. */
  detectionZ: number;
  /** After each detection, its path and this many harmonics are masked out before re-scoring. */
  harmonics: number;
  maskHalfWidthBins: number;
};

export const defaultMatchedConfig: MatchedConfig = {
  sampleRate: 4_000,
  window: 8_192,
  hop: 2_000,
  f0Range: [40, 700],
  f0StepHz: 0.5,
  radiusM: 10_000,
  coarseStepM: 1_000,
  fineStepM: 250,
  detectionZ: 7,
  harmonics: 4,
  maskHalfWidthBins: 2,
};

/** Log power, whitened per bin (removes steady tones and spectral tilt) and per frame (loudness). */
export type Spectrogram = { times: Float64Array; binHz: number; bins: number; data: Float32Array };

export function whitenedSpectrogram(x: Float32Array, cfg: MatchedConfig): Spectrogram {
  const { window: n, hop } = cfg;
  const binHz = cfg.sampleRate / n;
  const bins = Math.min(Math.ceil((cfg.f0Range[1] * 1.6) / binHz) + 2, n / 2);
  const frames = Math.max(0, Math.floor((x.length - n) / hop) + 1);
  const win = hann(n);
  const power = new Float64Array(frames * bins);
  const times = new Float64Array(frames);
  const re = new Float64Array(n), im = new Float64Array(n);

  for (let f = 0; f < frames; f++) {
    for (let i = 0; i < n; i++) { re[i] = x[f * hop + i]! * win[i]!; im[i] = 0; }
    fft(re, im);
    for (let k = 0; k < bins; k++) power[f * bins + k] = re[k]! ** 2 + im[k]! ** 2 + 1e-20;
    times[f] = (f * hop + n / 2) / cfg.sampleRate;
  }
  // Per-bin median over time, then per-frame median over frequency.
  const column = new Float64Array(frames);
  for (let k = 0; k < bins; k++) {
    for (let f = 0; f < frames; f++) column[f] = power[f * bins + k]!;
    const m = median(column);
    for (let f = 0; f < frames; f++) power[f * bins + k]! /= m;
  }
  const data = new Float32Array(frames * bins);
  const lo = Math.floor(cfg.f0Range[0] / binHz);
  for (let f = 0; f < frames; f++) {
    const row = power.subarray(f * bins + lo, (f + 1) * bins);
    const m = median(row);
    for (let k = 0; k < bins; k++) data[f * bins + k] = Math.log(power[f * bins + k]! / m);
  }
  return { times, binHz, bins, data };
}

export type Cell = { east: number; north: number };

/**
 * Doppler ratio f/f0 at each spectrogram frame for a phone at `offset` (ENU, m, relative to the
 * search center). NaN where the track has no data for the emission time.
 */
export function ratioCurve(path: TrackPath, clip: ClipInfo, times: Float64Array, offset: Cell): Float64Array {
  const out = new Float64Array(times.length);
  const o: Vec3 = [offset.east, offset.north, 0];
  for (let i = 0; i < times.length; i++) {
    const rx = clip.startTime + times[i]!;
    let tau = rx;
    for (let it = 0; it < 10; it++) {           // tau = rx − |p(tau) − o| / c  (contraction: v/c < 1)
      const p = path.at(tau);
      tau = rx - Math.hypot(p[0] - o[0], p[1] - o[1], p[2] - o[2]) / SPEED_OF_SOUND;
    }
    if (tau < path.start || tau > path.end) { out[i] = NaN; continue; }
    const p = path.at(tau), a = path.at(tau - 0.5), b = path.at(tau + 0.5);
    const d: Vec3 = [p[0] - o[0], p[1] - o[1], p[2] - o[2]];
    const r = Math.hypot(d[0], d[1], d[2]);
    const towardMic = -(d[0] * (b[0] - a[0]) + d[1] * (b[1] - a[1]) + d[2] * (b[2] - a[2])) / r;
    out[i] = 1 / (1 - towardMic / SPEED_OF_SOUND);
  }
  return out;
}

/** Best mean whitened log power along f0·ratio(t), maximized over the unknown f0. */
export function pathScore(spec: Spectrogram, ratio: Float64Array, cfg: MatchedConfig): { score: number; f0: number } {
  const valid: number[] = [];
  for (let i = 0; i < ratio.length; i++) if (Number.isFinite(ratio[i]!)) valid.push(i);
  if (valid.length < 8) return { score: -Infinity, f0: NaN };
  let best = -Infinity, bestF0 = NaN;
  for (let f0 = cfg.f0Range[0]; f0 <= cfg.f0Range[1]; f0 += cfg.f0StepHz) {
    let sum = 0;
    for (const i of valid) {
      const b = (f0 * ratio[i]!) / spec.binHz;
      const k = Math.floor(b);
      if (k < 1 || k + 1 >= spec.bins) { sum -= 1; continue; }
      const w = b - k, row = i * spec.bins;
      sum += (1 - w) * spec.data[row + k]! + w * spec.data[row + k + 1]!;
    }
    const score = sum / valid.length;
    if (score > best) { best = score; bestF0 = f0; }
  }
  return { score: best, f0: bestF0 };
}

export type ScoreMap = { cells: Cell[]; scores: Float64Array; f0: Float64Array };

export function scoreGrid(spec: Spectrogram, track: FlightTrack, clip: ClipInfo, cells: Cell[], cfg: MatchedConfig): ScoreMap {
  const path = new TrackPath(track, clip.location);
  const scores = new Float64Array(cells.length), f0 = new Float64Array(cells.length);
  cells.forEach((c, i) => {
    const s = pathScore(spec, ratioCurve(path, clip, spec.times, c), cfg);
    scores[i] = s.score; f0[i] = s.f0;
  });
  return { cells, scores, f0 };
}

export function squareGrid(center: Cell, radiusM: number, stepM: number): Cell[] {
  const cells: Cell[] = [];
  const n = Math.round(radiusM / stepM);
  for (let i = -n; i <= n; i++) for (let j = -n; j <= n; j++)
    cells.push({ east: center.east + i * stepM, north: center.north + j * stepM });
  return cells;
}

/** Robust z-scores: (x − median) / (1.4826 · MAD). */
export function zScores(x: Float64Array): Float64Array {
  const finite = Array.from(x).filter(Number.isFinite);
  const m = median(finite);
  const mad = median(finite.map((v) => Math.abs(v - m))) * 1.4826 || 1e-12;
  return x.map((v) => (Number.isFinite(v) ? (v - m) / mad : -Infinity));
}

export type Peak = Cell & { z: number };

/** Local maxima, strongest first, at least `separationM` apart. */
export function peaks(cells: Cell[], z: Float64Array, count: number, separationM: number): Peak[] {
  const order = Array.from(z.keys()).sort((a, b) => z[b]! - z[a]!);
  const out: Peak[] = [];
  for (const i of order) {
    const c = cells[i]!;
    if (out.every((p) => Math.hypot(p.east - c.east, p.north - c.north) >= separationM)) out.push({ ...c, z: z[i]! });
    if (out.length === count) break;
  }
  return out;
}

export type AircraftResult = {
  id: string;
  callsign?: string;
  detected: boolean;
  peakZ: number;
  f0: number;
  /** Strongest candidate locations (ENU m from the search center), after fine refinement. */
  peaks: Peak[];
  /** Percentile rank of the true location among coarse cells (100 = best). */
  truthPercentile: number;
};

export type MatchedResult = {
  aircraft: AircraftResult[];
  /** Combined over detected aircraft (sum of z-maps), coarse grid. */
  combined: Peak[];
  /** Distance from the best combined estimate to the true location, m (undefined if nothing detected). */
  errorM?: number;
  /**
   * Distance from the nearest of the top 3 combined peaks. One straight-flying aircraft leaves a
   * mirror ambiguity across its ground track; this is the error if the attacker resolves it
   * (a second aircraft, a curved track, or a map of where people could be).
   */
  ambiguityAwareErrorM?: number;
};

/** Zeroes (sets to the whitened median) the spectrogram along f0·ratio(t) and its harmonics. */
export function maskPath(spec: Spectrogram, ratio: Float64Array, f0: number, cfg: MatchedConfig): void {
  for (let i = 0; i < ratio.length; i++) {
    if (!Number.isFinite(ratio[i]!)) continue;
    for (let h = 1; h <= cfg.harmonics; h++) {
      const b = Math.round((h * f0 * ratio[i]!) / spec.binHz);
      for (let k = b - cfg.maskHalfWidthBins; k <= b + cfg.maskHalfWidthBins; k++)
        if (k >= 0 && k < spec.bins) spec.data[i * spec.bins + k] = 0;
    }
  }
}

function argmax(x: Float64Array): number {
  let best = 0;
  for (let i = 1; i < x.length; i++) if (x[i]! > x[best]!) best = i;
  return best;
}

/**
 * Greedy search (like radio astronomy's CLEAN): score every aircraft, take the most significant,
 * record it, mask its path and harmonics out of the spectrogram, and re-score the rest. Masking
 * stops one loud aircraft's harmonics from making other aircraft look detected.
 *
 * The grid is centered on the true location (from metadata) so results can be scored; a cell's
 * score never depends on where the grid is centered.
 */
export function matchedAttack(input: Spectrogram, tracks: FlightTrack[], clip: ClipInfo,
                              cfg: MatchedConfig = defaultMatchedConfig): MatchedResult {
  const spec: Spectrogram = { ...input, data: input.data.slice() };
  const coarse = squareGrid({ east: 0, north: 0 }, cfg.radiusM, cfg.coarseStepM);
  const truthIndex = coarse.findIndex((c) => c.east === 0 && c.north === 0);
  const combinedZ = new Float64Array(coarse.length);
  const results = new Map<string, AircraftResult>();

  const summarize = (track: FlightTrack, map: ScoreMap, z: Float64Array, detected: boolean): AircraftResult => {
    const best = argmax(z);
    const below = Array.from(z).filter((v) => v < z[truthIndex]!).length;
    return {
      id: track.id, callsign: track.callsign, detected,
      peakZ: z[best]!, f0: map.f0[best]!,
      peaks: peaks(coarse, z, 3, 1_500),
      truthPercentile: (100 * below) / Math.max(z.length - 1, 1),
    };
  };

  let candidates = tracks;
  while (candidates.length) {
    const scored = candidates.map((track) => {
      const map = scoreGrid(spec, track, clip, coarse, cfg);
      return { track, map, z: zScores(map.scores) };
    });
    for (const s of scored) results.set(s.track.id, summarize(s.track, s.map, s.z, false));
    scored.sort((a, b) => b.z[argmax(b.z)]! - a.z[argmax(a.z)]!);
    const top = scored[0]!;
    const bestCell = argmax(top.z);
    if (top.z[bestCell]! <= cfg.detectionZ) break;

    // Record the detection with a fine-grid refinement of its strongest peaks.
    const result = summarize(top.track, top.map, top.z, true);
    const finite = Array.from(top.map.scores).filter(Number.isFinite);
    const m = median(finite), mad = median(finite.map((v) => Math.abs(v - m))) * 1.4826 || 1e-12;
    result.peaks = result.peaks.map((p) => {
      const fine = squareGrid(p, cfg.coarseStepM, cfg.fineStepM);
      const fm = scoreGrid(spec, top.track, clip, fine, cfg);
      const bi = argmax(fm.scores);
      return { ...fine[bi]!, z: (fm.scores[bi]! - m) / mad };
    });
    results.set(top.track.id, result);
    for (let i = 0; i < combinedZ.length; i++) combinedZ[i]! += Number.isFinite(top.z[i]!) ? top.z[i]! : 0;

    const path = new TrackPath(top.track, clip.location);
    maskPath(spec, ratioCurve(path, clip, spec.times, coarse[bestCell]!), top.map.f0[bestCell]!, cfg);
    // Masking only removes energy, so only aircraft that were above threshold can still qualify.
    candidates = scored.slice(1).filter((s) => s.z[argmax(s.z)]! > cfg.detectionZ).map((s) => s.track);
  }

  const aircraft = tracks.map((t) => results.get(t.id)!);
  const combined = aircraft.some((a) => a.detected) ? peaks(coarse, combinedZ, 3, 1_500) : [];
  const dist = (p: Peak) => Math.hypot(p.east, p.north);
  // Prefer the refined peak of the strongest detection for the headline error.
  const strongest = aircraft.filter((a) => a.detected).sort((a, b) => b.peakZ - a.peakZ)[0];
  const headline = strongest?.peaks[0] ?? combined[0];
  return {
    aircraft,
    combined,
    errorM: headline ? dist(headline) : undefined,
    ambiguityAwareErrorM: strongest ? Math.min(...strongest.peaks.map(dist)) : undefined,
  };
}
