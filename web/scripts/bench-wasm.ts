/**
 * Size and speed of one wasm build: bun web/scripts/bench-wasm.ts <file.wasm> [label]
 * Prints one JSON line: raw and gzip bytes, and the time to cloak (default steps) and check a
 * 60 s, 48 kHz clip (a flyby, hum and noise), best of two runs.
 */
import { readFileSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { Camo, type Clip } from "../src/engine/camo.ts";
import { seededRandom } from "../src/random.ts";

const [path, label = path] = process.argv.slice(2);
if (!path) throw new Error("usage: bench-wasm.ts <file.wasm> [label]");
const bytes = readFileSync(path);

function clip(seconds: number, sr: number): Clip {
  const n = seconds * sr, x = new Float32Array(n), rand = seededRandom(7);
  const c = 343, speed = 90, distance = 300, t0 = seconds / 2, f0 = 180;
  let phase = 0;
  for (let i = 0; i < n; i++) {
    const t = i / sr, dx = speed * (t - t0), r = Math.hypot(dx, distance);
    phase += (2 * Math.PI * f0 / (1 + (speed * dx) / (r * c))) / sr;
    const level = 0.08 * Math.min(1, 300 / r);
    let s = 0;
    for (let h = 1; h <= 3; h++) s += (level / h) * Math.sin(h * phase);
    x[i] = s + 0.01 * Math.sin(2 * Math.PI * 60 * t) + 0.01 * (rand() + rand() + rand() - 1.5);
  }
  return { sampleRate: sr, channels: [x] };
}

const camo = await Camo.load(bytes), input = clip(60, 48_000);
const time = (f: () => unknown) => { const t = performance.now(); f(); return (performance.now() - t) / 1000; };
let cloak = Infinity, check = Infinity, out = new Float32Array(0);
for (let k = 0; k < 2; k++) {
  cloak = Math.min(cloak, time(() => { out = camo.scrub(input, { seed: 3 }).output; }));
  check = Math.min(check, time(() => camo.analyze({ sampleRate: 48_000, channels: [out] })));
}
const after = camo.analyze({ sampleRate: 48_000, channels: [out] });
console.log(JSON.stringify({ label, raw: bytes.length, gzip: gzipSync(bytes, { level: 9 }).length,
  cloakSeconds: +cloak.toFixed(2), checkSeconds: +check.toFixed(2), after: { tones: after.tones, doppler: after.doppler, hum: after.hum } }));
