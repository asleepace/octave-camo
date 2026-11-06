/**
 * Cloak raw mono float32 audio with the real wasm build, as the page would (long clips in parts):
 *   bun web/scripts/cloak-raw.ts <in.f32> <out.f32> <sampleRate> <full|experimental|light> [seed] [wasm]
 * For the lab (python3 -m lab cloak …): no browser, the same engine and presets as the page.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { Camo, FLATTEN, type Samples } from "../src/engine/camo.ts";
import { scrubInParts } from "../src/engine/chunks.ts";
import { PRESETS } from "../src/presets.ts";

const [input, output, rate, preset = "full", seed = "7", wasm = new URL("../public/octave-camo.wasm", import.meta.url).pathname] = process.argv.slice(2);
if (!input || !output || !rate || !(preset in PRESETS) || preset === "hum") throw new Error("usage: cloak-raw.ts <in.f32> <out.f32> <sampleRate> <full|experimental|light> [seed] [wasm]");
const bytes = readFileSync(input);
const x = new Float32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 4).slice() as Samples;
const camo = await Camo.load(readFileSync(wasm));
const chosen = PRESETS[preset as keyof typeof PRESETS];
const steps = ["mono" as const, ...chosen.steps], flattenSeconds = FLATTEN[chosen.flatten];
const t = performance.now();
const { output: y, log } = scrubInParts({ sampleRate: Number(rate), channels: [x] }, Number(seed),
  (part, s) => camo.scrub(part, { steps, seed: s, cutoff: 300, keepVoice: true, flattenSeconds }));
writeFileSync(output, new Uint8Array(y.buffer, y.byteOffset, y.byteLength));
console.error(`${preset}: ${(x.length / Number(rate)).toFixed(1)} s in ${((performance.now() - t) / 1000).toFixed(1)} s`);
for (const line of log) console.error(`  ${line}`);
