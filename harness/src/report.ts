import type { Analysis, Estimate } from "./analyzer.ts";
import type { ClipInfo } from "./clip.ts";
import type { GroundTruth } from "./track.ts";

/**
 * How close an estimate must be to count as "recovered". The truth itself is uncertain:
 * - distance: barometric altitude can be off by ~100 m with weather, plus 10 % model error
 * - t0: QuickTime timestamps have 1 s resolution and recording starts a beat after the stamp
 * - speed: ADS-B gives ground speed; the audio sees airspeed (they differ by the wind)
 */
export function tolerances(truth: GroundTruth) {
  return {
    distanceM: 0.1 * truth.distanceM + (truth.altitudeKind === "barometric" ? 100 : 20),
    t0S: 2,
    speedMps: 15,
  };
}

export type Comparison = {
  estimate?: Estimate;
  errors?: { distanceM: number; t0S: number; speedMps: number };
  /** The audio alone located the closest approach (distance and time both within tolerance). */
  recovered: boolean;
};

export function compare(truth: GroundTruth, analysis: Analysis): Comparison {
  const estimate = analysis.consensus ?? undefined;
  if (!estimate) return { recovered: false };
  const tol = tolerances(truth);
  const errors = {
    distanceM: estimate.distance - truth.distanceM,
    t0S: estimate.t0 - truth.t0,
    speedMps: estimate.speed - truth.speedMps,
  };
  return {
    estimate,
    errors,
    recovered: Math.abs(errors.distanceM) <= tol.distanceM && Math.abs(errors.t0S) <= tol.t0S,
  };
}

const fmt = (v: number, digits = 0) => v.toFixed(digits);
const signed = (v: number, digits = 0) => (v >= 0 ? "+" : "") + v.toFixed(digits);

export function printClip(clip: ClipInfo) {
  console.log(`clip: ${clip.path}`);
  console.log(`  recorded ${new Date(clip.startTime * 1000).toISOString()}, ${fmt(clip.durationS, 1)} s` +
    `${clip.device ? `, ${clip.device}` : ""}`);
  console.log(`  phone position known to ±${clip.locationAccuracyM?.toFixed(1) ?? "?"} m`);
}

export function printCandidates(truths: GroundTruth[]) {
  console.log(`\naircraft near the clip (${truths.length}), closest first:`);
  for (const t of truths.slice(0, 6)) {
    const name = [t.track.callsign, t.track.id].filter(Boolean).join(" / ");
    console.log(`  ${name.padEnd(22)} ${fmt(t.distanceM).padStart(6)} m at t0=${fmt(t.t0, 1).padStart(6)} s` +
      `  ${fmt(t.speedMps)} m/s  height ${fmt(t.heightM)} m${t.inClip ? "" : "  (closest approach outside clip)"}` +
      `${t.trackGapS > 20 ? `  ⚠ ${fmt(t.trackGapS)} s track gap` : ""}`);
  }
}

export function printComparison(label: string, truth: GroundTruth, c: Comparison) {
  const tol = tolerances(truth);
  console.log(`\n${label}`);
  if (!c.estimate || !c.errors) {
    console.log("  no flyby recovered from the audio");
    return;
  }
  const rows: [string, number, number, number, number, number][] = [
    ["distance (m)", truth.distanceM, c.estimate.distance, c.errors.distanceM, tol.distanceM, 0],
    ["t0 (s)", truth.t0, c.estimate.t0, c.errors.t0S, tol.t0S, 1],
    ["speed (m/s)", truth.speedMps, c.estimate.speed, c.errors.speedMps, tol.speedMps, 0],
  ];
  console.log(`  ${"".padEnd(13)}${"truth".padStart(9)}${"audio".padStart(9)}${"error".padStart(9)}  tolerance`);
  for (const [name, t, e, err, tl, d] of rows) {
    const ok = Math.abs(err) <= tl ? "✓" : "✗";
    console.log(`  ${name.padEnd(13)}${fmt(t, d).padStart(9)}${fmt(e, d).padStart(9)}${signed(err, d).padStart(9)}  ±${fmt(tl, d)} ${ok}`);
  }
}
