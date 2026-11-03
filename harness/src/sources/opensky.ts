import { z } from "zod";
import type { ClipInfo } from "../clip.ts";
import { boundingBox } from "../geo.ts";
import type { FlightTrack } from "../track.ts";
import { type FindOptions, type TrackSource, HttpError, clipMidpoint, fetchJSON, requireEnv } from "./types.ts";

const TOKEN_URL = "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token";
const API = "https://opensky-network.org/api";
/** Authenticated /states/all accepts `time` at most 1 hour in the past. */
const STATES_LOOKBACK_S = 3_600;

const Token = z.object({ access_token: z.string(), expires_in: z.number() });

// /tracks/all → path rows: [time, lat, lon, baro_altitude (m), true_track, on_ground]
const Waypoint = z.tuple([
  z.number(), z.number().nullable(), z.number().nullable(),
  z.number().nullable(), z.number().nullable(), z.boolean(),
]);
export const OpenSkyTrack = z.object({
  icao24: z.string(),
  startTime: z.number(),
  endTime: z.number(),
  callsign: z.string().nullable().optional(),
  calllsign: z.string().nullable().optional(), // sic: the field is misspelled in OpenSky's docs
  path: z.array(Waypoint),
});

// /states/all → rows indexed by field; we need icao24 (0) and callsign (1).
const States = z.object({
  time: z.number(),
  states: z.array(z.array(z.unknown())).nullable(),
});

const Flight = z.object({
  icao24: z.string(),
  callsign: z.string().nullable(),
  firstSeen: z.number(),
  lastSeen: z.number(),
});

export function toFlightTrack(raw: z.infer<typeof OpenSkyTrack>): FlightTrack {
  const callsign = (raw.callsign ?? raw.calllsign ?? undefined)?.trim() || undefined;
  return {
    source: "opensky",
    id: raw.icao24,
    callsign,
    altitudeKind: "barometric",
    points: raw.path.flatMap(([t, lat, lon, alt, , onGround]) =>
      lat === null || lon === null || alt === null || onGround ? [] : [{ t, lat, lon, altM: alt }]),
  };
}

export class OpenSky implements TrackSource {
  readonly name = "opensky" as const;
  private token?: { value: string; expires: number };

  constructor(
    private readonly clientId = requireEnv("OPENSKY_CLIENT_ID", "OpenSky API client id"),
    private readonly clientSecret = requireEnv("OPENSKY_CLIENT_SECRET", "OpenSky API client secret"),
  ) {}

  async findTracks(clip: ClipInfo, o: FindOptions): Promise<FlightTrack[]> {
    const at = clipMidpoint(clip);
    let icao24s: string[];
    if (o.icao24) {
      icao24s = [o.icao24.toLowerCase()];
    } else if (o.callsign) {
      icao24s = await this.icao24sForCallsign(o.callsign, at);
    } else if (Date.now() / 1000 - at < STATES_LOOKBACK_S) {
      icao24s = await this.aircraftNear(clip, o.radiusKm, at);
    } else {
      throw new Error(
        "OpenSky only searches by area within 1 hour of recording. Pass --icao24 or --callsign " +
        "(from your Flightradar24 screenshot), or use --source fr24.");
    }
    const tracks = await Promise.all(icao24s.map((id) => this.track(id, at)));
    return tracks.filter((t): t is FlightTrack => t !== undefined);
  }

  async track(icao24: string, time: number): Promise<FlightTrack | undefined> {
    const raw = await this.get("/tracks/all", { icao24, time: String(time) });
    return raw === undefined ? undefined : toFlightTrack(OpenSkyTrack.parse(raw));
  }

  async aircraftNear(clip: ClipInfo, radiusKm: number, time: number): Promise<string[]> {
    const box = boundingBox(clip.location, radiusKm);
    const raw = await this.get("/states/all", {
      time: String(time),
      lamin: String(box.south), lamax: String(box.north),
      lomin: String(box.west), lomax: String(box.east),
    });
    if (raw === undefined) return [];
    return (States.parse(raw).states ?? []).map((row) => String(row[0]));
  }

  /** /flights/all allows at most a 2-hour window. */
  async icao24sForCallsign(callsign: string, time: number): Promise<string[]> {
    const raw = await this.get("/flights/all", { begin: String(time - 3_600), end: String(time + 3_600) });
    if (raw === undefined) return [];
    const wanted = callsign.trim().toUpperCase();
    return [...new Set(z.array(Flight).parse(raw)
      .filter((f) => f.callsign?.trim().toUpperCase() === wanted)
      .map((f) => f.icao24))];
  }

  private async get(path: string, params: Record<string, string>, retried = false): Promise<unknown | undefined> {
    const url = `${API}${path}?${new URLSearchParams(params)}`;
    try {
      return await fetchJSON(url, { headers: { Authorization: `Bearer ${await this.accessToken()}` } });
    } catch (e) {
      if (e instanceof HttpError && e.status === 401 && !retried) {
        this.token = undefined; // expired (tokens last 30 min): refresh once
        return this.get(path, params, true);
      }
      if (e instanceof HttpError && e.status === 429) {
        throw new Error(`OpenSky credits exhausted; retry in ${e.retryAfterS ?? "?"} s`);
      }
      throw e;
    }
  }

  private async accessToken(): Promise<string> {
    if (this.token && Date.now() < this.token.expires) return this.token.value;
    const res = await fetch(TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "client_credentials",
        client_id: this.clientId,
        client_secret: this.clientSecret,
      }),
    });
    if (!res.ok) throw new HttpError(res.status, TOKEN_URL, await res.text());
    const t = Token.parse(await res.json());
    this.token = { value: t.access_token, expires: Date.now() + (t.expires_in - 60) * 1000 };
    return t.access_token;
  }
}
