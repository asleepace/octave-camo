/** Module-level behavior: hum, lowband details, decoy, informed, and the chain runner. */
import { describe, expect, test } from "bun:test";
import { describeModules, modules, needs, parseChain, parseChains, runChain } from "../src/defense/index.ts";
import { notch, swiftBinary } from "../src/defense/modules.ts";
import { Rng } from "../src/defense/signal.ts";
import type { DefenseContext } from "../src/defense/types.ts";
import { fft } from "../src/dsp.ts";
import { defaultMatchedConfig, matchedAttack, whitenedSpectrogram } from "../src/matched.ts";
import { loudnessChange, voiceRetention } from "../src/quality.ts";
import { predictedDopplerRatio } from "../src/track.ts";
import { clipInfo, straightTrack } from "./helpers.ts";

const ctx = (sampleRate: number, extra: Partial<DefenseContext> = {}): DefenseContext =>
  ({ sampleRate, seed: 1, log: () => {}, ...extra });
const noise = (n: number, rms: number, seed = 3) => { const r = new Rng(seed); return Float32Array.from({ length: n }, () => rms * r.gaussian()); };
function addTone(x: Float32Array, sr: number, freq: (i: number) => number, amp: number) {
  let p = 0;
  for (let i = 0; i < x.length; i++) { p += (2 * Math.PI * freq(i)) / sr; x[i]! += amp * Math.sin(p); }
}
const amplitudeAt = (x: Float32Array, sr: number, f: number) => {
  let s = 0, c = 0;
  for (let i = 0; i < x.length; i++) { s += x[i]! * Math.sin((2 * Math.PI * f * i) / sr); c += x[i]! * Math.cos((2 * Math.PI * f * i) / sr); }
  return (2 * Math.hypot(s, c)) / x.length;
};
const db = (a: number, b: number) => 20 * Math.log10(a / b);

describe("hum", () => {
  const sr = 8_000, n = sr * 4;
  const mixed = () => { const x = new Float32Array(n); for (const f of [60, 120, 180, 100, 430, 1000]) addTone(x, sr, () => f, 0.1); return x; };

  test("notches both the 50 and 60 Hz families and leaves other tones alone", async () => {
    const y = await runChain(parseChain("hum(refill=false)"), mixed(), ctx(sr));
    const mid = y.subarray(sr, -sr);
    for (const f of [60, 120, 180, 100]) expect(amplitudeAt(mid, sr, f)).toBeLessThan(0.1 * 10 ** (-30 / 20));
    for (const f of [430, 1000]) expect(db(amplitudeAt(mid, sr, f), 0.1)).toBeGreaterThan(-0.5);
  });
  test("refill removes a wandering mains line without leaving a dip", async () => {
    const r = new Rng(5), x = new Float32Array(n);
    for (let i = 0; i < n; i++) x[i] = 0.02 * r.gaussian();
    addTone(x, sr, (i) => 60 + 0.05 * Math.sin((2 * Math.PI * i) / sr / 3), 0.05);   // ENF-like wander
    const y = (await runChain(parseChain("hum"), x, ctx(sr))).subarray(sr, -sr);
    expect(amplitudeAt(y, sr, 60)).toBeLessThan(0.05 * 10 ** (-26 / 20));
    // The band around 60 Hz keeps about the noise floor's power (no hole, no line).
    const band = (f: number) => { let p = 0; for (let d = -1; d <= 1; d += 0.25) p += amplitudeAt(y, sr, f + d) ** 2; return p; };
    expect(Math.abs(10 * Math.log10(band(60) / band(75)))).toBeLessThan(4);
  });
  test("mains=50 targets 50 Hz harmonics instead", async () => {
    const x = new Float32Array(n);
    addTone(x, sr, () => 50, 0.1); addTone(x, sr, () => 60, 0.1);
    const y = (await runChain(parseChain("hum(mains=50,refill=false)"), x, ctx(sr))).subarray(sr, -sr);
    expect(amplitudeAt(y, sr, 50)).toBeLessThan(0.003);
    expect(amplitudeAt(y, sr, 60)).toBeGreaterThan(0.09);
  });
  test("is zero-phase: a kept tone isn't delayed", async () => {
    // Well above the notched range (harmonics up to 400 Hz), so nothing near it is notched or refilled.
    const long = sr * 10, x = new Float32Array(long); addTone(x, sr, () => 1500, 0.1);
    const y = await runChain(parseChain("hum"), x, ctx(sr));
    const worst = (from: number, to: number) => { let e = 0; for (let i = from; i < to; i++) e = Math.max(e, Math.abs(y[i]! - x[i]!)); return e; };
    // Exactly zero-phase once both passes have settled (the edge passes settle within ~3 s here)...
    expect(worst(3 * sr, long - 3 * sr)).toBeLessThan(1e-3);
    // ...and at the edges, where both passes run one way over 32 notches, within about 10° (20 µs
    // at 1.5 kHz: inaudible; the price of removing the mains line right up to the edge).
    expect(worst(0, long)).toBeLessThan(0.025);
  });
});

