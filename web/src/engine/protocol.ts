/** Messages between the page and the scrub worker, validated on both sides. */
import { z } from "zod";
import { STEPS } from "./camo.ts";

const samples = z.instanceof(Float32Array);

/** Which opened file a request is about; echoed in every reply so stale replies can be dropped. */
const token = z.number().int().nonnegative();

const clip = {
  token,
  sampleRate: z.number().int().min(8_000).max(384_000),
  channels: z.array(samples).min(1).max(8),
};
const sameLength = (r: { channels: Float32Array[] }) => r.channels.every((c) => c.length === r.channels[0]!.length && c.length > 0);
const sameLengthIssue = { message: "channels must be non-empty and the same length", path: ["channels"] };

export const AnalyzeRequest = z.object({ type: z.literal("analyze"), ...clip }).refine(sameLength, sameLengthIssue);

export const ScrubRequest = z.object({
  type: z.literal("scrub"),
  ...clip,
  steps: z.array(z.enum(STEPS)),
  seed: z.number().int().min(1).max(Number.MAX_SAFE_INTEGER),
  cutoff: z.number().min(50).max(2_000),
  keepVoice: z.boolean(),
}).refine(sameLength, sameLengthIssue);
export type ScrubRequest = z.infer<typeof ScrubRequest>;

export const FlickerRequest = z.object({
  type: z.literal("flicker"),
  token,
  frames: z.number().int().min(1),
  strips: z.number().int().min(1).max(64),
  rows: z.number().int().min(8).max(1024),
  values: samples,
  times: samples,
  clean: z.boolean(),
  /** Echoed back so the page can tell the clip scan from the saved-file check. */
  purpose: z.enum(["clip", "verify"]),
  /** Echoed back: which save a verify belongs to (a later save makes it stale). */
  seq: z.number().int().nonnegative().default(0),
}).refine((r) => r.values.length === r.frames * r.strips * r.rows && r.times.length === r.frames,
  { message: "profile size mismatch", path: ["values"] });
export type FlickerRequest = z.infer<typeof FlickerRequest>;

export const Request = z.union([AnalyzeRequest, ScrubRequest, FlickerRequest]);
export type Request = z.infer<typeof Request>;

const Trace = z.object({ tones: z.number(), doppler: z.number(), hum: z.number(), flybys: z.number() });
/** Display spectrogram (computed in the worker so a long clip doesn't freeze the page). */
const Spectrum = z.object({ db: samples, frames: z.number().int().nonnegative(), hop: z.number().positive() });
/** The 2D heatmap's spectrogram (see spectrum.ts detail()). */
const Detail = z.object({
  db: samples, columns: z.number().int().min(1), rows: z.number().int().min(2),
  seconds: z.number().nonnegative(), fLo: z.number().positive(), fHi: z.number().positive(),
}).refine((d) => d.db.length === d.columns * d.rows && d.fHi > d.fLo, { message: "heatmap size mismatch", path: ["db"] });

export const Stage = z.enum(["loading", "analyzing", "scrubbing", "verifying"]);
export type Stage = z.infer<typeof Stage>;

export const WorkerMessage = z.discriminatedUnion("type", [
  /** Sent once the scrubber is loaded: SHA-256 of the exact wasm bytes it compiled. */
  z.object({ type: z.literal("engine"), token, kind: z.enum(["wasm", "stand-in"]), sha256: z.string().regex(/^([0-9a-f]{64}|)$/),
    /** Set when the scrubber couldn't be loaded (the page can't cloak anything). */
    failed: z.string().optional() }),
  z.object({ type: z.literal("stage"), token, stage: Stage }),
  /** Sent once at startup: the landing heatmap (an illustration, computed here to keep the page responsive). */
  z.object({ type: z.literal("demo"), token, input: Detail, output: Detail }),
  z.object({ type: z.literal("analysis"), token, trace: Trace, spectrum: Spectrum, detail: Detail, engine: z.enum(["wasm", "stand-in"]) }),
  z.object({
    type: z.literal("result"),
    token,
    output: samples,
    spectrum: Spectrum,
    detail: Detail,
    log: z.array(z.string()),
    after: Trace,
    ms: z.number(),
    engine: z.enum(["wasm", "stand-in"]),
  }),
  z.object({
    type: z.literal("flicker"),
    token,
    purpose: z.enum(["clip", "verify"]),
    seq: z.number(),
    checked: z.boolean(),
    detected: z.boolean(),
    z: z.number(),
    flickerHz: z.number(),
    readoutMs: z.number(),
    after: z.object({ detected: z.boolean(), z: z.number() }),
    passesRemoved: z.number(),
    gains: samples.optional(),
  }),
  z.object({ type: z.literal("error"), token, scope: z.enum(["audio", "picture"]), message: z.string(),
    /** For picture errors: which scan failed (the clip's, or a saved file's check, by save seq). */
    purpose: z.enum(["clip", "verify"]).optional(), seq: z.number().optional() }),
]);
export type WorkerMessage = z.infer<typeof WorkerMessage>;
