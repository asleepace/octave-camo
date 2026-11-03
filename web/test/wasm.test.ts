/**
 * Smoke test of the real WebAssembly build through the same binding the web app uses.
 * CI builds web/public/octave-camo.wasm first; locally it is skipped when the file is missing.
 */
import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { Camo, type Clip, type Profiles } from "../src/engine/camo.ts";

const BUILDS = [
  ["release", new URL("../public/octave-camo.wasm", import.meta.url).pathname],
  // CI also builds a debug variant: same code, but a Swift trap prints its reason.
  ["debug", new URL("./wasm/octave-camo-debug.wasm", import.meta.url).pathname],
] as const;
const SR = 16_000;

/** 40 s: a jet-like flyby (Doppler-shifted tone + harmonics), 60 Hz mains hum, noise. */
function flybyClip(): Clip {
  const n = SR * 40, c = 343, speed = 90, distance = 300, t0 = 20, f0 = 180;
  const x = new Float32Array(n);
  let seed = 7;
  const rand = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32);
  let phase = 0;
  for (let i = 0; i < n; i++) {
    const t = i / SR;
    // Received frequency ignoring propagation delay is plenty for a smoke test.
    const dx = speed * (t - t0), r = Math.hypot(dx, distance);
    phase += (2 * Math.PI * f0 / (1 + (speed * dx) / (r * c))) / SR;
    const level = 0.08 * Math.min(1, 300 / r);
    let s = 0;
    for (let h = 1; h <= 3; h++) s += (level / h) * Math.sin(h * phase);
    s += 0.01 * Math.sin(2 * Math.PI * 60 * t) + 0.005 * Math.sin(2 * Math.PI * 120 * t);
    x[i] = s + 0.01 * (rand() + rand() + rand() - 1.5);
  }
  return { sampleRate: SR, channels: [x] };
}

/** 20 s of row profiles: a panning scene plus 100 Hz rolling-shutter flicker with ENF-like wander. */
function flickerProfiles(withFlicker: boolean): Profiles {
  const fps = 30, frames = 600, strips = 6, rows = 120;
  let seed = 11;
  const rand = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32);
  const features = Array.from({ length: strips }, () =>
    Array.from({ length: 6 }, () => ({ c: rand(), w: 0.02 + 0.18 * rand(), a: 0.6 * rand() - 0.3 })));
  const values = new Float32Array(frames * strips * rows), times = new Float32Array(frames);
  for (let k = 0; k < frames; k++) {
    const t = k / fps;
    times[k] = t;
    const pan = 0.004 * t + 0.01 * Math.sin((2 * Math.PI * t) / 7);
    const wander = ((0.05 * 17) / (2 * Math.PI)) * Math.cos((2 * Math.PI * t) / 17);
    for (let s = 0; s < strips; s++) for (let r = 0; r < rows; r++) {
      const u = r / rows + pan;
      let v = -0.8 + 0.2 * u;
      for (const f of features[s]!) v += f.a * Math.exp(-(((u - f.c) / f.w) ** 2));
      if (withFlicker) v += 0.03 * Math.cos(2 * Math.PI * (100 * (t + (0.6 / fps) * (r / rows)) - wander));
      values[(k * strips + s) * rows + r] = v + 0.002 * (rand() + rand() + rand() - 1.5);
    }
  }
  return { frames, strips, rows, values, times };
}

