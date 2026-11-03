import { type LatLonAlt, type Vec3, lerp, norm, sub, toENU, SPEED_OF_SOUND } from "./geo.ts";
import type { ClipInfo } from "./clip.ts";

export type TrackPoint = {
  /** Unix seconds. */
  t: number;
  lat: number;
  lon: number;
  /** Altitude, m. ADS-B reports barometric (pressure) altitude: see `altitudeKind`. */
  altM: number;
};

export type FlightTrack = {
  source: "opensky" | "fr24" | "file";
  /** icao24 for OpenSky, fr24_id for Flightradar24. */
  id: string;
  callsign?: string;
  /** Barometric altitude can differ from true altitude by ~100 m with weather. */
  altitudeKind: "barometric" | "geometric";
  points: TrackPoint[];
};

/** Where the aircraft really was relative to the phone: what the attacker tries to recover. */
export type GroundTruth = {
  track: { source: FlightTrack["source"]; id: string; callsign?: string };
  /** Closest-approach slant distance, m (3D, including altitude). */
  distanceM: number;
  /** Closest approach as heard: seconds into the clip (emission time + travel time − clip start). */
  t0: number;
  /** 3D speed at closest approach, m/s (ground-referenced; the audio sees airspeed). */
  speedMps: number;
  /** Aircraft height above the phone at closest approach, m. */
  heightM: number;
  horizontalDistanceM: number;
  /** Whether the closest approach is audible inside the clip. */
  inClip: boolean;
  /** Largest gap between track points around closest approach, s (interpolation quality). */
  trackGapS: number;
  altitudeKind: FlightTrack["altitudeKind"];
};

/** Track positions in ENU around the phone, sorted, with linear interpolation in time. */
export class TrackPath {
  readonly times: number[];
  private readonly enu: Vec3[];

  constructor(track: FlightTrack, origin: LatLonAlt) {
    const pts = [...track.points].sort((a, b) => a.t - b.t);
    if (pts.length < 2) throw new Error(`track ${track.id} has fewer than 2 points`);
    this.times = pts.map((p) => p.t);
    this.enu = pts.map((p) => toENU(p, origin));
  }

  get start() { return this.times[0]!; }
  get end() { return this.times[this.times.length - 1]!; }

  /** Index i with times[i] <= t < times[i+1] (clamped). */
  private segment(t: number): number {
    let lo = 0, hi = this.times.length - 1;
    while (hi - lo > 1) {
      const mid = (lo + hi) >> 1;
      if (this.times[mid]! <= t) lo = mid; else hi = mid;
    }
    return lo;
  }

  at(t: number): Vec3 {
    const i = this.segment(t);
    const t0 = this.times[i]!, t1 = this.times[i + 1]!;
    const w = Math.min(Math.max((t - t0) / (t1 - t0), 0), 1);
    return lerp(this.enu[i]!, this.enu[i + 1]!, w);
  }

  /** Gap between the track points bracketing t, s. */
  gapAt(t: number): number {
    const i = this.segment(t);
    return this.times[i + 1]! - this.times[i]!;
  }
}

/**
 * Closest approach of a track to the phone. Emission times are sampled every `stepS` over the
 * window in which sound could reach the clip; the clip-relative t0 includes the travel time d/c,
 * matching the analyzer's definition.
 */
export function groundTruth(track: FlightTrack, clip: ClipInfo, stepS = 0.05): GroundTruth | undefined {
  const path = new TrackPath(track, clip.location);
  // Sound emitted up to ~60 s before the clip (≈20 km away) can still be heard in it.
  const from = Math.max(path.start, clip.startTime - 60);
  const to = Math.min(path.end, clip.startTime + clip.durationS);
  if (to <= from) return undefined;

  let best = { t: from, r: Infinity };
  for (let t = from; t <= to; t += stepS) {
    const r = norm(path.at(t));
    if (r < best.r) best = { t, r };
  }

  const p = path.at(best.t);
  const velocity = sub(path.at(best.t + 1), path.at(best.t - 1)).map((v) => v / 2) as Vec3;
  const t0 = best.t + best.r / SPEED_OF_SOUND - clip.startTime;
  return {
    track: { source: track.source, id: track.id, callsign: track.callsign },
    distanceM: best.r,
    t0,
    speedMps: norm(velocity),
    heightM: p[2],
    horizontalDistanceM: Math.hypot(p[0], p[1]),
    inClip: t0 >= 0 && t0 <= clip.durationS,
    trackGapS: path.gapAt(best.t),
    altitudeKind: track.altitudeKind,
  };
}

/** Received frequency ratio f/f0 over clip time, for plotting or comparing against tracked tones. */
export function predictedDopplerRatio(track: FlightTrack, clip: ClipInfo, clipTimes: number[]): number[] {
  const path = new TrackPath(track, clip.location);
  return clipTimes.map((tc) => {
    // Find emission time τ with τ + r(τ)/c = receive time (fixed-point iteration converges fast).
    const rx = clip.startTime + tc;
    let tau = rx - norm(path.at(rx)) / SPEED_OF_SOUND;
    for (let i = 0; i < 6; i++) tau = rx - norm(path.at(tau)) / SPEED_OF_SOUND;
    const p = path.at(tau);
    const v = sub(path.at(tau + 0.5), path.at(tau - 0.5));
    const radialToward = -(p[0] * v[0] + p[1] * v[1] + p[2] * v[2]) / norm(p);
    return 1 / (1 - radialToward / SPEED_OF_SOUND);
  });
}
