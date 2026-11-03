/**
 * Voice pitch tracking (YIN, de Cheveigné & Kawahara 2002) used to keep voice harmonics while the
 * rest of the low band is regenerated. Machine tones are periodic too, so voiced runs that hold a
 * nearly constant pitch for too long are rejected: speech moves, engines don't.
 */
import { decimate } from "./signal.ts";

export type PitchTrack = {
  /** f0 per query time, Hz; 0 = unvoiced. */
  f0: Float64Array;
};

export type PitchOptions = {
  minHz: number;
  maxHz: number;
  /** YIN aperiodicity threshold (lower = stricter). */
  threshold: number;
  /** Voiced runs longer than this with < `steadyCents` of pitch movement are not voice. */
  maxSteadyS: number;
  steadyCents: number;
};

export const defaultPitchOptions: PitchOptions = { minHz: 70, maxHz: 400, threshold: 0.3, maxSteadyS: 1.5, steadyCents: 30 };

export function trackPitch(x: Float32Array, sampleRate: number, times: Float64Array,
                           o: PitchOptions = defaultPitchOptions): PitchTrack {
  const { x: y, rate } = decimate(x, sampleRate, 8_000);
  const window = Math.round(0.04 * rate);               // 40 ms integration
  const maxLag = Math.ceil(rate / o.minHz), minLag = Math.floor(rate / o.maxHz);
  const d = new Float64Array(maxLag + 1);
  const f0 = new Float64Array(times.length);

  for (let q = 0; q < times.length; q++) {
    const start = Math.round(times[q]! * rate - window / 2);
    if (start < 0 || start + window + maxLag >= y.length) continue;
    let energy = 0;
    for (let i = 0; i < window; i++) energy += y[start + i]! ** 2;
    if (energy < 1e-10 * window) continue;
    // Difference function and its cumulative-mean normalization.
    let running = 0;
    d[0] = 1;
    for (let tau = 1; tau <= maxLag; tau++) {
      let s = 0;
      for (let i = 0; i < window; i++) { const e = y[start + i]! - y[start + i + tau]!; s += e * e; }
      running += s;
      d[tau] = running > 0 ? (s * tau) / running : 1;
    }
    let tau = -1;
    for (let t = minLag; t <= maxLag; t++) {
      if (d[t]! < o.threshold) {
        while (t + 1 <= maxLag && d[t + 1]! < d[t]!) t++;
        tau = t;
        break;
      }
    }
    if (tau < 0) continue;
    const a = d[tau - 1] ?? d[tau]!, b = d[tau]!, c = d[tau + 1] ?? d[tau]!;
    const den = a - 2 * b + c;
    const refined = den !== 0 ? tau + (0.5 * (a - c)) / den : tau;
    f0[q] = rate / refined;
  }
  rejectSteadyRuns(f0, times, o);
  return { f0 };
}

/** Clears voiced runs whose pitch barely moves for longer than maxSteadyS (machines, not people). */
function rejectSteadyRuns(f0: Float64Array, times: Float64Array, o: PitchOptions) {
  let start = 0;
  while (start < f0.length) {
    if (f0[start] === 0) { start++; continue; }
    let end = start;
    while (end + 1 < f0.length && f0[end + 1]! > 0 && Math.abs(1200 * Math.log2(f0[end + 1]! / f0[end]!)) < 100) end++;
    const span = times[end]! - times[start]!;
    if (span > o.maxSteadyS) {
      let lo = Infinity, hi = -Infinity;
      for (let i = start; i <= end; i++) { lo = Math.min(lo, f0[i]!); hi = Math.max(hi, f0[i]!); }
      if (1200 * Math.log2(hi / lo) < o.steadyCents) for (let i = start; i <= end; i++) f0[i] = 0;
    }
    start = end + 1;
  }
}
