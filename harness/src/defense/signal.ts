/** Full-rate signal helpers shared by the defense modules. */
import { fft, hann } from "../dsp.ts";

/** Deterministic PRNG (mulberry32) with Gaussian draws. */
export class Rng {
  private s: number;
  constructor(seed: number) { this.s = seed >>> 0 || 1; }
  next(): number {
    let t = (this.s = (this.s + 0x6d2b79f5) >>> 0);
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4_294_967_296;
  }
  uniform(lo: number, hi: number) { return lo + (hi - lo) * this.next(); }
  gaussian(): number { return Math.sqrt(-2 * Math.log(this.next() + 1e-300)) * Math.cos(2 * Math.PI * this.next()); }
}

/** Integer-factor decimation with a windowed-sinc low-pass. Returns the new rate too. */
export function decimate(x: Float32Array, sampleRate: number, targetRate: number): { x: Float32Array; rate: number } {
  const factor = Math.max(1, Math.round(sampleRate / targetRate));
  if (factor === 1) return { x, rate: sampleRate };
  const taps = 16 * factor + 1, half = (taps - 1) / 2, cutoff = 0.45 / factor;
  const h = new Float64Array(taps);
  let sum = 0;
  for (let i = 0; i < taps; i++) {
    const k = i - half;
    const sinc = k === 0 ? 2 * cutoff : Math.sin(2 * Math.PI * cutoff * k) / (Math.PI * k);
    h[i] = sinc * (0.54 - 0.46 * Math.cos((2 * Math.PI * i) / (taps - 1)));
    sum += h[i]!;
  }
  for (let i = 0; i < taps; i++) h[i]! /= sum;
  const out = new Float32Array(Math.floor(x.length / factor));
  for (let o = 0; o < out.length; o++) {
    const c = o * factor;
    let acc = 0;
    for (let i = 0; i < taps; i++) {
      const j = c + i - half;
      if (j >= 0 && j < x.length) acc += h[i]! * x[j]!;
    }
    out[o] = acc;
  }
  return { x: out, rate: sampleRate / factor };
}

/**
 * Low-band STFT editing: analyze only bins 0..K-1 (Hann analysis and synthesis, 75 % overlap),
 * let the caller rewrite them, and add the change back. Untouched bins reconstruct exactly,
 * because the output is x + ISTFT(new − old).
 */
export class LowBandSTFT {
  readonly frames: number;
  readonly re: Float32Array;   // frames × K
  readonly im: Float32Array;
  private readonly pad: number;
  private readonly window: Float64Array;

  constructor(private readonly x: Float32Array, readonly size: number, readonly hop: number, readonly K: number) {
    this.pad = size;
    this.window = hann(size);
    this.frames = Math.floor((x.length + 2 * this.pad - size) / hop) + 1;
    this.re = new Float32Array(this.frames * K);
    this.im = new Float32Array(this.frames * K);
    const fr = new Float64Array(size), fi = new Float64Array(size);
    for (let m = 0; m < this.frames; m++) {
      this.loadFrame(m, fr, fi);
      fft(fr, fi);
      for (let k = 0; k < K; k++) { this.re[m * K + k] = fr[k]!; this.im[m * K + k] = fi[k]!; }
    }
  }

  /** Mean of window² over a frame: power scale of a random-phase frame relative to a windowed one. */
  get windowPower(): number { return this.window.reduce((a, w) => a + w * w, 0) / this.size; }
  /** Average Σw² overlap per sample (= size·windowPower / hop). */
  get overlapPower(): number { return (this.size * this.windowPower) / this.hop; }

  private loadFrame(m: number, re: Float64Array, im: Float64Array) {
    const start = m * this.hop - this.pad;
    for (let i = 0; i < this.size; i++) {
      const j = start + i;
      re[i] = j >= 0 && j < this.x.length ? this.x[j]! * this.window[i]! : 0;
      im[i] = 0;
    }
  }

  /** Synthesizes x + ISTFT(newBins − originalBins). */
  render(newRe: Float32Array, newIm: Float32Array): Float32Array {
    const { size, hop, K } = this;
    const total = this.x.length + 2 * this.pad;
    const acc = new Float64Array(total), norm = new Float64Array(total);
    const dr = new Float64Array(size), di = new Float64Array(size);
    for (let m = 0; m < this.frames; m++) {
      dr.fill(0); di.fill(0);
      let any = false;
      for (let k = 0; k < K; k++) {
        const a = newRe[m * K + k]! - this.re[m * K + k]!, b = newIm[m * K + k]! - this.im[m * K + k]!;
        if (a === 0 && b === 0) continue;
        any = true;
        // Inverse FFT via conj(FFT(conj(X))); keep Hermitian symmetry for a real result.
        dr[k] = a; di[k] = -b;
        if (k > 0) { dr[size - k] = a; di[size - k] = b; }
      }
      const start = m * hop;
      for (let i = 0; i < size; i++) norm[start + i]! += this.window[i]! ** 2;
      if (!any) continue;
      fft(dr, di);
      for (let i = 0; i < size; i++) acc[start + i]! += (dr[i]! / size) * this.window[i]!;
    }
    const out = Float32Array.from(this.x);
    for (let i = 0; i < out.length; i++) {
      const n = norm[i + this.pad]!;
      if (n > 1e-9) out[i]! += acc[i + this.pad]! / n;
    }
    return out;
  }
}

/** Equivalent rectangular bandwidth (Glasberg & Moore 1990), Hz. */
export const erb = (f: number) => 24.7 * (4.37 * f / 1000 + 1);
/** ERB-number scale and its inverse. */
export const erbNumber = (f: number) => 21.4 * Math.log10(1 + 0.00437 * f);
export const erbFrequency = (e: number) => (10 ** (e / 21.4) - 1) / 0.00437;

/** Band edges 1 ERB apart between lo and hi (inclusive ends). */
export function erbBands(lo: number, hi: number): number[] {
  const edges: number[] = [];
  for (let e = erbNumber(lo); e < erbNumber(hi); e += 1) edges.push(erbFrequency(e));
  edges.push(hi);
  return edges;
}

/** Centered moving average over `length` samples (zero-padded edges are excluded from the mean). */
export function smooth(x: Float64Array, length: number): Float64Array {
  if (length <= 1) return x.slice();
  const n = x.length, h = Math.floor(length / 2), pre = new Float64Array(n + 1), out = new Float64Array(n);
  for (let i = 0; i < n; i++) pre[i + 1] = pre[i]! + x[i]!;
  for (let i = 0; i < n; i++) {
    const lo = Math.max(0, i - h), hi = Math.min(n, i + h + 1);
    out[i] = (pre[hi]! - pre[lo]!) / (hi - lo);
  }
  return out;
}
