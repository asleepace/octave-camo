/** WGS-84 geodesy: enough for local geometry within a few tens of km. */

const A = 6_378_137; // semi-major axis, m
const F = 1 / 298.257223563;
const E2 = F * (2 - F); // first eccentricity squared

export type LatLonAlt = { lat: number; lon: number; altM: number };
export type Vec3 = [number, number, number];

const rad = (deg: number) => (deg * Math.PI) / 180;

export function toECEF({ lat, lon, altM }: LatLonAlt): Vec3 {
  const φ = rad(lat), λ = rad(lon);
  const n = A / Math.sqrt(1 - E2 * Math.sin(φ) ** 2);
  return [
    (n + altM) * Math.cos(φ) * Math.cos(λ),
    (n + altM) * Math.cos(φ) * Math.sin(λ),
    (n * (1 - E2) + altM) * Math.sin(φ),
  ];
}

/** East-north-up coordinates of `p` in meters, relative to `origin`. */
export function toENU(p: LatLonAlt, origin: LatLonAlt): Vec3 {
  const [x, y, z] = toECEF(p), [x0, y0, z0] = toECEF(origin);
  const dx = x - x0, dy = y - y0, dz = z - z0;
  const φ = rad(origin.lat), λ = rad(origin.lon);
  const sφ = Math.sin(φ), cφ = Math.cos(φ), sλ = Math.sin(λ), cλ = Math.cos(λ);
  return [
    -sλ * dx + cλ * dy,
    -sφ * cλ * dx - sφ * sλ * dy + cφ * dz,
    cφ * cλ * dx + cφ * sλ * dy + sφ * dz,
  ];
}

export const norm = (v: Vec3) => Math.hypot(v[0], v[1], v[2]);
export const sub = (a: Vec3, b: Vec3): Vec3 => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
export const lerp = (a: Vec3, b: Vec3, w: number): Vec3 => [
  a[0] + w * (b[0] - a[0]),
  a[1] + w * (b[1] - a[1]),
  a[2] + w * (b[2] - a[2]),
];

/** Lat/lon box of ±radiusKm around a point (small-area approximation). */
export function boundingBox(center: LatLonAlt, radiusKm: number) {
  const dLat = radiusKm / 111.32;
  const dLon = radiusKm / (111.32 * Math.cos(rad(center.lat)));
  return {
    north: center.lat + dLat,
    south: center.lat - dLat,
    west: center.lon - dLon,
    east: center.lon + dLon,
  };
}

export const FEET = 0.3048;
export const KNOTS = 0.514444;
export const SPEED_OF_SOUND = 343; // m/s, matches the analyzer's model
