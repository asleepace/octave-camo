import { describe, expect, test } from "bun:test";
import { informedCancel } from "../src/cancel.ts";
import { defaultMatchedConfig, matchedAttack, ratioCurve, whitenedSpectrogram } from "../src/matched.ts";
import { TrackPath, predictedDopplerRatio } from "../src/track.ts";
import { clipInfo, straightTrack } from "./helpers.ts";

const cfg = defaultMatchedConfig;
const clip = clipInfo(90);
const plane = { ...straightTrack({ offsetNorthM: 5_000, heightM: 3_000, speed: 150, t0: 45 }), id: "plane" };
const decoy = { ...straightTrack({ offsetNorthM: -8_000, heightM: 4_000, speed: 200, t0: 20 }), id: "decoy" };

/** White noise plus a faint 95 Hz tone (and harmonic) along the plane's true Doppler curve, at 4 kHz. */
function syntheticAudio(toneAmplitude: number, seed = 7): Float32Array {
  const sr = cfg.sampleRate, n = 90 * sr;
  const step = 0.02, grid = Array.from({ length: Math.ceil(90 / step) + 2 }, (_, i) => i * step);
  const ratio = predictedDopplerRatio(plane, clip, grid);
  let state = seed;
  const rand = () => ((state = (state * 1_103_515_245 + 12_345) % 2 ** 31) / 2 ** 31);
  const x = new Float32Array(n);
  let p1 = 0, p2 = 0;
  for (let i = 0; i < n; i++) {
    const g = i / sr / step, k = Math.floor(g), r = ratio[k]! + (g - k) * (ratio[k + 1]! - ratio[k]!);
    p1 += (2 * Math.PI * 95 * r) / sr; p2 += (2 * Math.PI * 190 * r) / sr;
    const noise = Math.sqrt(-2 * Math.log(rand() + 1e-12)) * Math.cos(2 * Math.PI * rand());
    x[i] = 0.1 * noise + toneAmplitude * (Math.sin(p1) + 0.5 * Math.sin(p2));
  }
  return x;
}

describe("matched attack", () => {
  test("ratio curve at the true location matches the ground-truth predictor", () => {
    const times = Float64Array.from([5, 30, 45, 60, 85]);
    const a = ratioCurve(new TrackPath(plane, clip.location), clip, times, { east: 0, north: 0 });
    const b = predictedDopplerRatio(plane, clip, Array.from(times));
    for (let i = 0; i < times.length; i++) expect(a[i]!).toBeCloseTo(b[i]!, 3);
  });

  const audio = syntheticAudio(0.01); // tone ~ -26 dB below the noise in amplitude
  const spec = whitenedSpectrogram(audio, cfg);

  test("locates a faint background plane and ignores a decoy", () => {
    const r = matchedAttack(spec, [plane, decoy], clip);
    const p = r.aircraft.find((a) => a.id === "plane")!, d = r.aircraft.find((a) => a.id === "decoy")!;
    expect(p.detected).toBe(true);
    expect(p.f0).toBeCloseTo(95, 0);
    expect(d.detected).toBe(false);
    expect(r.ambiguityAwareErrorM!).toBeLessThanOrEqual(500);
  }, 60_000);

  test("informed cancellation removes it", () => {
    const x = audio.slice();
    const reports = informedCancel(x, cfg.sampleRate, spec, [plane, decoy], clip);
    expect(reports.find((r) => r.id === "plane")!.cancelled).toBe(true);
    expect(reports.find((r) => r.id === "decoy")!.cancelled).toBe(false);
    const after = matchedAttack(whitenedSpectrogram(x, cfg), [plane, decoy], clip);
    expect(after.aircraft.every((a) => !a.detected)).toBe(true);
  }, 60_000);
});
