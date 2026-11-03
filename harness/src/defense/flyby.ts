import { SPEED_OF_SOUND } from "../geo.ts";

/**
 * Doppler ratio f/f0 heard at each receive time for an idealized straight, constant-speed flyby:
 * closest approach `distance` m, heard at `t0` s, at `speed` m/s. Includes propagation delay
 * (Newton on τ + r(τ)/c = t, warm-started from the previous sample).
 */
export function flybyRatio(times: ArrayLike<number>, t0: number, distance: number, speed: number): Float64Array {
  const c = SPEED_OF_SOUND, out = new Float64Array(times.length);
  const emissionT0 = t0 - distance / c;
  let tau = (times[0] ?? 0) - distance / c, prev = times[0] ?? 0;
  for (let i = 0; i < times.length; i++) {
    tau += times[i]! - prev;
    prev = times[i]!;
    for (let it = 0; it < 8; it++) {
      const dx = speed * (tau - emissionT0), r = Math.hypot(dx, distance);
      const g = tau + r / c - times[i]!;
      tau -= g / (1 + (speed * dx) / (c * r));
      if (Math.abs(g) < 1e-9) break;
    }
    const dx = speed * (tau - emissionT0), r = Math.hypot(dx, distance);
    out[i] = 1 / (1 + (speed * dx) / (r * c));
  }
  return out;
}

/** Instantaneous frequency per sample for a tone f0 along a ratio curve sampled every `step` s. */
export function perSampleFrequency(ratio: Float64Array, step: number, f0: number, n: number, sampleRate: number): Float64Array {
  const freq = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    const g = i / sampleRate / step, k = Math.min(Math.floor(g), ratio.length - 2), w = g - k;
    const r0 = ratio[k]!, r1 = ratio[k + 1]!;
    freq[i] = f0 * (Number.isFinite(r0) && Number.isFinite(r1) ? r0 + w * (r1 - r0) : 1);
  }
  return freq;
}

/** Box filter, centered, via prefix sums. */
function box(x: Float64Array, length: number): Float64Array {
  const n = x.length, h = (length - 1) >> 1, out = new Float64Array(n), pre = new Float64Array(n + 1);
  for (let i = 0; i < n; i++) pre[i + 1] = pre[i]! + x[i]!;
  for (let i = 0; i < n; i++) {
    const lo = Math.max(i - (length - 1) + h, 0), hi = Math.min(i + h, n - 1);
    out[i] = (pre[hi + 1]! - pre[lo]!) / length;
  }
  return out;
}

/**
 * Heterodyne-and-subtract one tone with known instantaneous frequency. `lowpassS` sets how much
 * around the curve is removed (≈ ±1/lowpassS Hz): long when the curve is exact, shorter when it
 * is only estimated.
 */
export function cancelTone(y: Float32Array, freq: Float64Array, sampleRate: number, lowpassS: number): void {
  const n = y.length, zr = new Float64Array(n), zi = new Float64Array(n), c = new Float64Array(n), s = new Float64Array(n);
  let phase = 0;
  for (let i = 0; i < n; i++) {
    phase += (2 * Math.PI * freq[i]!) / sampleRate;
    c[i] = Math.cos(phase); s[i] = Math.sin(phase);
    zr[i] = y[i]! * c[i]!; zi[i] = -y[i]! * s[i]!;
  }
  const L = Math.max(2, Math.round(lowpassS * sampleRate));
  const ar = box(box(zr, L), L), ai = box(box(zi, L), L);
  for (let i = 0; i < n; i++) y[i]! -= 2 * (ar[i]! * c[i]! - ai[i]! * s[i]!);
}