describe("notch edges", () => {
  test("a mains line is gone right up to the clip's first and last samples", () => {
    const sr = 16_000, n = sr * 4, x = new Float32Array(n);
    addTone(x, sr, () => 60, 0.1);
    const y = notch(x, 60, 30, sr);
    let edge = 0;
    for (let i = 0; i < sr / 4; i++) edge = Math.max(edge, Math.abs(y[i]!), Math.abs(y[n - 1 - i]!));
    expect(edge).toBeLessThan(0.01);                    // was 0.1 (untouched) with cold passes
  });
});

describe("lowband", () => {
  const sr = 16_000, n = sr * 12;

  test("is deterministic for a seed and varies across seeds", async () => {
    const x = noise(n, 0.05);
    const a = await runChain(parseChain("lowband(keepVoice=false)"), x, ctx(sr, { seed: 5 }));
    const b = await runChain(parseChain("lowband(keepVoice=false)"), x, ctx(sr, { seed: 5 }));
    const c = await runChain(parseChain("lowband(keepVoice=false)"), x, ctx(sr, { seed: 6 }));
    expect(b).toEqual(a);
    expect(c).not.toEqual(a);
  });

  test("keepVoice preserves a moving-pitch voice better than plain regeneration", async () => {
    const voice = new Float32Array(n);
    for (let h = 1; h <= 6; h++) addTone(voice, sr, (i) => h * (120 + 30 * Math.sin((2 * Math.PI * i) / sr / 1.1)), 0.08 / h);
    const x = Float32Array.from(voice, (v, i) => v + 0.01 * (new Rng(i).next() - 0.5));
    const keep = await runChain(parseChain("lowband"), x, ctx(sr));
    const drop = await runChain(parseChain("lowband(keepVoice=false)"), x, ctx(sr));
    expect(voiceRetention(voice, keep, sr)).toBeGreaterThan(voiceRetention(voice, drop, sr) + 0.2);
  });

  test("jitter adds a slow loudness wobble of about ±jitterDb", async () => {
    const x = noise(sr * 60, 0.05, 8);
    const quiet = await runChain(parseChain("lowband(keepVoice=false,jitterDb=0)"), x, ctx(sr));
    const wobbly = await runChain(parseChain("lowband(keepVoice=false,jitterDb=3)"), x, ctx(sr));
    expect(loudnessChange(quiet, wobbly, sr, 30, 200)).toBeGreaterThan(0.8);
    expect(loudnessChange(quiet, wobbly, sr, 30, 200)).toBeLessThan(4);
  });

  test("a higher cutoff regenerates more of the spectrum", async () => {
    const x = new Float32Array(n); addTone(x, sr, () => 400, 0.1);
    const at300 = await runChain(parseChain("lowband(keepVoice=false)"), x.slice(), ctx(sr));
    const at600 = await runChain(parseChain("lowband(keepVoice=false,cutoff=600)"), x.slice(), ctx(sr));
    expect(db(amplitudeAt(at300.subarray(sr, -sr), sr, 400), 0.1)).toBeGreaterThan(-0.5);
    // What's left is just the regenerated noise's random share of the band, not the tone.
    expect(db(amplitudeAt(at600.subarray(sr, -sr), sr, 400), 0.1)).toBeLessThan(-10);
  });
});

describe("decoy", () => {
  const clip = clipInfo(90);
  const real = { ...straightTrack({ offsetNorthM: 5_000, heightM: 3_000, speed: 150, t0: 45 }), id: "real" };
  const sr = defaultMatchedConfig.sampleRate;

  test("random decoys are barely audible (low-band loudness change < 1.5 dB)", async () => {
    const x = noise(sr * 90, 0.1, 21);
    const y = await runChain(parseChain("decoy"), x.slice(), ctx(sr, { seed: 3 }));
    expect(loudnessChange(x, y, sr, 30, 600)).toBeLessThan(1.5);
  });

  test("a decoy sits below the background in a critical band (what a listener hears)", async () => {
    const x = noise(sr * 90, 0.1, 22);
    const y = await runChain(parseChain("decoy(count=1,f0Min=150,f0Max=150,harmonics=1)"), x.slice(), ctx(sr, { seed: 3 }));
    const d = y.map((v, i) => v - x[i]!);                       // the decoy alone (decoys only add)
    const decoyPower = d.reduce((s, v) => s + v * v, 0) / d.length;
    // White noise: power per Hz = σ² / (sr/2). One ERB around 150 Hz is ~41 Hz wide.
    const noiseInErb = (0.1 ** 2 / (sr / 2)) * 41;
    const ratio = 10 * Math.log10(decoyPower / noiseInErb);
    expect(ratio).toBeLessThan(-3);                              // masked for a listener
    expect(ratio).toBeGreaterThan(-35);                          // but really there
  });

  test("spoof decoys steer the matched attacker to a fake place", async () => {
    const x = noise(sr * 90, 0.1, 23);
    const y = await runChain(parseChain("decoy(mode=spoof,count=1,levelDb=12,spoofKm=6)"), x, ctx(sr, { clip, tracks: [real] }));
    const r = matchedAttack(whitenedSpectrogram(y, defaultMatchedConfig), [real], clip);
    expect(r.aircraft[0]!.detected).toBe(true);
    expect(r.ambiguityAwareErrorM!).toBeGreaterThan(3_000);     // nowhere near the truth
    expect(r.errorM!).toBeGreaterThan(4_000);
    expect(r.errorM!).toBeLessThan(8_500);                      // close to the 6 km fake
  }, 60_000);

  test("spoof mode refuses to run without tracks", async () => {
    expect(runChain(parseChain("decoy(mode=spoof)"), noise(sr, 0.1), ctx(sr))).rejects.toThrow();
  });
});

