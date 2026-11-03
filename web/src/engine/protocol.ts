/** Messages between the page and the scrub worker, validated on both sides. */
import { z } from "zod";
import { STEPS } from "./camo.ts";

const samples = z.instanceof(Float32Array);

const clip = {
  sampleRate: z.number().int().min(8_000).max(384_000),
  channels: z.array(samples).min(1).max(8),
};

export const AnalyzeRequest = z.object({ type: z.literal("analyze"), ...clip });

export const ScrubRequest = z.object({
  type: z.literal("scrub"),
  ...clip,
  steps: z.array(z.enum(STEPS)),
  seed: z.number().int().min(1).max(Number.MAX_SAFE_INTEGER),
  cutoff: z.number().min(50).max(2_000),
  keepVoice: z.boolean(),
});
export type ScrubRequest = z.infer<typeof ScrubRequest>;

export const FlickerRequest = z.object({
  type: z.literal("flicker"),
  frames: z.number().int().min(1),
  strips: z.number().int().min(1).max(64),
  rows: z.number().int().min(8).max(1024),
  values: samples,
  times: samples,
  clean: z.boolean(),
  /** Echoed back so the page can tell the clip scan from the saved-file check. */
  purpose: z.enum(["clip", "verify"]),
});
export type FlickerRequest = z.infer<typeof FlickerRequest>;

export const Request = z.discriminatedUnion("type", [AnalyzeRequest, ScrubRequest, FlickerRequest]);
export type Request = z.infer<typeof Request>;

const Trace = z.object({ tones: z.number(), doppler: z.number(), hum: z.number(), flybys: z.number() });

export const Stage = z.enum(["loading", "analyzing", "scrubbing", "verifying"]);
export type Stage = z.infer<typeof Stage>;

export const WorkerMessage = z.discriminatedUnion("type", [
  z.object({ type: z.literal("stage"), stage: Stage }),
  z.object({ type: z.literal("analysis"), trace: Trace, engine: z.enum(["wasm", "stand-in"]) }),
  z.object({
    type: z.literal("result"),
    output: samples,
    log: z.array(z.string()),
    after: Trace,
    ms: z.number(),
    engine: z.enum(["wasm", "stand-in"]),
  }),
  z.object({
    type: z.literal("flicker"),
    purpose: z.enum(["clip", "verify"]),
    detected: z.boolean(),
    z: z.number(),
    flickerHz: z.number(),
    readoutMs: z.number(),
    after: z.object({ detected: z.boolean(), z: z.number() }),
    passesRemoved: z.number(),
    gains: samples.optional(),
  }),
  z.object({ type: z.literal("error"), scope: z.enum(["audio", "picture"]), message: z.string() }),
]);
export type WorkerMessage = z.infer<typeof WorkerMessage>;
