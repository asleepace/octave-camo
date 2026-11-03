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
  /** frames × bands, dB (mean power per band, lightly smoothed over time; for display, not calibration). */
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

// ---------- detail spectrogram (the 2D heatmap) ----------

/** Rows of the heatmap, log spaced over DETAIL_LO…DETAIL_HI: ~32 per octave, so a Doppler bend of a few percent reads as a curve, not a staircase. */
export const DETAIL_ROWS = 256;
export const DETAIL_LO = 30;
export const DETAIL_HI = 8_000;
/** Time columns at most (about the canvas width in device pixels); longer clips are max-pooled so short tones survive. */
export const DETAIL_MAX_COLUMNS = 2_400;

export type Detail = {
  /** columns × rows, dB, row 0 = lowest frequency. */
  db: Float32Array<ArrayBuffer>;
  columns: number;
  rows: number;
  /** Duration the columns span. */
  seconds: number;
  fLo: number;
  fHi: number;
};

/** Center of heatmap row r, Hz. */
export const detailHz = (d: Pick<Detail, "rows" | "fLo" | "fHi">, r: number) => d.fLo * (d.fHi / d.fLo) ** (r / (d.rows - 1));

export function detail(x: Float32Array, sampleRate: number): Detail {
  // ~100 ms windows: bins a few Hz wide, so mains hum and engine harmonics are thin lines.
  let n = 1;
  while (n < sampleRate * 0.1) n <<= 1;
  const fLo = DETAIL_LO, fHi = Math.min(DETAIL_HI, (sampleRate / 2) * 0.95), rows = DETAIL_ROWS;
  // Hop: a quarter window, but no more frames than twice the columns (pooling halves them anyway).
  const hop = Math.max(n >> 2, Math.ceil(x.length / (2 * DETAIL_MAX_COLUMNS)));
  const frames = Math.max(1, Math.ceil(x.length / hop));
  const columns = Math.min(frames, DETAIL_MAX_COLUMNS);
  const win = Float64Array.from({ length: n }, (_, i) => 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / n));
  const gain = 2 / win.reduce((s, w) => s + w, 0), binHz = sampleRate / n;

  // Row r covers the log axis halfway to its neighbors. Rows narrower than a bin interpolate
  // between bins; wider rows take their loudest bin (a tone stays a bright line, not a smear).
  const step = Math.sqrt(fHi / fLo) ** (1 / (rows - 1));
  const lo = new Int32Array(rows), hi = new Int32Array(rows), at = new Float64Array(rows);
  for (let r = 0; r < rows; r++) {
    const c = detailHz({ rows, fLo, fHi }, r);
    at[r] = c / binHz;
    lo[r] = Math.max(1, Math.ceil(c / step / binHz));
    hi[r] = Math.min(n / 2 - 1, Math.floor((c * step) / binHz));
  }

  const db = new Float32Array(columns * rows).fill(-240);
  const re = new Float64Array(n), im = new Float64Array(n), power = new Float64Array(n / 2 + 1);
  for (let f = 0; f < frames; f++) {
    const start = f * hop - n / 2;
    for (let i = 0; i < n; i++) {
      const j = start + i;
      re[i] = j >= 0 && j < x.length ? x[j]! * win[i]! : 0;
      im[i] = 0;
    }
    fft(re, im);
    for (let k = 0; k <= n / 2; k++) power[k] = (re[k]! * re[k]! + im[k]! * im[k]!) * gain * gain;
    const column = Math.min(columns - 1, Math.floor((f * columns) / frames)) * rows;
    for (let r = 0; r < rows; r++) {
      let p: number;
      if (hi[r]! > lo[r]!) {
        p = 0;
        for (let k = lo[r]!; k <= hi[r]!; k++) if (power[k]! > p) p = power[k]!;
      } else {
        const k = Math.min(n / 2 - 1, Math.floor(at[r]!)), u = at[r]! - k;
        p = power[k]! * (1 - u) + power[k + 1]! * u;
      }
      const v = 10 * Math.log10(p + 1e-12);
      if (v > db[column + r]!) db[column + r] = v;
    }
  }
  return { db, columns, rows, seconds: x.length / sampleRate, fLo, fHi };
}

/** dB at percentile q of a heatmap (for a color range shared by before and after). */
export function detailPercentile(d: Detail, q: number): number {
  const sample: number[] = [];
  const step = Math.max(1, Math.floor(d.db.length / 20_000));
  for (let i = 0; i < d.db.length; i += step) sample.push(d.db[i]!);
  sample.sort((a, b) => a - b);
  return sample[Math.min(sample.length - 1, Math.floor(q * sample.length))] ?? -60;
}

/**
 * The landing heatmap, before any file is dropped: a synthetic street (a passing plane with
 * harmonics, mains hum, two stretches of speech, noise) and an illustration of its cloaked
 * counterpart (plane and hum gone, speech and noise kept). Not engine output.
 */
export function demoDetail(): { input: Detail; output: Detail } {
  const sr = 16_000, seconds = 24, n = sr * seconds;
  const input = new Float32Array(n), output = new Float32Array(n);
  let seed = 11;
  const rand = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32);
  const c = 343, v = 95, d = 350, f0 = 96, t0 = 12;
  const speaking = (t: number) => ((t > 3 && t < 8) || (t > 16 && t < 21)) && Math.sin(t * 9.5) > -0.2;
  let phase = 0, voicePhase = 0, b0 = 0, b1 = 0, b2 = 0, l0 = 0, l1 = 0;
  for (let i = 0; i < n; i++) {
    const t = i / sr, dx = v * (t - t0), r = Math.hypot(dx, d);
    phase += (2 * Math.PI * f0) / (1 + (v * dx) / (r * c)) / sr;
    const level = 0.05 * Math.min(1, (d / r) ** 1.5);
    let plane = 0;
    for (let h = 1; h <= 9; h++) plane += (level / h ** 0.8) * Math.sin(h * phase + h);
    const hum = 0.006 * Math.sin(2 * Math.PI * 60 * t) + 0.003 * Math.sin(2 * Math.PI * 180 * t) + 0.002 * Math.sin(2 * Math.PI * 300 * t);
    const w = rand() - 0.5;
    b0 = 0.997 * b0 + 0.029 * w; b1 = 0.985 * b1 + 0.032 * w; b2 = 0.95 * b2 + 0.048 * w;
    const hiss = 0.05 * (b0 + b1 + b2 + 0.02 * w);
    l0 = 0.995 * l0 + 0.005 * (rand() - 0.5); l1 = 0.99 * l1 + 0.01 * l0;
    let voice = 0;
    if (speaking(t)) {
      const vf = 150 + 25 * Math.sin(t * 2.3) + 10 * Math.sin(t * 7);
      voicePhase += (2 * Math.PI * vf) / sr;
      for (let h = 1; h <= 20; h++) {
        const fh = h * vf;
        const formants = Math.exp(-(((fh - 600) / 250) ** 2)) + 0.6 * Math.exp(-(((fh - 1600) / 350) ** 2)) + 0.35 * Math.exp(-(((fh - 2700) / 400) ** 2));
        voice += 0.02 * formants * Math.sin(h * voicePhase);
      }
    }
    input[i] = plane + hum + hiss + 0.9 * l1 + voice;
    output[i] = hiss + 1.2 * l1 + voice;
  }
  return { input: detail(input, sr), output: detail(output, sr) };
}
