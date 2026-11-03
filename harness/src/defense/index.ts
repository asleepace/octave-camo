/**
 * Defense registry and chains.
 *
 * A chain is modules joined by "+", each with optional options in parentheses:
 *   hum+lowband(mode=regenerate,cutoff=300)+scurve(z=4)
 * Several chains (for comparisons) are separated by ";".
 */
import { decoy } from "./decoy.ts";
import { lowband } from "./lowband.ts";
import { hum, informed, legacy, subtract } from "./modules.ts";
import { scurve } from "./scurve.ts";
import type { Defense, DefenseContext, DefenseModule } from "./types.ts";

export const modules: DefenseModule[] = [hum, subtract, lowband, scurve, decoy, informed, legacy] as DefenseModule[];

export type ChainStep = { module: DefenseModule; options: Record<string, string>; label: string };
export type Chain = { label: string; steps: ChainStep[] };

export function parseChain(spec: string): Chain {
  const steps = spec.split("+").map((s) => s.trim()).filter(Boolean).map((part): ChainStep => {
    const m = /^([a-z][\w-]*)(?:\((.*)\))?$/i.exec(part);
    if (!m) throw new Error(`bad chain step "${part}" (expected name or name(key=value,...))`);
    const module = modules.find((d) => d.name === m[1]);
    if (!module) throw new Error(`unknown defense "${m[1]}" (have: ${modules.map((d) => d.name).join(", ")})`);
    const options: Record<string, string> = {};
    for (const kv of (m[2] ?? "").split(",").map((s) => s.trim()).filter(Boolean)) {
      const [k, v] = kv.split("=").map((s) => s.trim());
      if (!k || v === undefined) throw new Error(`bad option "${kv}" in ${part}`);
      options[k] = v;
    }
    module.options.strict().parse(options); // validate early: unknown keys and bad values fail here
    return { module, options, label: part };
  });
  if (!steps.length) throw new Error("empty chain");
  return { label: spec.trim(), steps };
}

export const parseChains = (spec: string) => spec.split(";").map((s) => s.trim()).filter(Boolean).map(parseChain);

export function needs(chain: Chain): Set<"clip" | "tracks"> {
  return new Set(chain.steps.flatMap((s) => s.module.requires ?? []));
}

export async function runChain(chain: Chain, x: Float32Array, ctx: DefenseContext): Promise<Float32Array> {
  let y = x;
  for (const step of chain.steps) {
    const defense: Defense = step.module.create(step.module.options.parse(step.options));
    y = await defense.process(y, ctx);
  }
  // Never clip: scale down if a decoy or regeneration pushed the peak over full scale.
  let peak = 0;
  for (const v of y) peak = Math.max(peak, Math.abs(v));
  if (peak > 0.99) for (let i = 0; i < y.length; i++) y[i]! *= 0.99 / peak;
  return y;
}

export function describeModules(): string {
  return modules.map((m) => {
    const shape = m.options.shape as Record<string, { def?: unknown; _zod?: { def?: { defaultValue?: unknown } } }>;
    const opts = Object.keys(shape).map((k) => {
      const d = shape[k]?._zod?.def?.defaultValue;
      return d === undefined ? k : `${k}=${typeof d === "function" ? (d as () => unknown)() : d}`;
    });
    return `  ${m.name.padEnd(9)} [${m.tier}] ${m.summary}${opts.length ? `\n            options: ${opts.join(", ")}` : ""}`;
  }).join("\n");
}

/** The recommended offline chain, the same one the Swift pipeline and the web app run by default. */
export const DEFAULT_CHAIN = "hum+subtract+scurve+lowband";
