/**
 * Cloak raw mono float32 audio with the real wasm build, as the page would (long clips in parts):
 *   bun web/scripts/cloak-raw.ts <in.f32> <out.f32> <sampleRate> <full|experimental|light> [seed] [wasm]
 * For the lab (python3 -m lab cloak …): no browser, the same engine and presets as the page.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { Camo, type Samples, type Step } from "../src/engine/camo.ts";
import { scrubInParts } from "../src/engine/chunks.ts";

const PRESETS: Record<string, { steps: Step[]; flattenSeconds: number }> = {
  full: { steps: ["mono", "hum", "subtract", "scurve", "lowband"], flattenSeconds: 0 },
  experimental: { steps: ["mono", "hum", "subtract", "scurve", "lowband", "lines"], flattenSeconds: 5 },
  light: { steps: ["mono", "hum", "lowband"], flattenSeconds: 0 },
};

const [input, output, rate, preset = "full", seed = "7", wasm = new URL("../public/octave-camo.wasm", import.meta.url).pathname] = process.argv.slice(2);
if (!input || !output || !rate || !PRESETS[preset]) throw new Error("usage: cloak-raw.ts <in.f32> <out.f32> <sampleRate> <full|experimental|light> [seed] [wasm]");
const bytes = readFileSync(input);
const x = new Float32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 4).slice() as Samples;
const camo = await Camo.load(readFileSync(wasm));
const { steps, flattenSeconds } = PRESETS[preset]!;
const t = performance.now();
const { output: y, log } = scrubInParts({ sampleRate: Number(rate), channels: [x] }, Number(seed),
  (part, s) => camo.scrub(part, { steps, seed: s, cutoff: 300, keepVoice: true, flattenSeconds }));
writeFileSync(output, new Uint8Array(y.buffer, y.byteOffset, y.byteLength));
console.error(`${preset}: ${(x.length / Number(rate)).toFixed(1)} s in ${((performance.now() - t) / 1000).toFixed(1)} s`);
for (const line of log) console.error(`  ${line}`);
