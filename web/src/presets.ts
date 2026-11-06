/**
 * The cloak's presets, shared by the page and the lab's runner (web/scripts/cloak-raw.ts): which
 * stages run, and how much of the low band's slow loudness goes (FLATTEN). One place to swap them.
 */
import type { Flatten, Step } from "./engine/camo.ts";

export const PRESETS = {
  // The low band's slow loudness: gentle on Full and Light (a plane's swell, little else), strong on
  // Experimental (a quicker pass too). Swap them here; FLATTEN names the strengths.
  full: { label: "Full", steps: ["hum", "subtract", "scurve", "lowband"], note: "planes, trains and ships", flatten: "gentle" },
  experimental: { label: "Experimental", steps: ["hum", "subtract", "scurve", "lowband", "lines"], flatten: "strong",
                  note: "full, plus every tone the check finds filled in and quicker low-band swells flattened (being tested)" },
  light: { label: "Light", steps: ["hum", "lowband"], note: "faster, but partial: misses trains and close passes", flatten: "gentle" },
  hum: { label: "Hum only", steps: ["hum"], note: "partial: removes the recording-time clock only", flatten: "off" },
} as const satisfies Record<string, { label: string; steps: readonly Step[]; note: string; flatten: Flatten }>;

export type Preset = keyof typeof PRESETS;
