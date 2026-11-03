/**
 * Development-only stand-in for the WebAssembly scrubber (used when public/octave-camo.wasm has
 * not been built). It is NOT a defense: it just high-passes below the cutoff so the UI has
 * something to show. Production builds never load it.
 */
import type { Clip, Flicker, Profiles, Samples, Trace } from "./camo.ts";
import type { ScrubRequest } from "./protocol.ts";

function mono(clip: Clip): Samples {
  const n = clip.channels[0]!.length, out = new Float32Array(n);
  for (const ch of clip.channels) for (let i = 0; i < n; i++) out[i]! += ch[i]! / clip.channels.length;
  return out;
}

export const standIn = {
  kind: "stand-in" as const,
  analyze(clip: Clip): Trace {
    // Pretend: count proportional to low-band energy, so before/after differ.
    const x = mono(clip);
    let low = 0, prev = 0;
    for (let i = 0; i < x.length; i++) { prev += (x[i]! - prev) * 0.02; low += prev * prev; }
    const tones = Math.min(9, Math.round(Math.sqrt(low / x.length) * 400));
    return { tones, doppler: Math.round(tones / 3), hum: tones > 2 ? 2 : 0, flybys: tones > 4 ? 1 : 0 };
  },
  flicker(p: Profiles, clean: boolean): Flicker {
    // With VITE_STANDIN_FLICKER=1 it always "finds" flicker (no-op gains), to exercise the
    // re-encode path; otherwise it never does (dev only, either way).
    const found = import.meta.env.VITE_STANDIN_FLICKER === "1";
    const gains = clean ? new Float32Array(p.frames * p.rows).fill(1) : undefined;
    return { checked: true, detected: found, z: found ? 300 : 5, flickerHz: found ? 120 : 0, readoutMs: found ? 16 : 0,
      after: { detected: false, z: 5 }, passesRemoved: found ? 1 : 0, gains };
  },
  scrub(clip: Clip, r: ScrubRequest) {
    const x = mono(clip), y = new Float32Array(x.length);
    const a = Math.exp((-2 * Math.PI * r.cutoff) / clip.sampleRate);
    let lp1 = 0, lp2 = 0;
    for (let i = 0; i < x.length; i++) {
      lp1 = a * lp1 + (1 - a) * x[i]!;
      lp2 = a * lp2 + (1 - a) * lp1;
      y[i] = x[i]! - lp2;
    }
    return { output: y, log: ["mono: averaged", "stand-in: high-passed (dev only, not a defense)"] };
  },
};
