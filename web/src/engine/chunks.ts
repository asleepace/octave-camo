/**
 * Long clips in parts. The scrubber holds a clip's samples several times over in WebAssembly memory
 * (and `scurve` costs grow with the square of the length), so a clip longer than
 * SINGLE_PASS_SECONDS is cloaked and checked as overlapping parts of at most PART_SECONDS, then
 * stitched back together. Shorter clips go through in one piece, exactly as before.
 *
 * Each part carries PAD_SECONDS of the clip on either side of its own stretch, so every stage has
 * settled by the time it reaches a seam. Seams are crossfaded over FADE_SECONDS, separately above
 * and below CROSSOVER_HZ: above it the two parts are mostly the same kept sound, below it mostly
 * each part's own fresh noise. In each band the fade's gains follow how alike the two parts are
 * there (their correlation ρ), so the level stays put either way: weights adding to one for the
 * same sound (ρ = 1), powers adding to one for unrelated noise (ρ = 0), and in between for a mix.
 * The check's tones are joined across seams, so a tone that crosses one is counted once.
 */
import { type Clip, type Found, MAX_FOUND, type Samples, type Trace } from "./camo.ts";

/** Clips up to this long are processed in one piece. */
export const SINGLE_PASS_SECONDS = 300;
/** Longest stretch of a clip one part owns (parts are balanced: 10 minutes → 3 × 200 s). */
export const PART_SECONDS = 240;
/** Clip either side of a part's stretch that it also processes. */
export const PAD_SECONDS = 10;
/** Crossfade length at each seam (inside the padding, well clear of a part's edges). */
export const FADE_SECONDS = 2;
/** Above this the parts' sound is kept (same signal); below it the low band is regenerated noise. */
export const CROSSOVER_HZ = 300;

/** Sample indices: [start, end) is processed; [coreStart, coreEnd) is the stretch the part owns. */
export type Part = { start: number; end: number; coreStart: number; coreEnd: number };

export function plan(frames: number, sampleRate: number): Part[] {
  if (frames <= SINGLE_PASS_SECONDS * sampleRate) return [{ start: 0, end: frames, coreStart: 0, coreEnd: frames }];
  const n = Math.ceil(frames / (PART_SECONDS * sampleRate)), pad = Math.round(PAD_SECONDS * sampleRate);
  const cuts = Array.from({ length: n + 1 }, (_, k) => Math.round((k * frames) / n));
  return cuts.slice(0, -1).map((coreStart, k) => {
    const coreEnd = cuts[k + 1]!;
    return { start: Math.max(0, coreStart - pad), end: Math.min(frames, coreEnd + pad), coreStart, coreEnd };
  });
}

export const slice = (clip: Clip, p: Part): Clip =>
  ({ sampleRate: clip.sampleRate, channels: clip.channels.map((ch) => ch.subarray(p.start, p.end) as Samples) });

/** Second-order low-pass (RBJ), run causally; `x - lowpass(x)` is then its exact complement. */
function lowpass(x: Float32Array, sampleRate: number, hz: number): Float32Array {
  const w = (2 * Math.PI * hz) / sampleRate, alpha = Math.sin(w) / Math.SQRT2, cos = Math.cos(w), a0 = 1 + alpha;
  const b0 = (1 - cos) / 2 / a0, b1 = (1 - cos) / a0, b2 = b0, a1 = (-2 * cos) / a0, a2 = (1 - alpha) / a0;
  const y = new Float32Array(x.length);
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  for (let i = 0; i < x.length; i++) {
    const v = b0 * x[i]! + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1; x1 = x[i]!; y2 = y1; y1 = v; y[i] = v;
  }
  return y;
}

