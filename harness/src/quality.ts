/**
 * Cheap perceptual proxies for "what did the defense cost?". Compares loudness per critical band
 * (ERB) over 250 ms frames, which is roughly what a listener hears of background sound.
 */
import { fft, hann } from "./dsp.ts";
import { erbBands } from "./defense/signal.ts";

/** dB per ERB band per frame. */
function bandEnvelopes(x: Float32Array, sampleRate: number, lo: number, hi: number) {
  const n = 8192, hop = Math.round(0.25 * sampleRate), w = hann(n), binHz = sampleRate / n;
  const edges = erbBands(lo, hi), B = edges.length - 1;
  const frames = Math.max(0, Math.floor((x.length - n) / hop) + 1);
  const out = Array.from({ length: frames }, () => new Float64Array(B));
  const re = new Float64Array(n), im = new Float64Array(n);
  for (let f = 0; f < frames; f++) {
    for (let i = 0; i < n; i++) { re[i] = x[f * hop + i]! * w[i]!; im[i] = 0; }
    fft(re, im);
    for (let b = 0; b < B; b++) {
      let e = 1e-20;
      for (let k = Math.ceil(edges[b]! / binHz); k < Math.ceil(edges[b + 1]! / binHz); k++) e += re[k]! ** 2 + im[k]! ** 2;
      out[f]![b] = 10 * Math.log10(e);
    }
  }
  return out;
}

/** Mean absolute loudness change in dB across bands and frames that have sound in the reference. */
export function loudnessChange(reference: Float32Array, processed: Float32Array, sampleRate: number, lo: number, hi: number): number {
  const a = bandEnvelopes(reference, sampleRate, lo, hi), b = bandEnvelopes(processed, sampleRate, lo, hi);
  const frames = Math.min(a.length, b.length);
  let sum = 0, count = 0;
  for (let f = 0; f < frames; f++) for (let k = 0; k < a[f]!.length; k++) {
    if (a[f]![k]! < -150) continue;
    sum += Math.abs(a[f]![k]! - b[f]![k]!); count++;
  }
  return count ? sum / count : 0;
}

/**
 * How much of a voice stem's low-frequency structure survived: correlation (0–1) between the
 * stem's and the output's magnitude spectra in [lo, hi] Hz, over frames where the voice is active.
 */
export function voiceRetention(voice: Float32Array, processed: Float32Array, sampleRate: number, lo = 80, hi = 300): number {
  const n = 4096, hop = 1024, w = hann(n), binHz = sampleRate / n;
  const k0 = Math.ceil(lo / binHz), k1 = Math.floor(hi / binHz);
  const frames = Math.floor((Math.min(voice.length, processed.length) - n) / hop) + 1;
  const vr = new Float64Array(n), vi = new Float64Array(n), pr = new Float64Array(n), pi = new Float64Array(n);
  const energies: number[] = [], rows: { v: number[]; p: number[] }[] = [];
  for (let f = 0; f < frames; f++) {
    for (let i = 0; i < n; i++) { vr[i] = voice[f * hop + i]! * w[i]!; vi[i] = 0; pr[i] = processed[f * hop + i]! * w[i]!; pi[i] = 0; }
    fft(vr, vi); fft(pr, pi);
    const v: number[] = [], p: number[] = [];
    let e = 0;
    for (let k = k0; k <= k1; k++) { v.push(Math.hypot(vr[k]!, vi[k]!)); p.push(Math.hypot(pr[k]!, pi[k]!)); e += v.at(-1)! ** 2; }
    energies.push(e); rows.push({ v, p });
  }
  // Voice-active frames: within 20 dB of the loudest voice frame.
  const threshold = Math.max(...energies) / 100;
  let sv = 0, sp = 0, svv = 0, spp = 0, svp = 0, m = 0;
  rows.forEach((r, f) => {
    if (energies[f]! < threshold || !(threshold > 0)) return;
    for (let i = 0; i < r.v.length; i++) {
      const a = r.v[i]!, b = r.p[i]!;
      sv += a; sp += b; svv += a * a; spp += b * b; svp += a * b; m++;
    }
  });
  if (!m) return NaN;
  const cov = svp / m - (sv / m) * (sp / m);
  return cov / Math.sqrt((svv / m - (sv / m) ** 2) * (spp / m - (sp / m) ** 2));
}
