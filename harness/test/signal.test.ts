import { describe, expect, test } from "bun:test";
import { cancelTone, flybyRatio, perSampleFrequency } from "../src/defense/flyby.ts";
import { Rng, decimate, erb, erbBands, erbFrequency, erbNumber, smooth } from "../src/defense/signal.ts";
import { median } from "../src/dsp.ts";
import { loudnessChange, voiceRetention } from "../src/quality.ts";

const tone = (n: number, sr: number, f: number, a = 0.1) => Float32Array.from({ length: n }, (_, i) => a * Math.sin((2 * Math.PI * f * i) / sr));
const amplitudeAt = (x: Float32Array, sr: number, f: number) => {
  let s = 0, c = 0;
  for (let i = 0; i < x.length; i++) { s += x[i]! * Math.sin((2 * Math.PI * f * i) / sr); c += x[i]! * Math.cos((2 * Math.PI * f * i) / sr); }
  return (2 * Math.hypot(s, c)) / x.length;
};
function noise(n: number, rms: number, seed: number) {
  const r = new Rng(seed);
  return Float32Array.from({ length: n }, () => rms * r.gaussian());
}

describe("Rng", () => {
  test("same seed, same sequence; different seed, different sequence", () => {
    const a = new Rng(42), b = new Rng(42), c = new Rng(43);
    const sa = Array.from({ length: 5 }, () => a.next()), sb = Array.from({ length: 5 }, () => b.next());
    expect(sa).toEqual(sb);
    expect(Array.from({ length: 5 }, () => c.next())).not.toEqual(sa);
  });
  test("gaussian draws have mean 0 and unit variance", () => {
    const r = new Rng(7), xs = Array.from({ length: 100_000 }, () => r.gaussian());
    const mean = xs.reduce((s, v) => s + v, 0) / xs.length;
    const variance = xs.reduce((s, v) => s + (v - mean) ** 2, 0) / xs.length;
    expect(Math.abs(mean)).toBeLessThan(0.02);
    expect(variance).toBeCloseTo(1, 1);
  });
  test("uniform stays in range", () => {
    const r = new Rng(1);
    for (let i = 0; i < 1000; i++) { const v = r.uniform(-3, 5); expect(v).toBeGreaterThanOrEqual(-3); expect(v).toBeLessThan(5); }
  });
});

describe("decimate", () => {
  const sr = 48_000, x = new Float32Array(sr * 2);
  const inBand = tone(x.length, sr, 300), aliasing = tone(x.length, sr, 3_000);
  for (let i = 0; i < x.length; i++) x[i] = inBand[i]! + aliasing[i]!;
  const { x: y, rate } = decimate(x, sr, 4_000);

  test("reports the new rate and length", () => {
    expect(rate).toBe(4_000);
    expect(y.length).toBe(x.length / 12);
  });
  test("keeps in-band tones", () => {
    expect(amplitudeAt(y.subarray(400, -400), rate, 300)).toBeCloseTo(0.1, 2);
  });
  test("rejects tones above the new Nyquist instead of aliasing them", () => {
    // 3 kHz would alias to |3000 − 4000| = 1000 Hz.
    expect(amplitudeAt(y.subarray(400, -400), rate, 1_000)).toBeLessThan(0.1 * 10 ** (-40 / 20));
  });
  test("is a no-op when the rate already matches", () => {
    expect(decimate(x, 4_000, 4_000).x).toBe(x);
  });
});

