/**
 * Basic tier: make the low band information-free.
 *
 * Distant aircraft leak through narrow tones below a few hundred Hz, tracked to ~0.5 Hz for tens
 * of seconds. Listeners hear that region in critical bands (ERBs, ~35 Hz wide at 100 Hz) as
 * texture. So below `cutoff`:
 *   - highpass:   remove it (cheapest; sounds thinner on headphones)
 *   - regenerate: replace it with noise matching each ERB band's loudness over time, slowly
 *                 smoothed and randomly re-gained so a plane's loudness swell doesn't survive.
 * With keepVoice, bins on tracked voice harmonics are kept as-is.
 */
import { z } from "zod";
import { median } from "../dsp.ts";
import { trackPitch, defaultPitchOptions } from "./pitch.ts";
import { LowBandSTFT, Rng, erbBands, smooth } from "./signal.ts";
import { defineDefense } from "./types.ts";

export const lowband = defineDefense({
  name: "lowband",
  summary: "remove or regenerate the band below `cutoff` (ERB texture); keeps voice harmonics",
  tier: "basic",
  options: z.object({
    mode: z.enum(["regenerate", "highpass"]).default("regenerate"),
    cutoff: z.coerce.number().positive().default(300),
    /** Crossover half-width as a fraction of cutoff. */
    crossover: z.coerce.number().min(0).max(0.9).default(0.2),
    keepVoice: z.stringbool().default(true),
    /** Envelope smoothing, s: hides the loudness swell of a passing plane. */
    smoothS: z.coerce.number().min(0).default(0.75),
    /** Slow random gain per band, ±dB, with 10–30 s periods. */
    jitterDb: z.coerce.number().min(0).default(1.5),
    fftSize: z.coerce.number().int().default(8192),
  }),
  create: (o) => ({
    process(x, ctx) {
      const sr = ctx.sampleRate, size = o.fftSize, hop = size / 4;
      const binHz = sr / size;
      const top = o.cutoff * (1 + o.crossover), bottom = o.cutoff * (1 - o.crossover);
      const K = Math.min(Math.ceil(top / binHz) + 2, size / 2);
      const stft = new LowBandSTFT(x, size, hop, K);
      const F = stft.frames;
      const outRe = stft.re.slice(), outIm = stft.im.slice();

      // How much of each bin to replace: 1 below `bottom`, raised-cosine to 0 at `top`.
      const replace = Float64Array.from({ length: K }, (_, k) => {
        const f = k * binHz;
        if (f <= bottom) return 1;
        if (f >= top) return 0;
        return 0.5 + 0.5 * Math.cos((Math.PI * (f - bottom)) / (top - bottom));
      });

      if (o.mode === "highpass") {
        for (let m = 0; m < F; m++) for (let k = 0; k < K; k++) {
          outRe[m * K + k]! *= 1 - replace[k]!; outIm[m * K + k]! *= 1 - replace[k]!;
        }
        ctx.log(`lowband: removed below ${o.cutoff} Hz`);
        return stft.render(outRe, outIm);
      }

      // Voice harmonics to keep (frame centers in seconds of the original signal).
      const keep = new Uint8Array(F * K);
      let voicedFrames = 0;
      if (o.keepVoice) {
        const times = Float64Array.from({ length: F }, (_, m) => (m * hop - size + size / 2) / sr);
        const { f0 } = trackPitch(x, sr, times, defaultPitchOptions);
        for (let m = 0; m < F; m++) {
          if (!f0[m]) continue;
          voicedFrames++;
          for (let h = 1; h * f0[m]! < top; h++) {
            const c = (h * f0[m]!) / binHz;
            for (let k = Math.max(0, Math.floor(c - 1.5)); k <= Math.min(K - 1, Math.ceil(c + 1.5)); k++) keep[m * K + k] = 1;
          }
        }
      }

      // ERB bands over [0, top]; each bin belongs to one band.
      const edges = [0, ...erbBands(20, top).slice(1)];
      const bandOf = Int32Array.from({ length: K }, (_, k) => {
        const f = k * binHz;
        let b = 0;
        while (b + 1 < edges.length - 1 && f >= edges[b + 1]!) b++;
        return b;
      });
      const B = edges.length - 1;

      // Static per-bin spectral shape (long-term median power): carries no time-varying information.
      const profile = Float64Array.from({ length: K }, (_, k) =>
        median(Array.from({ length: F }, (_, m) => stft.re[m * K + k]! ** 2 + stft.im[m * K + k]! ** 2)) + 1e-20);

      // Band energy per frame (replaced bins only), smoothed, with slow random gain.
      const rng = new Rng(ctx.seed);
      const framesPerS = sr / hop;
      const energy = Array.from({ length: B }, () => new Float64Array(F));
      for (let m = 0; m < F; m++) for (let k = 0; k < K; k++) {
        if (keep[m * K + k] || replace[k] === 0) continue;
        energy[bandOf[k]!]![m]! += stft.re[m * K + k]! ** 2 + stft.im[m * K + k]! ** 2;
      }
      const target = energy.map((e) => {
        const s = smooth(e, Math.round(o.smoothS * framesPerS));
        const periods = [rng.uniform(10, 30), rng.uniform(10, 30)], phases = [rng.uniform(0, 6.283), rng.uniform(0, 6.283)];
        return s.map((v, m) => {
          const t = m / framesPerS;
          const db = (o.jitterDb / 2) * (Math.sin(6.283 * t / periods[0]! + phases[0]!) + Math.sin(6.283 * t / periods[1]! + phases[1]!));
          return v * 10 ** (db / 10);
        });
      });

      // Random-phase frames overlap-add incoherently, so their power comes out lower than the
      // analyzed (coherent) frames' by windowPower / overlapPower; compensate.
      const gain = Math.sqrt(stft.overlapPower / stft.windowPower);
      for (let m = 0; m < F; m++) {
        const shapeSum = new Float64Array(B);
        for (let k = 0; k < K; k++) if (!keep[m * K + k] && replace[k]! > 0) shapeSum[bandOf[k]!]! += profile[k]!;
        for (let k = 0; k < K; k++) {
          const i = m * K + k, w = replace[k]!;
          if (keep[i] || w === 0) continue;
          const b = bandOf[k]!;
          const amp = Math.sqrt((target[b]![m]! * profile[k]!) / (shapeSum[b]! || 1) / 2) * gain;
          // Power-complementary crossfade: the original and the noise are uncorrelated.
          const keepOriginal = Math.sqrt(1 - w), useNoise = Math.sqrt(w);
          outRe[i] = keepOriginal * stft.re[i]! + useNoise * amp * rng.gaussian();
          outIm[i] = keepOriginal * stft.im[i]! + useNoise * amp * rng.gaussian();
        }
      }
      ctx.log(`lowband: regenerated below ${o.cutoff} Hz in ${B} ERB bands` +
        (o.keepVoice ? `, kept voice harmonics in ${((100 * voicedFrames) / F).toFixed(0)}% of frames` : ""));
      return stft.render(outRe, outIm);
    },
  }),
});
