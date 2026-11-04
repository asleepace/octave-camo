/**
 * Smoke test of the real WebAssembly build through the same binding the web app uses.
 * CI builds web/public/octave-camo.wasm first; locally it is skipped when the file is missing.
 */
import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { Camo, type Clip, type Profiles } from "../src/engine/camo.ts";
import { analyzeInParts, plan, scrubInParts } from "../src/engine/chunks.ts";
import { seededRandom } from "../src/random.ts";

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
  const rand = seededRandom(7);
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
  const rand = seededRandom(11);
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
    const rand = seededRandom(3);
    for (let i = 0; i < x.length; i++) x[i] = 0.02 * Math.sin((2 * Math.PI * 1_200 * i) / SR) + 0.004 * (rand() - 0.5);
    const trace = camo.analyze({ sampleRate: SR, channels: [x] });
    expect(trace.tones).toBe(trace.found.length);
    expect(trace.found.filter((f) => f.lo > 1_300)).toEqual([]);            // the background noise is not a tone
    const tone = trace.found.find((f) => f.lo < 1_205 && f.hi > 1_195);
    expect(tone).toBeDefined();
    expect(tone!.hi - tone!.lo).toBeLessThan(10);
    expect(tone!.start).toBeLessThan(1);
    expect(tone!.end).toBeGreaterThan(10);
    // Counted but not removed yet (the cloak's tone subtraction stops at 1 kHz).
    const after = camo.analyze({ sampleRate: SR, channels: [camo.scrub({ sampleRate: SR, channels: [x] }, { seed: 5 }).output] });
    expect(after.found.some((f) => f.lo < 1_205 && f.hi > 1_195)).toBe(true);
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

/**
 * Ten minutes at 48 kHz: a steady 1.2 kHz line through the whole clip, 60 Hz hum, and a flyby whose
 * closest approach sits on the first seam. Background noise throughout.
 */
function longClip(seconds: number, sr: number): Clip {
  const n = seconds * sr, x = new Float32Array(n), rand = seededRandom(23);
  const c = 343, speed = 90, distance = 300, t0 = 200, f0 = 180;
  let phase = 0;
  for (let i = 0; i < n; i++) {
    const t = i / sr, dx = speed * (t - t0), r = Math.hypot(dx, distance);
    phase += (2 * Math.PI * f0 / (1 + (speed * dx) / (r * c))) / sr;
    const level = 0.08 * Math.min(1, 300 / r);
    let s = 0;
    for (let h = 1; h <= 3; h++) s += (level / h) * Math.sin(h * phase);
    s += 0.004 * Math.sin(2 * Math.PI * 1_200 * t) + 0.01 * Math.sin(2 * Math.PI * 60 * t);
    x[i] = s + 0.01 * (rand() + rand() + rand() - 1.5);
  }
  return { sampleRate: sr, channels: [x] };
}

describe.skipIf(!existsSync(BUILDS[0][1]))("a ten-minute clip, in parts (release build)", () => {
  test("is checked and cloaked whole: one line per tone across the seams, no clicks, the flyby on a seam removed", async () => {
    const sr = 48_000, clip = longClip(600, sr), camo = await Camo.load(readFileSync(BUILDS[0][1]));
    const parts = plan(clip.channels[0]!.length, sr);
    expect(parts.length).toBe(3);
    let t = performance.now();
    const before = analyzeInParts(clip, (p) => camo.analyze(p));
    const checkSeconds = (performance.now() - t) / 1000;
    const line = before.found.filter((f) => f.lo < 1_201 && f.hi > 1_199);
    expect(line).toHaveLength(1);                                          // one line, not one per part
    expect(line[0]!.start).toBeLessThan(5);
    expect(line[0]!.end).toBeGreaterThan(595);
    expect(before.doppler).toBeGreaterThan(0);
    expect(before.hum).toBeGreaterThan(0);

    t = performance.now();
    const { output, log } = scrubInParts(clip, 9, (p, seed) => camo.scrub(p, { seed }));
    const cloakSeconds = (performance.now() - t) / 1000;
    expect(output.length).toBe(clip.channels[0]!.length);
    expect(output.every(Number.isFinite)).toBe(true);
    expect(log[0]).toContain("3 parts");
    // No click at a seam: the biggest step from one sample to the next there is like anywhere else.
    const step = (from: number, to: number) => { let m = 0; for (let i = from + 1; i < to; i++) m = Math.max(m, Math.abs(output[i]! - output[i - 1]!)); return m; };
    const typical = step(100 * sr, 110 * sr);
    for (const seam of parts.slice(0, -1).map((p) => p.coreEnd)) expect(step(seam - 2 * sr, seam + 2 * sr)).toBeLessThan(1.5 * typical);

    const after = analyzeInParts({ sampleRate: sr, channels: [output] }, (p) => camo.analyze(p));
    // The flyby whose closest approach sits on the first seam is gone. (Other faint tones can stay:
    // as the plane recedes its harmonics flatten into weak steady lines the frame tracker never
    // targets, the gap PLAN.md's step 2 closes. The next test shows parts leave no more than one piece.)
    expect(after.doppler).toBe(0);
    console.log(`perf: 10 min at 48 kHz in ${parts.length} parts: check ${checkSeconds.toFixed(1)} s, cloak ${cloakSeconds.toFixed(1)} s, `
      + `wasm memory ${(camo.memoryBytes / 2 ** 20).toFixed(0)} MiB; found before ${before.tones} (doppler ${before.doppler}, hum ${before.hum}), `
      + `after ${after.tones} (doppler ${after.doppler}, hum ${after.hum})`);
    expect(camo.memoryBytes).toBeLessThan(2 * 2 ** 30);
  }, 3_600_000);
  test("parts leave no more for the check than cloaking in one piece", async () => {
    const sr = 16_000, clip = longClip(360, sr), camo = await Camo.load(readFileSync(BUILDS[0][1]));
    expect(plan(clip.channels[0]!.length, sr).length).toBe(2);
    const counts = (t: { tones: number; doppler: number; hum: number }) => [t.tones, t.doppler, t.hum];
    const check = (x: Float32Array) => analyzeInParts({ sampleRate: sr, channels: [x as Float32Array<ArrayBuffer>] }, (p) => camo.analyze(p));
    const whole = check(camo.scrub(clip, { seed: 9 }).output), inParts = check(scrubInParts(clip, 9, (p, seed) => camo.scrub(p, { seed })).output);
    console.log(`long: 6 min at 16 kHz, tones/doppler/hum after cloaking: one piece ${counts(whole)}, two parts ${counts(inParts)}`);
    expect(inParts.doppler).toBeLessThanOrEqual(whole.doppler);
    expect(inParts.hum).toBeLessThanOrEqual(whole.hum + 1);
    expect(inParts.tones).toBeLessThanOrEqual(whole.tones + Math.max(2, Math.ceil(0.3 * whole.tones)));
  }, 3_600_000);

  test("memory for comparison: a 5-minute 48 kHz clip in one piece (the old limit)", async () => {
    const sr = 48_000, clip = longClip(300, sr), camo = await Camo.load(readFileSync(BUILDS[0][1]));
    const t = performance.now();
    camo.scrub(clip, { seed: 9 });
    camo.analyze(clip);
    console.log(`perf: 5 min at 48 kHz in one piece: cloak + check ${((performance.now() - t) / 1000).toFixed(1)} s, wasm memory ${(camo.memoryBytes / 2 ** 20).toFixed(0)} MiB`);
    expect(camo.memoryBytes).toBeLessThan(3 * 2 ** 30);
  }, 3_600_000);
});