describe("ERB scale", () => {
  test("matches Glasberg & Moore: ~35 Hz at 100 Hz, ~133 Hz at 1 kHz", () => {
    expect(erb(100)).toBeCloseTo(35.5, 0);
    expect(erb(1000)).toBeCloseTo(132.6, 0);
  });
  test("number and frequency are inverses", () => {
    for (const f of [20, 100, 300, 1000, 8000]) expect(erbFrequency(erbNumber(f))).toBeCloseTo(f, 6);
  });
  test("bands are ascending, cover the range, and are about 1 ERB wide", () => {
    const edges = erbBands(20, 300);
    expect(edges[0]).toBeCloseTo(20, 6);
    expect(edges.at(-1)).toBe(300);
    for (let i = 1; i < edges.length - 1; i++) {
      const width = edges[i]! - edges[i - 1]!, center = (edges[i]! + edges[i - 1]!) / 2;
      expect(width / erb(center)).toBeGreaterThan(0.9);
      expect(width / erb(center)).toBeLessThan(1.1);
    }
  });
});

describe("smooth", () => {
  test("averages over the window and handles edges", () => {
    const s = smooth(Float64Array.from([0, 0, 3, 0, 0]), 3);
    expect(Array.from(s)).toEqual([0, 1, 1, 1, 0]);
  });
  test("length 1 is a copy", () => {
    const x = Float64Array.from([1, 2, 3]);
    const s = smooth(x, 1);
    expect(Array.from(s)).toEqual([1, 2, 3]);
    expect(s).not.toBe(x);
  });
});

describe("flyby curves", () => {
  test("ratio is 1 at closest approach, above before, below after", () => {
    const r = flybyRatio([0, 30, 60], 30, 1500, 75);
    expect(r[1]!).toBeCloseTo(1, 9);
    expect(r[0]!).toBeGreaterThan(1);
    expect(r[2]!).toBeLessThan(1);
  });
  test("faster or closer means a larger shift", () => {
    expect(flybyRatio([0], 30, 1500, 150)[0]!).toBeGreaterThan(flybyRatio([0], 30, 1500, 75)[0]!);
  });
  test("per-sample frequency interpolates the curve", () => {
    const ratio = Float64Array.from([1, 1.1, 1.2]);
    const f = perSampleFrequency(ratio, 0.5, 100, 1000, 1000);   // 1 s at 1 kHz, curve every 0.5 s
    expect(f[0]!).toBeCloseTo(100, 6);
    expect(f[250]!).toBeCloseTo(105, 6);
    expect(f[500]!).toBeCloseTo(110, 6);
  });
  test("cancelTone removes a tone with known frequency (> 40 dB)", () => {
    const sr = 8_000, x = tone(sr * 4, sr, 137);
    const freq = new Float64Array(x.length).fill(137);
    cancelTone(x, freq, sr, 0.3);
    expect(amplitudeAt(x.subarray(sr, -sr), sr, 137)).toBeLessThan(0.1 * 10 ** (-40 / 20));
  });
});

describe("quality metrics", () => {
  const sr = 16_000, x = noise(sr * 5, 0.1, 3);
  test("identical signals: no loudness change", () => {
    expect(loudnessChange(x, x, sr, 30, 4000)).toBe(0);
  });
  test("half amplitude reads as about 6 dB", () => {
    expect(loudnessChange(x, x.map((v) => v / 2), sr, 30, 4000)).toBeCloseTo(6.02, 1);
  });
  test("voice retention: ~1 for the voice itself, low for unrelated noise", () => {
    const voice = new Float32Array(sr * 5);
    let p = 0;
    for (let i = 0; i < voice.length; i++) {
      const f = 130 + 20 * Math.sin((2 * Math.PI * i) / sr / 0.8);
      p += (2 * Math.PI * f) / sr;
      voice[i] = 0.1 * (Math.sin(p) + 0.5 * Math.sin(2 * p));
    }
    expect(voiceRetention(voice, voice, sr)).toBeCloseTo(1, 3);
    expect(voiceRetention(voice, noise(voice.length, 0.1, 11), sr)).toBeLessThan(0.3);
  });
});

describe("median", () => {
  test("odd, even and unsorted input", () => {
    expect(median([3, 1, 2])).toBe(2);
    expect(median([4, 1, 3, 2])).toBe(2.5);
  });
});
