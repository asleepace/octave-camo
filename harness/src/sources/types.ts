import type { ClipInfo } from "../clip.ts";
import type { FlightTrack } from "../track.ts";

export type FindOptions = {
  /** Search radius around the phone, km. */
  radiusKm: number;
  /** Known aircraft identifiers, if you noted them while recording. */
  icao24?: string;
  callsign?: string;
  flightId?: string;
};

/** A flight-data provider that can return candidate tracks for a clip. */
export interface TrackSource {
  readonly name: FlightTrack["source"];
  findTracks(clip: ClipInfo, options: FindOptions): Promise<FlightTrack[]>;
}

export class HttpError extends Error {
  constructor(readonly status: number, readonly url: string, body: string, readonly retryAfterS?: number) {
    super(`HTTP ${status} from ${url.replace(/\?.*$/, "")}${body ? `: ${body.slice(0, 300)}` : ""}`);
  }
}

export async function fetchJSON(url: string, init: RequestInit): Promise<unknown | undefined> {
  const res = await fetch(url, init);
  if (res.status === 404) return undefined; // both APIs use 404 for "no data"
  if (!res.ok) {
    const retry = res.headers.get("X-Rate-Limit-Retry-After-Seconds") ?? res.headers.get("Retry-After");
    throw new HttpError(res.status, url, await res.text(), retry ? Number(retry) : undefined);
  }
  return res.json();
}

export function requireEnv(name: string, hint: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set (${hint}). See harness/.env.example.`);
  return value;
}

/** Midpoint of the clip, Unix seconds: the best single instant to look for nearby aircraft. */
export const clipMidpoint = (clip: ClipInfo) => Math.round(clip.startTime + clip.durationS / 2);
