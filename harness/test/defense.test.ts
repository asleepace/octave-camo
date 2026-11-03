import { describe, expect, test } from "bun:test";
import { parseChain, runChain } from "../src/defense/index.ts";
import { flybyRatio, perSampleFrequency } from "../src/defense/flyby.ts";
import { trackPitch } from "../src/defense/pitch.ts";
import { LowBandSTFT, Rng } from "../src/defense/signal.ts";
import type { DefenseContext } from "../src/defense/types.ts";
import { ratioCurve } from "../src/matched.ts";
import { fft, median } from "../src/dsp.ts";
import { TrackPath } from "../src/track.ts";
import { clipInfo, straightTrack } from "./helpers.ts";

const SR = 16_000;
const ctx = (extra: Partial<DefenseContext> = {}): DefenseContext => ({ sampleRate: SR, seed: 1, log: () => {}, ...extra });

function noise(n: number, rms: number, seed = 3): Float32Array {
  const r = new Rng(seed), x = new Float32Array(n);
  for (let i = 0; i < n; i++) x[i] = rms * r.gaussian();
  return x;
}
function addTone(x: Float32Array, freq: (i: number) => number, amp: number) {
  let p = 0;
  for (let i = 0; i < x.length; i++) { p += (2 * Math.PI * freq(i)) / SR; x[i]! += amp * Math.sin(p); }
}
/** Amplitude of a tone with known instantaneous frequency (coherent projection). */
function toneAmplitude(x: Float32Array, freq: (i: number) => number): number {
  let p = 0, s = 0, c = 0;
  for (let i = 0; i < x.length; i++) { p += (2 * Math.PI * freq(i)) / SR; s += x[i]! * Math.sin(p); c += x[i]! * Math.cos(p); }
  return (2 * Math.hypot(s, c)) / x.length;
}
function bandRms(x: Float32Array, lo: number, hi: number): number {
  const n = 1 << Math.floor(Math.log2(x.length)), re = new Float64Array(n), im = new Float64Array(n);
  for (let i = 0; i < n; i++) re[i] = x[i]!;
  fft(re, im);
  let e = 0;
  for (let k = Math.ceil((lo * n) / SR); k <= Math.floor((hi * n) / SR); k++) e += re[k]! ** 2 + im[k]! ** 2;
  return Math.sqrt((2 * e) / (n * n));
}
const db = (a: number, b: number) => 20 * Math.log10(a / b);

describe("STFT editing", () => {
  test("unchanged bins reconstruct the input exactly", () => {
    const x = noise(SR * 3, 0.1);
    const s = new LowBandSTFT(x, 2048, 512, 40);
    const y = s.render(s.re.slice(), s.im.slice());
    let err = 0;
    for (let i = 0; i < x.length; i++) err = Math.max(err, Math.abs(x[i]! - y[i]!));
    expect(err).toBeLessThan(1e-6);
  });
});

describe("lowband", () => {
  const n = SR * 20;
  const tone = (i: number) => 100 + 2 * Math.sin((2 * Math.PI * i) / SR / 7); // slow drift, like a distant plane

  test("highpass removes a 100 Hz tone and keeps 1 kHz", async () => {
    const x = new Float32Array(n);
    addTone(x, tone, 0.1); addTone(x, () => 1000, 0.1);
    const y = await runChain(parseChain("lowband(mode=highpass)"), x, ctx());
    expect(toneAmplitude(y, tone)).toBeLessThan(0.002);
    expect(toneAmplitude(y, () => 1000)).toBeCloseTo(0.1, 2);
  });

  test("regenerate keeps low-band loudness but destroys the tone's fine structure", async () => {
    const x = noise(n, 0.05);
    addTone(x, tone, 0.05);
    const y = await runChain(parseChain("lowband(keepVoice=false,jitterDb=0)"), x, ctx());
    expect(Math.abs(db(bandRms(y, 30, 220), bandRms(x, 30, 220)))).toBeLessThan(1.5);
    expect(db(toneAmplitude(y, tone), toneAmplitude(x, tone))).toBeLessThan(-15);
    expect(Math.abs(db(bandRms(y, 500, 4000), bandRms(x, 500, 4000)))).toBeLessThan(0.05);
  });
});

describe("pitch tracking", () => {
  const times = Float64Array.from({ length: 80 }, (_, i) => 0.5 + i * 0.05);

  test("keeps a voice: syllables at changing pitches, with intonation and jitter", () => {
    const n = SR * 5, x = noise(n, 0.002), f = new Float64Array(n), rng = new Rng(4);
    const bases = [120, 175, 140, 200, 125, 165, 210, 130, 185, 150, 115, 190];
    let jitter = 0, phase = 0;
    for (let i = 0; i < n; i++) {
      const t = i / SR, syllable = Math.floor(t / 0.42), into = t - syllable * 0.42;
      if (into >= 0.3) continue;
      if (i % Math.round(SR / 100) === 0) jitter = 0.7 * jitter + rng.gaussian() * 25;     // cents
      f[i] = bases[syllable % bases.length]! * (1 + 0.15 * into) * 2 ** (jitter / 1200);
      phase += (2 * Math.PI * f[i]!) / SR;
      for (let h = 1; h <= 6; h++) x[i]! += (0.1 / h) * Math.sin(h * phase);
    }
    const q = Float64Array.from({ length: 90 }, (_, k) => 0.2 + k * 0.05);
    const { f0 } = trackPitch(x, SR, q);
    const truth = Array.from(q).filter((t) => f[Math.floor(t * SR)]! > 0).length;
    expect(Array.from(f0).filter((v) => v > 0).length).toBeGreaterThan(truth / 2);
    for (let k = 0; k < q.length; k++) {
      const real = f[Math.floor(q[k]! * SR)]!;
      if (f0[k]! > 0 && real > 0) expect(Math.abs(f0[k]! - real)).toBeLessThan(0.06 * real);
    }
  });

  test("rejects a glide whose voicing flickers (each piece speech-length, the whole a Doppler curve)", () => {
    const n = SR * 6, x = noise(n, 0.002);
    let phase = 0;
    for (let i = 0; i < n; i++) {
      const t = i / SR, f = 120 + 40 / (1 + Math.exp((t - 3) * 1.5));
      phase += (2 * Math.PI * f) / SR;
      if (t % 0.65 < 0.5) for (let h = 1; h <= 4; h++) x[i]! += (0.1 / h) * Math.sin(h * phase);
    }
    const q = Float64Array.from({ length: 110 }, (_, k) => 0.2 + k * 0.05);
    expect(Array.from(trackPitch(x, SR, q).f0).filter((v) => v > 0).length).toBe(0);
  });

  test("rejects a steady engine tone as not-voice", () => {
    const x = noise(SR * 5, 0.002);
    for (let h = 1; h <= 4; h++) addTone(x, () => h * 95, 0.1 / h);
    const { f0 } = trackPitch(x, SR, times);
    expect(Array.from(f0).filter((v) => v > 0).length).toBe(0);
  });
});