for (const [name, WASM] of BUILDS) describe.skipIf(!existsSync(WASM))(`octave-camo.wasm (${name})`, () => {
  test("exposes the default steps", async () => {
    const camo = await Camo.load(readFileSync(WASM));
    expect(camo.defaultSteps).toEqual(["mono", "hum", "subtract", "scurve", "lowband"]);
  });

  test("scrubs a flyby and hum so a blind tracker finds neither", async () => {
    const camo = await Camo.load(readFileSync(WASM));
    const clip = flybyClip();
    const before = camo.analyze(clip);
    expect(before.doppler).toBeGreaterThan(0);
    expect(before.hum).toBeGreaterThan(0);

    const { output, log } = camo.scrub(clip, { seed: 42 });
    expect(output.length).toBe(clip.channels[0]!.length);
    expect(output.every(Number.isFinite)).toBe(true);
    expect(log.map((l) => l.split(":")[0])).toEqual(["mono", "hum", "subtract", "scurve", "lowband"]);

    const after = camo.analyze({ sampleRate: SR, channels: [output] });
    expect(after.doppler).toBe(0);
    expect(after.hum).toBe(0);
  }, 600_000);

  test("reports each long tone's time and frequency, from 40 Hz up to 8 kHz", async () => {
    const camo = await Camo.load(readFileSync(WASM));
    const x = new Float32Array(SR * 12);
    let seed = 3;
    for (let i = 0; i < x.length; i++) {
      seed = (seed * 1664525 + 1013904223) >>> 0;
      x[i] = 0.02 * Math.sin((2 * Math.PI * 1_200 * i) / SR) + 0.004 * (seed / 2 ** 32 - 0.5);
    }
    const trace = camo.analyze({ sampleRate: SR, channels: [x] });
    expect(trace.tones).toBe(trace.found.length);
    const tone = trace.found.find((f) => f.lo < 1_200 && f.hi > 1_200);
    expect(tone).toBeDefined();
    expect(tone!.hi - tone!.lo).toBeLessThan(10);
    expect(tone!.start).toBeLessThan(1);
    expect(tone!.end).toBeGreaterThan(10);
    // Counted but not removed yet (the cloak's tone subtraction stops at 1 kHz).
    const after = camo.analyze({ sampleRate: SR, channels: [camo.scrub({ sampleRate: SR, channels: [x] }, { seed: 5 }).output] });
    expect(after.found.some((f) => f.lo < 1_200 && f.hi > 1_200)).toBe(true);
  }, 600_000);

  test("finds rolling-shutter flicker, removes it, and leaves clean video alone", async () => {
    const camo = await Camo.load(readFileSync(WASM));
    const flickering = camo.flicker(flickerProfiles(true), true);
    expect(flickering.detected).toBe(true);
    expect(Math.abs(flickering.flickerHz - 100)).toBeLessThan(0.6);
    expect(flickering.after.z).toBeLessThan(flickering.z / 10);
    expect(flickering.gains!.length).toBe(600 * 120);
    const clean = camo.flicker(flickerProfiles(false), true);
    expect(clean.detected).toBe(false);
    expect(clean.checked).toBe(true);
    expect(clean.gains!.every((g) => g === 1)).toBe(true);
  }, 600_000);

  test("a picture it can't judge is reported as not checked, never as clean", async () => {
    const camo = await Camo.load(readFileSync(WASM));
    const few = flickerProfiles(true);
    // 5 frames: under the export's minimum; 60 frames: under one 4 s segment.
    for (const frames of [5, 60]) {
      const p = { ...few, frames, values: few.values.slice(0, frames * 6 * 120), times: few.times.slice(0, frames) };
      const r = camo.flicker(p, true);
      expect(r.checked).toBe(false);
      expect(r.detected).toBe(false);
      expect(r.gains === undefined || r.gains.every((g) => g === 1)).toBe(true);
    }
  });

  test("bad input is refused, and refusing leaves no stale result behind", async () => {
    const camo = await Camo.load(readFileSync(WASM));
    const clip = flybyClip();
    const short = { sampleRate: SR, channels: [clip.channels[0]!.slice(0, SR * 3)] };
    expect(camo.scrub(short, { seed: 1 }).output.length).toBe(SR * 3);
    expect(() => camo.scrub({ sampleRate: SR, channels: [new Float32Array(0)] })).toThrow();
    expect(() => camo.scrub({ sampleRate: SR, channels: [new Float32Array(10), new Float32Array(9)] })).toThrow();
    expect(() => camo.analyze({ sampleRate: 0, channels: [new Float32Array(10)] })).toThrow();
    expect(() => camo.scrub({ sampleRate: 0, channels: [new Float32Array(10)] })).toThrow();
  }, 600_000);

  test("NaN, Inf and absurd samples are replaced, not spread", async () => {
    const camo = await Camo.load(readFileSync(WASM));
    const x = flybyClip().channels[0]!.slice(0, SR * 5);
    x[10] = Number.NaN; x[1000] = Number.POSITIVE_INFINITY; x[2000] = 1e12;
    const { output, log } = camo.scrub({ sampleRate: SR, channels: [x] }, { seed: 3 });
    expect(output.every(Number.isFinite)).toBe(true);
    expect(Math.max(...output.map(Math.abs))).toBeGreaterThan(0.01);
    expect(log[0]).toContain("replaced 3");
  }, 600_000);

  test("every sample rate the page can send cloaks to the same length", async () => {
    const camo = await Camo.load(readFileSync(WASM));
    for (const sampleRate of [8_000, 22_050, 44_100, 48_000]) {
      const n = sampleRate * 3, x = new Float32Array(n);
      for (let i = 0; i < n; i++) x[i] = 0.05 * Math.sin((2 * Math.PI * 60 * i) / sampleRate) + 0.01 * Math.sin(i * 1.7);
      const { output } = camo.scrub({ sampleRate, channels: [x] }, { seed: 9 });
      expect(output.length).toBe(n);
      expect(output.every(Number.isFinite)).toBe(true);
    }
  }, 600_000);

  test("a seed makes the output deterministic", async () => {
    const camo = await Camo.load(readFileSync(WASM));
    const clip = flybyClip();
    const a = camo.scrub(clip, { steps: ["hum", "lowband"], seed: 5 }).output;
    const b = camo.scrub(clip, { steps: ["hum", "lowband"], seed: 5 }).output;
    expect(a).toEqual(b);
  }, 600_000);
});
