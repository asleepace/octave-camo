import { describe, expect, test } from "bun:test";
import type { Clip, Found, Samples, Trace } from "../src/engine/camo.ts";
import { analyzeInParts, FADE_SECONDS, mergeTraces, PAD_SECONDS, plan, scrubInParts, SINGLE_PASS_SECONDS, stitch } from "../src/engine/chunks.ts";
import { seededRandom } from "../src/random.ts";

const SR = 8_000;
const noise = (n: number, seed: number) => { const r = seededRandom(seed), x = new Float32Array(n); for (let i = 0; i < n; i++) x[i] = r() * 2 - 1; return x as Samples; };
const power = (x: Float32Array, from: number, to: number) => { let s = 0; for (let i = from; i < to; i++) s += x[i]! ** 2; return s / (to - from); };
const db = (r: number) => 10 * Math.log10(r);

describe("long clips in parts", () => {
  test("a clip up to the single-pass length is one part", () => {
    expect(plan(SINGLE_PASS_SECONDS * SR, SR)).toEqual([{ start: 0, end: SINGLE_PASS_SECONDS * SR, coreStart: 0, coreEnd: SINGLE_PASS_SECONDS * SR }]);
  });

  test("ten minutes is three balanced parts whose stretches tile the clip, each padded", () => {
    const frames = 600 * SR, parts = plan(frames, SR), pad = PAD_SECONDS * SR;
    expect(parts.length).toBe(3);
    expect(parts[0]!.coreStart).toBe(0);
    expect(parts.at(-1)!.coreEnd).toBe(frames);
    parts.forEach((p, k) => {
      expect(p.coreEnd - p.coreStart).toBe(200 * SR);
      if (k) expect(p.coreStart).toBe(parts[k - 1]!.coreEnd);
      expect(p.start).toBe(Math.max(0, p.coreStart - pad));
      expect(p.end).toBe(Math.min(frames, p.coreEnd + pad));
    });
    // Odd lengths still tile exactly.
    const odd = plan(601 * SR + 7, SR);
    expect(odd.at(-1)!.coreEnd).toBe(601 * SR + 7);
    expect(odd.every((p, k) => !k || p.coreStart === odd[k - 1]!.coreEnd)).toBe(true);
  });

  test("stitching untouched parts gives back the clip exactly", () => {
    const x = noise(620 * SR, 1), parts = plan(x.length, SR);
    const out = stitch(parts, parts.map((p) => x.slice(p.start, p.end)), x.length, SR);
    let worst = 0;
    for (let i = 0; i < x.length; i++) worst = Math.max(worst, Math.abs(out[i]! - x[i]!));
    expect(worst).toBeLessThan(1e-5);
  });

  test("unrelated noise in each part keeps its level through the seam, high and low", () => {
    const frames = 620 * SR, parts = plan(frames, SR);
    // Each part's output is its own noise (like a regenerated low band, here at every frequency).
    const outputs = parts.map((p, k) => noise(p.end - p.start, 10 + k));
    const out = stitch(parts, outputs, frames, SR);
    const half = (FADE_SECONDS * SR) / 2;
    for (const seam of parts.slice(0, -1).map((p) => p.coreEnd)) {
      const around = power(out, seam - half, seam + half), before = power(out, seam - 20 * half, seam - 2 * half);
      expect(Math.abs(db(around / before))).toBeLessThan(0.5);
      // The middle of the fade, where unrelated signals summed with weights adding to one would dip 3 dB.
      const middle = power(out, seam - half / 4, seam + half / 4);
      expect(Math.abs(db(middle / before))).toBeLessThan(0.7);
    }
  });

  test("outputs of the wrong length are refused", () => {
    const parts = plan(600 * SR, SR);
    expect(() => stitch(parts, parts.map(() => new Float32Array(5)), 600 * SR, SR)).toThrow();
  });

  const box = (start: number, end: number, lo: number, hi: number, kind: Found["kind"] = "steady"): Found => ({ start, end, lo, hi, kind });
  const trace = (found: Found[], extra: Partial<Trace> = {}): Trace => ({
    tones: found.length, doppler: found.filter((f) => f.kind === "doppler").length, hum: found.filter((f) => f.kind === "hum").length,
    flybys: found.filter((f) => f.kind === "doppler").length, found, ...extra,
  });

  test("a tone crossing a seam is counted once, at the clip's times; separate tones stay separate", () => {
    const parts = plan(600 * SR, SR);           // part 2 starts at 190 s, part 3 at 390 s
    const merged = mergeTraces(parts, [
      // A 700 Hz line through the whole clip, a 120 Hz hum only in part 1, a 2 kHz tone in part 1's padding.
      trace([box(0, 210, 699.5, 700.5), box(30, 60, 119.8, 120.2, "hum"), box(201, 209, 1_999, 2_001)]),
      // Part 2 sees the 700 Hz line, the same 2 kHz tone (its own times start at 190 s), and a Doppler tone.
      trace([box(0, 220, 699.4, 700.6, "noFit"), box(11, 19, 1_999.5, 2_000.5), box(100, 140, 300, 330, "doppler")]),
      trace([box(0, 210, 699.6, 700.4)]),
    ], SR);
    expect(merged.tones).toBe(4);
    expect(merged.hum).toBe(1);
    expect(merged.doppler).toBe(1);
    expect(merged.flybys).toBe(1);
    const line = merged.found.find((f) => f.lo < 700 && f.hi > 700)!;
    expect(line.start).toBe(0);
    expect(line.end).toBe(600);
    expect(line.kind).toBe("noFit");             // the riskier of steady and noFit
    expect(merged.found[0]).toBe(line);           // longest first
    const doppler = merged.found.find((f) => f.kind === "doppler")!;
    expect(doppler.start).toBe(290);
  });

  test("tones at different frequencies or times are not joined", () => {
    const parts = plan(600 * SR, SR);
    const merged = mergeTraces(parts, [trace([box(180, 210, 500, 501)]), trace([box(0, 20, 520, 521), box(30, 40, 500, 501)]), trace([])], SR);
    expect(merged.tones).toBe(3);
  });

  test("one part passes straight through", () => {
    const t = trace([box(1, 2, 3, 4)]);
    expect(mergeTraces(plan(10 * SR, SR), [t], SR)).toBe(t);
  });

  test("parts get their own seeds, a log line each, and their own slice of the clip", () => {
    const x = noise(610 * SR, 3), clip: Clip = { sampleRate: SR, channels: [x] };
    const seeds: number[] = [], seen: number[] = [], progress: string[] = [];
    const r = scrubInParts(clip, 41, (part, seed) => {
      seeds.push(seed); seen.push(part.channels[0]!.length);
      return { output: part.channels[0]!.slice() as Samples, log: ["hum: nothing"] };
    }, (k, n) => progress.push(`${k}/${n}`));
    expect(seeds).toEqual([41, 42, 43]);
    expect(progress).toEqual(["1/3", "2/3", "3/3"]);
    expect(seen.reduce((a, b) => a + b)).toBeGreaterThan(x.length);
    expect(r.output.length).toBe(x.length);
    expect(r.log[0]).toContain("3 parts");
    expect(r.log.filter((l) => l.endsWith("hum: nothing"))).toHaveLength(3);
    // A short clip: one call, the seed and log untouched; 0 (random) stays 0 for every part.
    const one = scrubInParts({ sampleRate: SR, channels: [noise(SR, 4)] }, 7, (part, seed) => ({ output: part.channels[0]!.slice() as Samples, log: [`seed ${seed}`] }));
    expect(one.log).toEqual(["seed 7"]);
    const random: number[] = [];
    scrubInParts(clip, 0, (part, seed) => { random.push(seed); return { output: part.channels[0]!.slice() as Samples, log: [] }; });
    expect(random).toEqual([0, 0, 0]);
  });

  test("checking in parts moves each part's tones to the clip's time", () => {
    const clip: Clip = { sampleRate: SR, channels: [noise(600 * SR, 5)] };
    const t = analyzeInParts(clip, () => trace([box(100, 110, 1_000, 1_001)]));
    expect(t.found.map((f) => f.start).sort((a, b) => a - b)).toEqual([100, 290, 490]);
  });
});
