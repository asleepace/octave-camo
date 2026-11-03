import type { z } from "zod";
import type { ClipInfo } from "../clip.ts";
import type { FlightTrack } from "../track.ts";

/** What a defense may know. Offline defenses use only `sampleRate` and `seed`. */
export type DefenseContext = {
  sampleRate: number;
  /** Seeds every random choice, so runs are reproducible. */
  seed: number;
  /** Recording location and time (the phone always knows these). */
  clip?: ClipInfo;
  /** Nearby ADS-B tracks: only for online defenses. */
  tracks?: FlightTrack[];
  log: (line: string) => void;
};

/** One processing step: full-rate mono in, full-rate mono out. */
export interface Defense {
  process(x: Float32Array, ctx: DefenseContext): Float32Array | Promise<Float32Array>;
}

export type Tier = "basic" | "offline" | "online" | "experimental";

export type DefenseModule<S extends z.ZodObject = z.ZodObject> = {
  name: string;
  summary: string;
  tier: Tier;
  /** Context the module can't run without. */
  requires?: ("clip" | "tracks")[];
  /** Options, all with defaults; parsed from `name(key=value,...)` strings. */
  options: S;
  create(options: z.infer<S>): Defense;
};

/** Keeps each module's option types tied to its schema. */
export const defineDefense = <S extends z.ZodObject>(m: DefenseModule<S>) => m;
