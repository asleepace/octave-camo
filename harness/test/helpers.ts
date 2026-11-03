import type { ClipInfo } from "../src/clip.ts";
import type { LatLonAlt } from "../src/geo.ts";
import { SPEED_OF_SOUND, toENU } from "../src/geo.ts";
import type { FlightTrack } from "../src/track.ts";

export const PHONE: LatLonAlt = { lat: 37.7465, lon: -122.4334, altM: 106.217 };
export const START = Date.parse("2026-11-03T02:33:13Z") / 1000;

/** Inverse of toENU: small-area first guess, then a few corrections against the exact forward map. */
export function fromENU(target: [number, number, number], o: LatLonAlt): LatLonAlt {
  const mPerDegLat = 111_132.954, mPerDegLon = 111_319.488 * Math.cos((o.lat * Math.PI) / 180);
  let p: LatLonAlt = { lat: o.lat + target[1] / mPerDegLat, lon: o.lon + target[0] / mPerDegLon, altM: o.altM + target[2] };
  for (let i = 0; i < 5; i++) {
    const [e, n, u] = toENU(p, o);
    p = { lat: p.lat + (target[1] - n) / mPerDegLat, lon: p.lon + (target[0] - e) / mPerDegLon, altM: p.altM + (target[2] - u) };
  }
  return p;
}

/**
 * Straight, level flyby heading west: passes `offsetNorthM` north of the phone at `heightM` above
 * it, so the slant closest approach is hypot(offsetNorthM, heightM). `t0` is when it is *heard*.
 */
export function straightTrack(opts: { offsetNorthM: number; heightM: number; speed: number; t0: number;
                                      stepS?: number }): FlightTrack {
  const d = Math.hypot(opts.offsetNorthM, opts.heightM);
  const emissionCA = START + opts.t0 - d / SPEED_OF_SOUND;
  const points = [];
  for (let dt = -120; dt <= 120; dt += opts.stepS ?? 5) {
    const p = fromENU([-opts.speed * dt, opts.offsetNorthM, opts.heightM], PHONE);
    points.push({ t: emissionCA + dt, lat: p.lat, lon: p.lon, altM: p.altM });
  }
  return { source: "file", id: "test01", callsign: "TEST01", altitudeKind: "geometric", points };
}

export const clipInfo = (durationS = 60): ClipInfo =>
  ({ path: "synthetic.mov", location: PHONE, startTime: START, durationS });