describe("informed (as a chain module)", () => {
  test("cancels the plane so the matched attacker loses it", async () => {
    const clip = clipInfo(90), sr = defaultMatchedConfig.sampleRate;
    const plane = { ...straightTrack({ offsetNorthM: 5_000, heightM: 3_000, speed: 150, t0: 45 }), id: "plane" };
    const step = 0.02, grid = Array.from({ length: 90 / step + 2 }, (_, i) => i * step);
    const ratio = predictedDopplerRatio(plane, clip, grid);
    const x = noise(sr * 90, 0.1, 31);
    addTone(x, sr, (i) => { const g = i / sr / step, k = Math.floor(g); return 95 * (ratio[k]! + (g - k) * (ratio[k + 1]! - ratio[k]!)); }, 0.01);
    const before = matchedAttack(whitenedSpectrogram(x, defaultMatchedConfig), [plane], clip);
    expect(before.aircraft[0]!.detected).toBe(true);
    const y = await runChain(parseChain("informed"), x, ctx(sr, { clip, tracks: [plane] }));
    const after = matchedAttack(whitenedSpectrogram(y, defaultMatchedConfig), [plane], clip);
    expect(after.aircraft[0]!.detected).toBe(false);
  }, 60_000);
});

describe("chains", () => {
  test("every registered module parses with defaults and has a summary", () => {
    for (const m of modules) {
      expect(() => parseChain(m.name)).not.toThrow();
      expect(m.summary.length).toBeGreaterThan(10);
    }
    expect(describeModules()).toContain("lowband");
  });
  test("multiple chains split on ';' and options keep their values", () => {
    const chains = parseChains("hum; lowband(mode=highpass,cutoff=250) ;legacy(steps=hum|subtract)");
    expect(chains.map((c) => c.label)).toEqual(["hum", "lowband(mode=highpass,cutoff=250)", "legacy(steps=hum|subtract)"]);
    expect(chains[1]!.steps[0]!.options).toEqual({ mode: "highpass", cutoff: "250" });
  });
  test("bad values are rejected, not silently defaulted", () => {
    expect(() => parseChain("lowband(cutoff=-5)")).toThrow();
    expect(() => parseChain("lowband(mode=loud)")).toThrow();
    expect(() => parseChain("lowband(keepVoice=maybe)")).toThrow();
    expect(() => parseChain("lowband(cutoff)")).toThrow();
    expect(() => parseChain("")).toThrow();
  });
  test("needs() reports what online modules require", () => {
    expect([...needs(parseChain("hum+lowband"))]).toEqual([]);
    expect(needs(parseChain("hum+informed")).has("tracks")).toBe(true);
  });
  test("the runner never lets the output clip", async () => {
    const x = Float32Array.from({ length: 4000 }, (_, i) => 1.4 * Math.sin(i / 10));
    const y = await runChain(parseChain("hum(mains=0)"), x, ctx(4000));
    let peak = 0;
    for (const v of y) peak = Math.max(peak, Math.abs(v));
    expect(peak).toBeLessThanOrEqual(0.99 + 1e-6);
  });
});

describe.skipIf(!(await Bun.file(swiftBinary()).exists()))("swift (the shipped pipeline)", () => {
  test("runs the Swift CLI on a clip and returns the same length", async () => {
    const sr = 16_000, x = noise(sr * 6, 0.05, 4), lines: string[] = [];
    const y = await runChain(parseChain("swift"), x, { sampleRate: sr, seed: 3, log: (l) => lines.push(l) });
    expect(y.length).toBeGreaterThan(x.length - 64);
    expect(y.length).toBeLessThan(x.length + 64);
    expect(lines.some((l) => l.includes("lowband"))).toBe(true);
  }, 120_000);
});