/** Correlation of a and b from index `from` on, clamped to [0, 1]. */
function correlation(a: Float32Array, b: Float32Array, from: number): number {
  let ab = 0, aa = 0, bb = 0;
  for (let i = from; i < a.length; i++) { ab += a[i]! * b[i]!; aa += a[i]! * a[i]!; bb += b[i]! * b[i]!; }
  return aa > 0 && bb > 0 ? Math.min(1, Math.max(0, ab / Math.sqrt(aa * bb))) : 1;
}

/** (1 − w)·a + w·b, scaled so the result's power stays that of either side for correlation ρ. */
const fade = (a: number, b: number, w: number, rho: number) =>
  ((1 - w) * a + w * b) / Math.sqrt((1 - w) ** 2 + w ** 2 + 2 * rho * w * (1 - w));

/** Joins the parts' outputs (each covering its part's [start, end)) into one clip of `frames`. */
export function stitch(parts: Part[], outputs: Float32Array[], frames: number, sampleRate: number): Samples {
  if (parts.length !== outputs.length) throw new Error("one output per part");
  parts.forEach((p, k) => { if (outputs[k]!.length !== p.end - p.start) throw new Error(`part ${k + 1}: output is the wrong length`); });
  if (parts.length === 1) return outputs[0]!.slice() as Samples;
  const out = new Float32Array(frames);
  const half = Math.round((FADE_SECONDS * sampleRate) / 2), warm = Math.round(0.5 * sampleRate);
  const at = (k: number, i: number) => outputs[k]![i - parts[k]!.start]!;
  parts.forEach((p, k) => {
    const from = k === 0 ? 0 : p.coreStart + half, to = k === parts.length - 1 ? frames : p.coreEnd - half;
    out.set(outputs[k]!.subarray(from - p.start, to - p.start), from);
  });
  for (let k = 0; k + 1 < parts.length; k++) {
    const seam = parts[k]!.coreEnd, s0 = seam - half, s1 = seam + half;
    // Filter from a little before the fade so the low-pass has settled; both parts cover it.
    const f0 = Math.max(parts[k + 1]!.start, s0 - warm);
    const grab = (j: number) => Float32Array.from({ length: s1 - f0 }, (_, i) => at(j, f0 + i));
    const a = grab(k), b = grab(k + 1), aLow = lowpass(a, sampleRate, CROSSOVER_HZ), bLow = lowpass(b, sampleRate, CROSSOVER_HZ);
    const aHigh = a.map((v, j) => v - aLow[j]!), bHigh = b.map((v, j) => v - bLow[j]!);
    const from = s0 - f0, rhoLow = correlation(aLow, bLow, from), rhoHigh = correlation(aHigh, bHigh, from);
    for (let i = s0; i < s1; i++) {
      const u = (i - s0 + 0.5) / (s1 - s0), w = 0.5 - 0.5 * Math.cos(Math.PI * u), j = i - f0;
      out[i] = fade(aHigh[j]!, bHigh[j]!, w, rhoHigh) + fade(aLow[j]!, bLow[j]!, w, rhoLow);
    }
  }
  return out as Samples;
}

/** Which kind wins when one tone was classed differently on either side of a seam. */
const RISK: Record<Found["kind"], number> = { doppler: 3, hum: 2, noFit: 1, steady: 0 };

/** The same tone, seen by two neighbouring parts: overlapping (or touching) in time and frequency. */
function sameTone(a: Found, b: Found): boolean {
  const margin = Math.max(2, 0.002 * (a.lo + a.hi) / 2);
  return a.start <= b.end + 1 && b.start <= a.end + 1 && a.lo - margin <= b.hi && b.lo - margin <= a.hi;
}

/**
 * One trace for the whole clip from the parts' traces: times moved to the clip's, a tone found by
 * two neighbouring parts joined into one, and the counts corrected for those joins. (A part's
 * outline list is capped at MAX_FOUND; past that, joins are missed and the counts can run high,
 * which errs on the side of caution.)
 */
