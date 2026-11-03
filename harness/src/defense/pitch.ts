/**
 * Voice pitch tracking (YIN, de Cheveigné & Kawahara 2002) used to keep voice harmonics while the
 * rest of the low band is regenerated. Machine tones are periodic too, so stretches that a voice
 * wouldn't produce are rejected (same rules as Swift's PitchTracker): an unbroken run longer than
 * speech makes, or a stretch joined across short gaps whose smoothed pitch is steady or moves one
 * way throughout (a Doppler glide).
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
  /** Machine-like (steady or one-way) stretches longer than this are rejected. */
  maxSteadyS: number;
  /** "Steady": the middle half of the stretch's pitches lies within this. */
  steadyCents: number;
  /** Unvoiced gaps up to this (or 2.5 query spacings) don't end a stretch. */
  maxGapS: number;
  /** Unbroken voiced runs longer than this are not speech. */
  maxRunS: number;
  /** A voiced frame joins a stretch if within this of the stretch's recent median pitch. */
  joinCents: number;
  /** |Kendall's τ| between time and pitch at or above this, over a real change, is a glide. */
  glideTau: number;
};

export const defaultPitchOptions: PitchOptions = {
  minHz: 70, maxHz: 400, threshold: 0.3, maxSteadyS: 1.5, steadyCents: 80, maxGapS: 0.3, maxRunS: 2, joinCents: 300, glideTau: 0.7,
};

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

const cents = (a: number, b: number) => 1200 * Math.log2(a / b);
const median = (v: number[]) => { const s = [...v].sort((a, b) => a - b); const m = s.length >> 1; return s.length % 2 ? s[m]! : (s[m - 1]! + s[m]!) / 2; };

/** Clears voiced stretches a voice wouldn't produce (see the module comment). */
function rejectSteadyRuns(f0: Float64Array, times: Float64Array, o: PitchOptions) {
  const reject = new Uint8Array(f0.length);
  // Unbroken runs.
  for (let start = 0; start < f0.length;) {
    if (f0[start] === 0) { start++; continue; }
    let end = start;
    while (end + 1 < f0.length && f0[end + 1]! > 0 && Math.abs(cents(f0[end + 1]!, f0[end]!)) < 100) end++;
    if (times[end]! - times[start]! > o.maxRunS) reject.fill(1, start, end + 1);
    start = end + 1;
  }
  // Stretches joined across short gaps (relative to the query spacing too). In noise the
  // estimator jitters by tens of cents, so membership compares against the stretch's recent
  // median, and the tests are rank- and quartile-based.
  const spacings: number[] = [];
  for (let i = 1; i < times.length; i++) if (times[i]! > times[i - 1]!) spacings.push(times[i]! - times[i - 1]!);
  const spacing = spacings.length ? median(spacings) : 0.05, maxGap = Math.max(o.maxGapS, 2.5 * spacing);
  let group: number[] = [];
  const judge = () => {
    const g = group;
    group = [];
    if (g.length < 5 || times[g.at(-1)!]! - times[g[0]!]! <= o.maxSteadyS) return;
    const c = g.map((i) => cents(f0[i]!, f0[g[0]!]!));
    // Steady: the middle half of the pitches lies within steadyCents.
    const sorted = [...c].sort((a, b) => a - b);
    const iqr = sorted[Math.floor(0.75 * (sorted.length - 1))]! - sorted[Math.floor(0.25 * (sorted.length - 1))]!;
    // Gliding: pitch ranks follow time ranks (Kendall's τ), and it moves by more than steadyCents.
    let concordant = 0, discordant = 0;
    for (let a = 0; a < c.length; a++) for (let b = a + 1; b < c.length; b++) {
      if (c[b]! > c[a]!) concordant++; else if (c[b]! < c[a]!) discordant++;
    }
    const tau = (concordant - discordant) / Math.max(1, (c.length * (c.length - 1)) / 2);
    const k = Math.max(1, Math.floor(c.length / 4));
    const change = Math.abs(median(c.slice(-k)) - median(c.slice(0, k)));
    if (iqr < o.steadyCents || (Math.abs(tau) >= o.glideTau && change >= o.steadyCents)) reject.fill(1, g[0]!, g.at(-1)! + 1);
  };
  for (let i = 0; i < f0.length; i++) {
    if (f0[i] === 0) continue;
    const previous = group.at(-1);
    const recent = group.length ? median(group.slice(-3).map((j) => f0[j]!)) : 0;
    if (previous !== undefined && (times[i]! - times[previous]! > maxGap || Math.abs(cents(f0[i]!, recent)) >= o.joinCents)) judge();
    group.push(i);
  }
  judge();
  for (let i = 0; i < f0.length; i++) if (reject[i]) f0[i] = 0;
}
