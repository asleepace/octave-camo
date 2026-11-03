/**
 * Offline tier: find S-curves without flight data, and cancel them.
 *
 * Any straight, constant-speed flyby produces a pitch curve f0·r(t) set by just four numbers:
 * f0, speed (β = v/c), time scale τ = distance/speed, and the heard closest-approach time t0.
 * So the defender can run the attacker's own trick (integrate energy along a curve) over the
 * whole physical family, and cancel the best candidates. It errs toward over-cancelling:
 * removing a thin sliver of noise along a curve that wasn't a plane is inaudible.
 *
 * Scoring uses a log-frequency spectrogram, where a curve f0·r(t) becomes ln f0 + ln r(t): each
 * frame is just shifted and added, giving the score for every f0 at once.
 */
import { z } from "zod";
import { median } from "../dsp.ts";
import { SPEED_OF_SOUND } from "../geo.ts";
import { type MatchedConfig, type Spectrogram, defaultMatchedConfig, whitenedSpectrogram } from "../matched.ts";
import { cancelTone, flybyRatio, perSampleFrequency } from "./flyby.ts";
import { decimate } from "./signal.ts";
import { defineDefense } from "./types.ts";

type Curve = { beta: number; tau: number; t0: number };
type Candidate = Curve & { score: number; logF0: number };

/** Log-frequency rows: L[t][j] at f = fMin·e^(j·δ), linearly interpolated from the spectrogram. */
function logRows(spec: Spectrogram, fMin: number, fMax: number, delta: number) {
  const J = Math.floor(Math.log(fMax / fMin) / delta) + 1, T = spec.times.length;
  const rows = new Float32Array(T * J);
  for (let t = 0; t < T; t++) for (let j = 0; j < J; j++) {
    const b = (fMin * Math.exp(j * delta)) / spec.binHz, k = Math.floor(b), w = b - k;
    rows[t * J + j] = k + 1 < spec.bins ? (1 - w) * spec.data[t * spec.bins + k]! + w * spec.data[t * spec.bins + k + 1]! : 0;
  }
  return { rows, J, T };
}