describe("scurve (blind, no flight data)", () => {
  const clip = clipInfo(60);
  test("analytic flyby curve matches the track-based predictor", () => {
    const track = straightTrack({ offsetNorthM: 900, heightM: 1200, speed: 75, t0: 30 });
    const times = Float64Array.from([5, 20, 30, 40, 55]);
    const a = ratioCurve(new TrackPath(track, clip.location), clip, times, { east: 0, north: 0 });
    const b = flybyRatio(times, 30, 1500, 75);
    for (let i = 0; i < times.length; i++) expect(b[i]!).toBeCloseTo(a[i]!, 3);
  });

  test("finds and cancels a faint flyby buried in noise", async () => {
    const n = SR * 60, step = 0.02;
    const ratio = flybyRatio(Float64Array.from({ length: 60 / step + 2 }, (_, i) => i * step), 30, 4000, 120);
    const freq = perSampleFrequency(ratio, step, 110, n, SR);
    const x = noise(n, 0.1);
    addTone(x, (i) => freq[i]!, 0.012); // ≈ -21 dB re the noise: invisible frame by frame
    const y = await runChain(parseChain("scurve"), x, ctx());
    expect(db(toneAmplitude(y, (i) => freq[i]!), toneAmplitude(x, (i) => freq[i]!))).toBeLessThan(-12);
  }, 120_000);

  test("on pure noise, over-cancelling changes almost nothing", async () => {
    const x = noise(SR * 60, 0.1, 9);
    const y = await runChain(parseChain("scurve"), x, ctx());
    expect(Math.abs(db(bandRms(y, 30, 2000), bandRms(x, 30, 2000)))).toBeLessThan(0.3);
  }, 120_000);
});

describe("chains", () => {
  test("unknown modules and options are rejected", () => {
    expect(() => parseChain("nope")).toThrow();
    expect(() => parseChain("lowband(cutof=300)")).toThrow();
  });
  test("online modules refuse to run without tracks", async () => {
    expect(runChain(parseChain("informed"), noise(SR, 0.1), ctx())).rejects.toThrow();
  });
});

describe("no fingerprints from the cloak itself", () => {
  /** Mean dB of the long-term spectrum at f relative to its neighbourhood (negative = a dip). */
  function prominence(x: Float32Array, sr: number, freqs: number[]): number {
    const n = 1 << 16, hopN = n / 2, P = new Float64Array(n / 2);
    const w = Float64Array.from({ length: n }, (_, i) => 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / n));
    let segments = 0;
    for (let s = 0; s + n <= x.length; s += hopN, segments++) {
      const re = new Float64Array(n), im = new Float64Array(n);
      for (let i = 0; i < n; i++) re[i] = x[s + i]! * w[i]!;
      fft(re, im);
      for (let k = 0; k < n / 2; k++) P[k]! += re[k]! ** 2 + im[k]! ** 2;
    }
    const binHz = sr / n;
    const values = freqs.map((f) => {
      const k = Math.round(f / binHz), at = Math.min(...Array.from({ length: 5 }, (_, d) => P[k - 2 + d]!));
      const around: number[] = [];
      for (let d = Math.round(4 / binHz); d <= Math.round(12 / binHz); d++) around.push(P[k - d]!, P[k + d]!);
      return 10 * Math.log10(at / median(around));
    });
    return values.reduce((a, b) => a + b, 0) / values.length;
  }

  test("the default chain leaves no dips that tell 60 Hz grids from 50 Hz ones", async () => {
    const sr = SR, x = noise(sr * 30, 0.05, 21);
    const y = await runChain(parseChain("hum+lowband"), x, ctx());
    // Harmonics that belong to only one family, above and below the lowband cutoff.
    const sixty = prominence(y, sr, [120, 180, 240, 360]), fifty = prominence(y, sr, [100, 150, 200, 250, 350]);
    expect(Math.abs(sixty - fifty)).toBeLessThan(1.5);
  }, 120_000);

  test("regenerated low-band noise carries no narrow lines from the input", async () => {
    const sr = SR, x = noise(sr * 30, 0.05, 22);
    addTone(x, () => 87, 0.02);                   // a steady motor hum below the cutoff
    const y = await runChain(parseChain("lowband(keepVoice=false)"), x, ctx());
    expect(prominence(y, sr, [87])).toBeLessThan(3);
  }, 120_000);
});
