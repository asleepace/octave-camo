import { z } from "zod";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { run } from "./clip.ts";

/** Mirrors the Swift `octave-camo analyze --json` payload. */
const Geometry = z.object({ f0: z.number(), speed: z.number(), t0: z.number(), distance: z.number() });
const Report = z.object({
  kind: z.enum(["hum", "steady", "doppler", "noFit"]),
  meanFrequency: z.number(),
  minFrequency: z.number(),
  maxFrequency: z.number(),
  duration: z.number(),
  fit: z.object({ geometry: Geometry, rms: z.number() }).nullish(),
});
export const AnalysisJSON = z.object({
  consensus: Geometry.nullish(),
  tracks: z.array(Report),
});
export type Analysis = z.infer<typeof AnalysisJSON>;
export type Estimate = z.infer<typeof Geometry>;

const SWIFT_BINARY = join(import.meta.dir, "..", "..", ".build", "release", "octave-camo");
const REFERENCE = ["python3", join(import.meta.dir, "..", "..", "reference", "analyze_json.py")];

/**
 * Runs the analyzer CLI: $OCTAVE_CAMO_CMD if set, else the Swift release build if it exists,
 * else the NumPy reference (same interface and JSON).
 */
export class Analyzer {
  readonly command: string[];

  constructor(command = process.env.OCTAVE_CAMO_CMD) {
    this.command = command?.trim()
      ? command.trim().split(/\s+/)
      : existsSync(SWIFT_BINARY) ? [SWIFT_BINARY] : REFERENCE;
  }

  async analyze(wav: string, thresholdDB: number): Promise<Analysis> {
    const out = await run([...this.command, "analyze", wav, "--json", "--threshold", String(thresholdDB)]);
    return AnalysisJSON.parse(JSON.parse(out));
  }

  /** `steps` (reference analyzer only) picks scrub stages, e.g. ["mono", "hum", "subtract"]. */
  async scrub(inWav: string, outWav: string, steps?: string[]): Promise<void> {
    await run([...this.command, "scrub", inWav, outWav], steps ? { SCRUB_STEPS: steps.join(",") } : undefined);
  }
}
