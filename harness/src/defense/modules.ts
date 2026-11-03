/** The small modules: hum notches, informed cancellation (online), and the legacy NumPy scrub. */
import { z } from "zod";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Analyzer } from "../analyzer.ts";
import { informedCancel } from "../cancel.ts";
import { readMono, writeMonoWav } from "../dsp.ts";
import { defaultMatchedConfig, whitenedSpectrogram } from "../matched.ts";
import { decimate } from "./signal.ts";
import { defineDefense } from "./types.ts";

/** Zero-phase RBJ notch. */
function notch(x: Float32Array, f: number, q: number, sampleRate: number): Float32Array {
  const w = (2 * Math.PI * f) / sampleRate, alpha = Math.sin(w) / (2 * q), cw = Math.cos(w), a0 = 1 + alpha;
  const b0 = 1 / a0, b1 = (-2 * cw) / a0, b2 = 1 / a0, a1 = (-2 * cw) / a0, a2 = (1 - alpha) / a0;
  const pass = (input: Float32Array) => {
    const out = new Float32Array(input.length);
    let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    for (let i = 0; i < input.length; i++) {
      const xn = input[i]!, yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
      x2 = x1; x1 = xn; y2 = y1; y1 = yn; out[i] = yn;
    }
    return out;
  };
  return pass(pass(x).reverse()).reverse();
}

export const hum = defineDefense({
  name: "hum",
  summary: "notch mains harmonics (removes the grid-frequency clock)",
  tier: "basic",
  options: z.object({
    mains: z.coerce.number().min(0).default(60),
    maxHz: z.coerce.number().default(400),
    q: z.coerce.number().positive().default(30),
  }),
  create: (o) => ({
    process(x, ctx) {
      let y = x, count = 0;
      for (let f = o.mains; o.mains > 0 && f < o.maxHz; f += o.mains, count++) y = notch(y, f, o.q, ctx.sampleRate);
      ctx.log(`hum: notched ${count} harmonics of ${o.mains} Hz`);
      return y;
    },
  }),
});

export const informed = defineDefense({
  name: "informed",
  summary: "cancel each nearby aircraft along its exact curve at the true location (needs tracks)",
  tier: "online",
  requires: ["clip", "tracks"],
  options: z.object({}),
  create: () => ({
    process(x, ctx) {
      if (!ctx.clip || !ctx.tracks) throw new Error("informed needs the clip location and flight tracks");
      const { x: low, rate } = decimate(x, ctx.sampleRate, 4_000);
      const cfg = { ...defaultMatchedConfig, sampleRate: rate };
      const y = Float32Array.from(x);
      const reports = informedCancel(y, ctx.sampleRate, whitenedSpectrogram(low, cfg), ctx.tracks, ctx.clip, undefined, cfg);
      const hit = reports.filter((r) => r.cancelled);
      ctx.log(`informed: cancelled ${hit.length} of ${reports.length} aircraft` +
        (hit.length ? ` (${hit.map((r) => `${r.callsign ?? r.id} ${r.f0.toFixed(1)} Hz`).join(", ")})` : ""));
      return y;
    },
  }),
});

export const legacy = defineDefense({
  name: "legacy",
  summary: "the original scrub via the analyzer command: per-frame tone tracking + subtraction (best on loud, close passes), optional wobble",
  tier: "basic",
  options: z.object({
    /** Stages separated by "|": mono, hum, subtract, flatten, wobble. */
    steps: z.string().regex(/^[a-z|]+$/).default("mono|hum|subtract|wobble"),
  }),
  create: (o) => ({
    async process(x, ctx) {
      const dir = await mkdtemp(join(tmpdir(), "octave-camo-legacy-"));
      try {
        const inp = join(dir, "in.wav"), out = join(dir, "out.wav");
        await writeMonoWav(inp, x, ctx.sampleRate);
        const steps = o.steps.split("|");
        await new Analyzer().scrub(inp, out, steps);
        ctx.log(`legacy: ${steps.join(", ")}`);
        return await readMono(out, ctx.sampleRate);
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    },
  }),
});

/** Per-frame tone tracking + subtraction on its own (the Swift ToneSubtraction stage, run via the analyzer). */
export const subtract = defineDefense({
  name: "subtract",
  summary: "track tones frame by frame and cancel them: handles loud, close passes that lowband's cutoff misses",
  tier: "basic",
  options: z.object({}),
  create: () => legacy.create({ steps: "subtract" }),
});
