/** The small modules: hum notches, informed cancellation (online), and the legacy NumPy scrub. */
import { z } from "zod";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Analyzer } from "../analyzer.ts";
import { informedCancel } from "../cancel.ts";
import { median, readMono, writeMonoWav } from "../dsp.ts";
import { defaultMatchedConfig, whitenedSpectrogram } from "../matched.ts";
import { decimate, Rng } from "./signal.ts";
import { defineDefense } from "./types.ts";

/** Centered moving average of x², square-rooted: a smooth RMS envelope. */
function envelope(x: Float32Array, length: number): Float32Array {
  const n = x.length, prefix = new Float64Array(n + 1), out = new Float32Array(n), h = length >> 1;
  for (let i = 0; i < n; i++) prefix[i + 1] = prefix[i]! + x[i]! * x[i]!;
  for (let i = 0; i < n; i++) {
    const lo = Math.max(0, i - h), hi = Math.min(n - 1, i + h);
    out[i] = Math.sqrt((prefix[hi + 1]! - prefix[lo]!) / (hi - lo + 1));
  }
  return out;
}

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
    /** Mains frequencies, "|"-separated (both by default: notching only the local grid would leave
     *  dips that say which grid, and so which part of the world). 0 disables. */
    mains: z.string().default("50|60").transform((v, ctx) => {
      const values = v.split("|").map(Number);
      if (values.some((n) => !Number.isFinite(n) || n < 0)) {
        ctx.addIssue({ code: "custom", message: "mains must be numbers like 50|60 (0 disables)" });
      }
      return values.filter((n) => n > 0);
    }),
    maxHz: z.coerce.number().default(400),
    q: z.coerce.number().positive().default(30),
    /** Refill each notch with noise at the neighbouring bands' level, so no dips are left behind. */
    refill: z.stringbool().default(true),
  }),
  create: (o) => ({
    process(x, ctx) {
      const sr = ctx.sampleRate, freqs: number[] = [];
      for (const base of o.mains) {
        for (let f = base; f < o.maxHz; f += base) if (!freqs.some((g) => Math.abs(g - f) < 0.5)) freqs.push(f);
      }
      freqs.sort((a, b) => a - b);
      let y = x;
      for (const f of freqs) y = notch(y, f, o.q, sr);
      if (o.refill && freqs.length) {
        // For each notch: a narrow band of noise (white noise minus its own notch) at the long-term
        // median level of the notched signal's neighbouring bands, two bandwidths either side.
        // The level is constant on purpose: following the neighbours over time would re-imprint
        // when a moving tone swept past them, which is the timing a matched attacker integrates.
        const rng = new Rng(ctx.seed ^ 0x5eed), L = Math.max(1, Math.round(0.25 * sr));
        const white = Float32Array.from({ length: x.length }, () => rng.gaussian());
        const out = Float32Array.from(y);
        for (const f of freqs) {
          const bw = f / o.q;
          const sides = [f - 2 * bw, f + 2 * bw].filter((g) => g > 0 && !freqs.some((h) => Math.abs(h - g) < 1.5 * h / o.q));
          if (!sides.length) continue;
          let level = 0;
          for (const g of sides) {
            const n = notch(y, g, o.q, sr), band = new Float32Array(x.length);
            for (let i = 0; i < x.length; i++) band[i] = y[i]! - n[i]!;
            const e = envelope(band, L), power = new Float64Array(Math.ceil(x.length / L));
            for (let j = 0; j < power.length; j++) power[j] = e[Math.min(x.length - 1, j * L)]! ** 2;
            level += (median(power) * (f / g)) / sides.length;                // bandwidth ∝ f
          }
          const nn = notch(white, f, o.q, sr), fill = new Float32Array(x.length);
          for (let i = 0; i < x.length; i++) fill[i] = white[i]! - nn[i]!;
          let own = 0;
          for (let i = 0; i < x.length; i++) own += fill[i]! * fill[i]!;
          const gain = Math.sqrt(level / (own / x.length || 1));
          for (let i = 0; i < x.length; i++) out[i]! += fill[i]! * gain;
        }
        y = out;
      }
      ctx.log(`hum: notched${o.refill ? " and refilled" : ""} ${freqs.length} harmonics of ${o.mains.length ? o.mains.join(" and ") + " Hz" : "nothing"}`);
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

/** Path of the compiled Swift CLI (`swift build -c release` at the repo root), or OCTAVE_CAMO_BIN. */
export const swiftBinary = () =>
  process.env.OCTAVE_CAMO_BIN ?? join(import.meta.dir, "..", "..", "..", ".build", "release", "octave-camo");

export const swift = defineDefense({
  name: "swift",
  summary: "the shipped Swift pipeline (`octave-camo scrub`): the code the web app runs as WebAssembly",
  tier: "basic",
  options: z.object({
    /** Steps separated by "|" (mono, hum, subtract, scurve, lowband, wobble); empty = the Swift default. */
    steps: z.string().regex(/^[a-z|]*$/).default(""),
  }),
  create: (o) => ({
    async process(x, ctx) {
      const bin = swiftBinary();
      if (!(await Bun.file(bin).exists())) throw new Error(`the swift module needs the Swift CLI at ${bin}: run swift build -c release`);
      const dir = await mkdtemp(join(tmpdir(), "octave-camo-swift-"));
      try {
        const inp = join(dir, "in.wav"), out = join(dir, "out.wav");
        await writeMonoWav(inp, x, ctx.sampleRate);
        const args = [bin, "scrub", inp, out, "--seed", String(ctx.seed)];
        if (o.steps) args.push("--steps", o.steps.split("|").join(","));
        const proc = Bun.spawn(args, { stdout: "pipe", stderr: "pipe" });
        const [stdout, stderr, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
        if (code !== 0) throw new Error(`octave-camo scrub failed (${code}): ${stderr.trim().split("\n")[0]}`);
        for (const line of stdout.trim().split("\n")) if (line) ctx.log(`swift: ${line}`);
        return await readMono(out, ctx.sampleRate);
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    },
  }),
});
