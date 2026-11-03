/**
 * Experimental tier: add fake S-curves.
 *
 * Decoys are synthetic engine tones (with harmonics) along physically plausible flyby curves,
 * set just above the background in a narrow (1 Hz) band, which a machine sees, but far below
 * the background in a critical band (~35 Hz at 100 Hz), which a listener hears.
 *
 * - random: invented geometries. They poison blind attackers (wrong distance/speed fits), but an
 *   ADS-B attacker will ignore curves that match no real flight.
 * - spoof:  (online) take a real nearby flight and synthesize the curve it would have produced
 *   from a different place `spoofKm` away, so the ADS-B attacker finds a convincing wrong location.
 *   Pair with cancellation of the true curves.
 */
import { z } from "zod";
import { fft, hann, median } from "../dsp.ts";
import { SPEED_OF_SOUND } from "../geo.ts";
import { ratioCurve } from "../matched.ts";
import { TrackPath } from "../track.ts";
import { flybyRatio, perSampleFrequency } from "./flyby.ts";
import { Rng } from "./signal.ts";
import { defineDefense } from "./types.ts";

/** Background power in a 1 Hz band around f (long-term median over 1 s frames). */
function powerPerHz(x: Float32Array, sampleRate: number, f: number): number {
  const n = 1 << Math.ceil(Math.log2(sampleRate)), w = hann(n), binHz = sampleRate / n, k = Math.round(f / binHz);
  const vals: number[] = [];
  const re = new Float64Array(n), im = new Float64Array(n);
  for (let start = 0; start + n <= x.length; start += n) {
    for (let i = 0; i < n; i++) { re[i] = x[start + i]! * w[i]!; im[i] = 0; }
    fft(re, im);
    let p = 0;
    for (let j = k - 1; j <= k + 1; j++) p += re[j]! ** 2 + im[j]! ** 2;
    vals.push(p / 3);
  }
  if (!vals.length) return 1e-12;
  // |X|² of a Hann-windowed frame → power spectral density (per Hz).
  const enbw = w.reduce((a, v) => a + v * v, 0);
  return (median(vals) / (enbw * sampleRate)) * 2;
}

function addTone(y: Float32Array, freq: Float64Array, amplitude: Float64Array | number, sampleRate: number) {
  let phase = 0;
  for (let i = 0; i < y.length; i++) {
    phase += (2 * Math.PI * freq[i]!) / sampleRate;
    y[i]! += (typeof amplitude === "number" ? amplitude : amplitude[i]!) * Math.sin(phase);
  }
}

export const decoy = defineDefense({
  name: "decoy",
  summary: "inject fake flyby curves (random, or spoofed from real flights at a wrong location)",
  tier: "experimental",
  options: z.object({
    mode: z.enum(["random", "spoof"]).default("random"),
    count: z.coerce.number().int().min(0).default(3),
    /** Fundamental's power relative to the background in a 1 Hz band, dB. */
    levelDb: z.coerce.number().default(6),
    harmonics: z.coerce.number().int().min(1).default(3),
    f0Min: z.coerce.number().default(60),
    f0Max: z.coerce.number().default(300),
    /** spoof: how far from the truth the fake listening point is, km. */
    spoofKm: z.coerce.number().positive().default(6),
  }),
  create: (o) => ({
    process(x, ctx) {
      const sr = ctx.sampleRate, rng = new Rng(ctx.seed ^ 0x5eed), y = Float32Array.from(x);
      const duration = x.length / sr, step = 0.02;
      const grid = Float64Array.from({ length: Math.ceil(duration / step) + 2 }, (_, i) => i * step);
      const made: string[] = [];

      const inject = (ratio: Float64Array, f0: number, rangeGain: Float64Array | number) => {
        const p = powerPerHz(x, sr, f0);
        const amp = Math.sqrt(2 * p * 10 ** (o.levelDb / 10));
        for (let h = 1; h <= o.harmonics; h++) {
          const freq = perSampleFrequency(ratio, step, h * f0, y.length, sr);
          const g = typeof rangeGain === "number" ? (amp / h) * rangeGain : rangeGain.map((v) => (v * amp) / h);
          addTone(y, freq, g, sr);
        }
      };

      if (o.mode === "spoof") {
        if (!ctx.clip || !ctx.tracks?.length) throw new Error("decoy(mode=spoof) needs the clip location and flight tracks");
        const theta = rng.uniform(0, 2 * Math.PI);
        const fake = { east: o.spoofKm * 1000 * Math.cos(theta), north: o.spoofKm * 1000 * Math.sin(theta) };
        for (const track of ctx.tracks.slice(0, o.count)) {
          const ratio = ratioCurve(new TrackPath(track, ctx.clip.location), ctx.clip, grid, fake);
          const f0 = rng.uniform(o.f0Min, o.f0Max);
          inject(ratio, f0, 1);
          made.push(`${track.callsign ?? track.id} as heard ${o.spoofKm} km away @ ${f0.toFixed(0)} Hz`);
        }
      } else {
        for (let i = 0; i < o.count; i++) {
          const speed = rng.uniform(60, 250), distance = rng.uniform(2_000, 15_000);
          const t0 = rng.uniform(-0.25 * duration, 1.25 * duration), f0 = rng.uniform(o.f0Min, o.f0Max);
          // Spherical spreading relative to closest approach, sampled per output sample.
          const ratio = flybyRatio(grid, t0, distance, speed);
          const gain = new Float64Array(y.length);
          for (let n = 0; n < y.length; n++) {
            const t = n / sr, dx = speed * (t - t0 + distance / SPEED_OF_SOUND);
            gain[n] = distance / Math.hypot(dx, distance);
          }
          inject(ratio, f0, gain);
          made.push(`${f0.toFixed(0)} Hz, ${(distance / 1000).toFixed(1)} km, ${speed.toFixed(0)} m/s, t0 ${t0.toFixed(0)} s`);
        }
      }
      ctx.log(`decoy: ${made.length} ${o.mode} curves at +${o.levelDb} dB/Hz: ${made.join("; ")}`);
      return y;
    },
  }),
});
