import { describe, expect, test } from "bun:test";
import { parseChain, runChain } from "../src/defense/index.ts";
import { flybyRatio, perSampleFrequency } from "../src/defense/flyby.ts";
import { trackPitch } from "../src/defense/pitch.ts";
import { LowBandSTFT, Rng } from "../src/defense/signal.ts";
import type { DefenseContext } from "../src/defense/types.ts";
import { ratioCurve } from "../src/matched.ts";
import { fft } from "../src/dsp.ts";
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

  test("finds a moving voice-like pitch", () => {
    const x = noise(SR * 5, 0.002);
    const f = (i: number) => 140 + 25 * Math.sin((2 * Math.PI * i) / SR / 1.3);
    for (let h = 1; h <= 6; h++) addTone(x, (i) => h * f(i), 0.1 / h);
    const { f0 } = trackPitch(x, SR, times);
    const voiced = Array.from(f0).filter((v) => v > 0);
    expect(voiced.length).toBeGreaterThan(60);
    for (let q = 0; q < times.length; q++) if (f0[q]! > 0) expect(Math.abs(f0[q]! - f(times[q]! * SR))).toBeLessThan(5);
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
