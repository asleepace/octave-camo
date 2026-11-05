/**
 * Run the page's check (the real wasm build, long clips in parts) on raw mono float32 audio and
 * print what it found as JSON: the counts, and every Doppler tone with a plausible flyby fit.
 *   bun web/scripts/check-raw.ts <in.f32> <sampleRate> [wasm]
 * For the lab (python3 -m lab check …).
 */
import { readFileSync } from "node:fs";
import { Camo, type Samples } from "../src/engine/camo.ts";
import { analyzeInParts } from "../src/engine/chunks.ts";

const [input, rate, wasm = new URL("../public/octave-camo.wasm", import.meta.url).pathname] = process.argv.slice(2);
if (!input || !rate) throw new Error("usage: check-raw.ts <in.f32> <sampleRate> [wasm]");
const bytes = readFileSync(input);
const x = new Float32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 4).slice() as Samples;
const camo = await Camo.load(readFileSync(wasm));
const t = performance.now();
const trace = analyzeInParts({ sampleRate: Number(rate), channels: [x] }, (part) => camo.analyze(part));
const { tones, doppler, hum, flybys } = trace;
console.log(JSON.stringify({
  seconds: x.length / Number(rate), took: (performance.now() - t) / 1000, tones, doppler, hum, flybys,
  passes: trace.found.filter((f) => f.kind === "doppler"),
}));