export function mergeTraces(parts: Part[], traces: Trace[], sampleRate: number): Trace {
  if (parts.length !== traces.length) throw new Error("one trace per part");
  if (parts.length === 1) return traces[0]!;
  const boxes = traces.flatMap((t, k) => t.found.map((f) => {
    const shift = parts[k]!.start / sampleRate;
    return { part: k, f: { ...f, start: f.start + shift, end: f.end + shift } };
  }));
  // Union-find over pairs from neighbouring parts.
  const root = boxes.map((_, i) => i);
  const find = (i: number): number => (root[i] === i ? i : (root[i] = find(root[i]!)));
  for (let i = 0; i < boxes.length; i++) {
    for (let j = 0; j < boxes.length; j++) {
      if (boxes[j]!.part === boxes[i]!.part + 1 && sameTone(boxes[i]!.f, boxes[j]!.f)) root[find(j)] = find(i);
    }
  }
  const groups = new Map<number, Found[]>();
  boxes.forEach((b, i) => { const r = find(i); groups.set(r, [...(groups.get(r) ?? []), b.f]); });
  const merged: Found[] = [];
  let joins = 0;
  const lost = { doppler: 0, hum: 0 };
  for (const g of groups.values()) {
    const kind = g.reduce((best, f) => (RISK[f.kind] > RISK[best] ? f.kind : best), g[0]!.kind);
    merged.push({ start: Math.min(...g.map((f) => f.start)), end: Math.max(...g.map((f) => f.end)),
                  lo: Math.min(...g.map((f) => f.lo)), hi: Math.max(...g.map((f) => f.hi)), kind });
    joins += g.length - 1;
    for (const k of ["doppler", "hum"] as const) lost[k] += g.filter((f) => f.kind === k).length - (kind === k ? 1 : 0);
  }
  const sum = (key: "tones" | "doppler" | "hum" | "flybys") => traces.reduce((s, t) => s + t[key], 0);
  const doppler = sum("doppler") - lost.doppler;
  merged.sort((a, b) => b.end - b.start - (a.end - a.start));
  return {
    tones: sum("tones") - joins, doppler, hum: sum("hum") - lost.hum,
    // Fits aren't in the outline list; a joined Doppler tone keeps at most one.
    flybys: Math.min(sum("flybys"), doppler),
    found: merged.slice(0, MAX_FOUND),
  };
}

export type PartProgress = (part: number, parts: number) => void;

/** Cloaks a clip part by part (one part for a short clip). Part k uses seed + k. */
export function scrubInParts(clip: Clip, seed: number, scrubPart: (clip: Clip, seed: number) => { output: Samples; log: string[] },
                             progress: PartProgress = () => {}): { output: Samples; log: string[] } {
  const frames = clip.channels[0]?.length ?? 0, parts = plan(frames, clip.sampleRate);
  const results = parts.map((p, k) => {
    progress(k + 1, parts.length);
    return scrubPart(slice(clip, p), seed === 0 ? 0 : ((seed - 1 + k) % Number.MAX_SAFE_INTEGER) + 1);
  });
  const log = parts.length === 1 ? results[0]!.log
    : [`cloaked in ${parts.length} parts of about ${Math.round((parts[0]!.coreEnd - parts[0]!.coreStart) / clip.sampleRate)} s, crossfaded at the seams`,
       ...results.flatMap((r, k) => r.log.map((line) => `part ${k + 1} · ${line}`))];
  return { output: stitch(parts, results.map((r) => r.output), frames, clip.sampleRate), log };
}

/** Checks a clip part by part, joining tones across seams. */
export function analyzeInParts(clip: Clip, analyzePart: (clip: Clip) => Trace, progress: PartProgress = () => {}): Trace {
  const frames = clip.channels[0]?.length ?? 0, parts = plan(frames, clip.sampleRate);
  return mergeTraces(parts, parts.map((p, k) => { progress(k + 1, parts.length); return analyzePart(slice(clip, p)); }), clip.sampleRate);
}