export const scurve = defineDefense({
  name: "scurve",
  summary: "blind search for flyby pitch curves (no flight data) and cancel them",
  tier: "offline",
  options: z.object({
    /** Cancel candidates whose robust z (vs. all curves) exceeds this; low = over-cancel. */
    z: z.coerce.number().default(4.5),
    maxCurves: z.coerce.number().int().min(0).default(8),
    f0Min: z.coerce.number().default(40),
    f0Max: z.coerce.number().default(600),
    /** Amplitude low-pass for cancellation, s (curves are estimated, so shorter than informed). */
    lowpassS: z.coerce.number().positive().default(0.4),
  }),
  create: (o) => ({
    process(x, ctx) {
      const { x: low, rate } = decimate(x, ctx.sampleRate, 4_000);
      const cfg: MatchedConfig = { ...defaultMatchedConfig, sampleRate: rate, f0Range: [o.f0Min, o.f0Max] };
      const spec = whitenedSpectrogram(low, cfg);
      const T = spec.times.length;
      if (T < 16) return x;
      const duration = x.length / ctx.sampleRate;

      // Ratios span ~0.6–1.6, so rows cover f0Min·0.6 … f0Max·1.6.
      const delta = 0.002, rMin = 0.6;
      const { rows, J } = logRows(spec, o.f0Min * rMin, o.f0Max * 1.6, delta);
      const jLo = Math.round(Math.log(1 / rMin) / delta);                 // index of f0Min
      const jHi = Math.round(Math.log((o.f0Max) / (o.f0Min * rMin)) / delta);

      // The physical family on a grid.
      const curves: Curve[] = [];
      for (let beta = 0.1; beta <= 0.8001; beta += 0.1)
        for (let tau = 5; tau <= 240; tau *= 1.25) {
          const step = Math.max(2, tau / 4);
          for (let t0 = -Math.min(2 * tau, 240); t0 <= duration + Math.min(2 * tau, 240); t0 += step) curves.push({ beta, tau, t0 });
        }

      const acc = new Float64Array(J);
      const score = (c: Curve): Candidate => {
        const speed = c.beta * SPEED_OF_SOUND;
        const r = flybyRatio(spec.times, c.t0, c.tau * speed, speed);
        acc.fill(0);
        for (let t = 0; t < T; t++) {
          const shift = Math.log(r[t]!) / delta, s = Math.floor(shift), w = shift - s, row = t * J;
          for (let j = jLo; j <= jHi; j++) {
            const a = j + s;
            if (a >= 0 && a + 1 < J) acc[j]! += (1 - w) * rows[row + a]! + w * rows[row + a + 1]!;
          }
        }
        let best = jLo;
        for (let j = jLo + 1; j <= jHi; j++) if (acc[j]! > acc[best]!) best = j;
        return { ...c, score: acc[best]! / T, logF0: best };
      };

      const scored = curves.map(score);
      const all = scored.map((c) => c.score);
      const m = median(all), mad = median(all.map((v) => Math.abs(v - m))) * 1.4826 || 1e-12;
      const ranked = scored.map((c) => ({ ...c, z: (c.score - m) / mad })).sort((a, b) => b.z - a.z);

      // Greedy: cancel the best, mask it in the log rows, re-score the next contenders.
      const y = Float32Array.from(x);
      const cancelled: string[] = [];
      let pool = ranked.filter((c) => c.z > o.z).slice(0, 200);
      // The grid is coarse (t0 steps of τ/4); refine each winner by coordinate descent before
      // cancelling, or fast close sweeps are cancelled along a slightly wrong curve.
      const refine = (c: Candidate): Candidate => {
        let best = c;
        const tryCurve = (curve: Curve) => {
          if (curve.beta <= 0.02 || curve.beta >= 0.9 || curve.tau <= 1) return;
          const s = score(curve);
          if (s.score > best.score) best = s;
        };
        let dt0 = Math.max(2, c.tau / 4) / 2, dTau = 0.12, dBeta = 0.05;
        for (let round = 0; round < 4; round++, dt0 /= 2, dTau /= 2, dBeta /= 2) {
          for (let k = -3; k <= 3; k++) tryCurve({ ...best, t0: best.t0 + (k * dt0) / 3 });
          for (let k = -3; k <= 3; k++) tryCurve({ ...best, tau: best.tau * (1 + (k * dTau) / 3) });
          for (let k = -3; k <= 3; k++) tryCurve({ ...best, beta: best.beta + (k * dBeta) / 3 });
        }
        return best;
      };

      while (pool.length && cancelled.length < o.maxCurves) {
        const best = { ...refine(pool[0]!), z: pool[0]!.z };
        if (best.z <= o.z) break;
        const f0 = o.f0Min * rMin * Math.exp(best.logF0 * delta);
        const speed = best.beta * SPEED_OF_SOUND, step = 0.02;
        const grid = Float64Array.from({ length: Math.ceil(duration / step) + 2 }, (_, i) => i * step);
        const ratio = flybyRatio(grid, best.t0, best.tau * speed, speed);
        cancelTone(y, perSampleFrequency(ratio, step, f0, y.length, ctx.sampleRate), ctx.sampleRate, o.lowpassS);
        cancelled.push(`${f0.toFixed(1)} Hz (τ ${best.tau.toFixed(0)} s, β ${best.beta.toFixed(1)}, t0 ${best.t0.toFixed(0)} s, z ${best.z.toFixed(1)})`);

        // Mask ±1.2 % around the cancelled path so it isn't found again.
        const r = flybyRatio(spec.times, best.t0, best.tau * speed, speed), halfWidth = Math.ceil(0.012 / delta);
        for (let t = 0; t < T; t++) {
          const c = best.logF0 + Math.round(Math.log(r[t]!) / delta);
          for (let j = c - halfWidth; j <= c + halfWidth; j++) if (j >= 0 && j < J) rows[t * J + j] = 0;
        }
        pool = pool.slice(1).map(score).map((c) => ({ ...c, z: (c.score - m) / mad }))
          .filter((c) => c.z > o.z).sort((a, b) => b.z - a.z);
      }
      ctx.log(`scurve: searched ${curves.length} flyby curves; cancelled ${cancelled.length}` +
        (cancelled.length ? `: ${cancelled.join("; ")}` : ""));
      return y;
    },
  }),
});
