/** Log-frequency band spectrogram for the terrain and the band chart. */

export const F_LO = 20;
export const F_HI = 16_000;
export const BAND_COUNT = 96;
/** Seconds between frames (one terrain row). */
export const HOP_SECONDS = 0.05;

export type Spectrogram = {
  /** Band centers, Hz (log spaced, F_LO…F_HI). */
  centers: Float64Array;
  hop: number;
  frames: number;
  /** frames × bands, dB re full-scale sine. */
  db: Float32Array;
};

export const bandCenters = (count = BAND_COUNT) =>
  Float64Array.from({ length: count }, (_, i) => F_LO * (F_HI / F_LO) ** (i / (count - 1)));

/** Position of f on the log axis, 0…1. */
export const logX = (f: number) => Math.min(1, Math.max(0, Math.log(f / F_LO) / Math.log(F_HI / F_LO)));

export function mix(channels: Float32Array[]): Float32Array {
  if (channels.length === 1) return channels[0]!;
  const n = channels[0]!.length, out = new Float32Array(n);
  for (const ch of channels) for (let i = 0; i < n; i++) out[i]! += ch[i]!;
  for (let i = 0; i < n; i++) out[i]! /= channels.length;
  return out;
}

function fft(re: Float64Array, im: Float64Array): void {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) { [re[i], re[j]] = [re[j]!, re[i]!]; [im[i], im[j]] = [im[j]!, im[i]!]; }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const a = (-2 * Math.PI) / len, wr = Math.cos(a), wi = Math.sin(a);
    for (let i = 0; i < n; i += len) {
      let cr = 1, ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const p = i + k, q = p + len / 2;
        const tr = re[q]! * cr - im[q]! * ci, ti = re[q]! * ci + im[q]! * cr;
        re[q] = re[p]! - tr; im[q] = im[p]! - ti;
        re[p]! += tr; im[p]! += ti;
        const nr = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = nr;
      }
    }
  }
}

export function spectrogram(x: Float32Array, sampleRate: number): Spectrogram {
  // ~170 ms windows resolve the low band (where the leaks are) to a few Hz.
  let n = 1;
  while (n < sampleRate * 0.17) n <<= 1;
  const hop = Math.max(1, Math.round(sampleRate * HOP_SECONDS));
  const frames = Math.max(1, Math.floor(x.length / hop));
  const centers = bandCenters(), B = centers.length;
  const win = Float64Array.from({ length: n }, (_, i) => 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / n));
  const gain = 2 / win.reduce((s, w) => s + w, 0);
  const binHz = sampleRate / n, nyquist = sampleRate / 2;

  // Each band covers its share of the log axis; narrow low bands fall back to the nearest bin.
  const ratio = Math.sqrt(centers[1]! / centers[0]!);
  const lo = new Int32Array(B), hi = new Int32Array(B);
  for (let b = 0; b < B; b++) {
    const c = Math.min(centers[b]!, nyquist * 0.98);
    lo[b] = Math.max(1, Math.floor(c / ratio / binHz));
    hi[b] = Math.max(lo[b]!, Math.min(n / 2 - 1, Math.ceil((c * ratio) / binHz)));
  }

  const db = new Float32Array(frames * B);
  const re = new Float64Array(n), im = new Float64Array(n);
  const smoothed = new Float64Array(B);
  for (let f = 0; f < frames; f++) {
    const start = f * hop - n / 2;
    for (let i = 0; i < n; i++) {
      const j = start + i;
      re[i] = j >= 0 && j < x.length ? x[j]! * win[i]! : 0;
      im[i] = 0;
    }
    fft(re, im);
    for (let b = 0; b < B; b++) {
      // Mean power per band (a narrow tone still dominates its band), lightly smoothed over
      // time so noise reads as texture and tones as ridges.
      let p = 0;
      for (let k = lo[b]!; k <= hi[b]!; k++) p += re[k]! * re[k]! + im[k]! * im[k]!;
      p = (p / (hi[b]! - lo[b]! + 1)) * gain * gain;
      smoothed[b] = f ? 0.55 * smoothed[b]! + 0.45 * p : p;
      db[f * B + b] = 10 * Math.log10(smoothed[b]! + 1e-12);
    }
  }
  return { centers, hop: HOP_SECONDS, frames, db };
}

/** Long-term level per band (power mean), dB. */
export function meanBands(s: Spectrogram): Float32Array {
  const B = s.centers.length, out = new Float32Array(B);
  for (let b = 0; b < B; b++) {
    let p = 0;
    for (let f = 0; f < s.frames; f++) p += 10 ** (s.db[f * B + b]! / 10);
    out[b] = 10 * Math.log10(p / s.frames + 1e-12);
  }
  return out;
}

/** dB value at the given percentile over the whole spectrogram (for scaling the views). */
export function percentile(s: Spectrogram, q: number): number {
  const sample: number[] = [];
  const step = Math.max(1, Math.floor(s.db.length / 20_000));
  for (let i = 0; i < s.db.length; i += step) sample.push(s.db[i]!);
  sample.sort((a, b) => a - b);
  return sample[Math.min(sample.length - 1, Math.floor(q * sample.length))] ?? -60;
}

/**
 * A synthetic "street with a passing plane" for the landing view, before any file is dropped:
 * a Doppler S-curve with harmonics over rumble and hiss, and its cloaked counterpart.
 */
export function demo(seconds = 40): { input: Spectrogram; output: Spectrogram } {
  const centers = bandCenters(), B = centers.length, frames = Math.round(seconds / HOP_SECONDS);
  const input = new Float32Array(frames * B), output = new Float32Array(frames * B);
  let seed = 3;
  const rand = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32);
  const c = 343, v = 110, d = 900, f0 = 92;
  const bump = (lf: number, center: number, width: number) => Math.exp(-((lf - center) ** 2) / (2 * width * width));
  for (let f = 0; f < frames; f++) {
    const t = (f * HOP_SECONDS) % 26 - 13;           // a pass every 26 s
    const dx = v * t, r = Math.hypot(dx, d);
    const ratio = 1 / (1 + (v * dx) / (r * c));
    const level = Math.min(1, 2.2 * d / r);
    for (let b = 0; b < B; b++) {
      const fc = centers[b]!, lf = Math.log2(fc);
      const noise = (rand() - 0.5) * 4;
      const base = -78 + 18 * bump(lf, Math.log2(70), 1.3) + 9 * bump(lf, Math.log2(3_500), 1.2) + noise;
      let tone = -120;
      for (let h = 1; h <= 4; h++) {
        tone = Math.max(tone, -34 - 6 * h + 20 * Math.log10(level) - 900 * (Math.log2(fc / (h * f0 * ratio))) ** 2);
      }
      const hum = -52 - 1400 * Math.log2(fc / 60) ** 2;
      input[f * B + b] = Math.max(base, tone, hum);
      // Cloaked: tones and hum gone; the band keeps its overall texture.
      output[f * B + b] = fc < 300 ? -76 + 16 * bump(lf, Math.log2(70), 1.3) + noise * 0.6 : base;
    }
  }
  const make = (db: Float32Array): Spectrogram => ({ centers, hop: HOP_SECONDS, frames, db });
  return { input: make(input), output: make(output) };
}
