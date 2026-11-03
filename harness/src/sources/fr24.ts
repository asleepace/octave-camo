import { z } from "zod";
import type { ClipInfo } from "../clip.ts";
import { FEET, boundingBox } from "../geo.ts";
import type { FlightTrack } from "../track.ts";
import { type FindOptions, type TrackSource, clipMidpoint, fetchJSON, requireEnv } from "./types.ts";

const API = "https://fr24api.flightradar24.com/api";

/** Track points: ISO timestamps, altitude in feet (barometric), ground speed in knots. */
const FR24Point = z.object({
  timestamp: z.string(),
  lat: z.number(),
  lon: z.number(),
  alt: z.number(),
  gspeed: z.number().optional(),
  callsign: z.string().optional(),
});
const FR24TrackEntry = z.object({
  fr24_id: z.string().optional(),
  tracks: z.array(FR24Point),
});
/** /flight-tracks has been seen returning both an array of entries and a single entry. */
export const FR24Tracks = z.union([z.array(FR24TrackEntry), FR24TrackEntry]);

const FR24Positions = z.object({
  data: z.array(z.object({
    fr24_id: z.string(),
    callsign: z.string().optional(),
    hex: z.string().optional(),
  })),
});

export function toFlightTrack(raw: z.infer<typeof FR24Tracks>, fallbackId: string): FlightTrack {
  const entry = Array.isArray(raw) ? raw[0] : raw;
  if (!entry) throw new Error(`empty Flightradar24 track for ${fallbackId}`);
  const callsign = entry.tracks.find((p) => p.callsign)?.callsign?.trim() || undefined;
  return {
    source: "fr24",
    id: entry.fr24_id ?? fallbackId,
    callsign,
    altitudeKind: "barometric",
    points: entry.tracks.map((p) => ({ t: Date.parse(p.timestamp) / 1000, lat: p.lat, lon: p.lon, altM: p.alt * FEET })),
  };
}

/**
 * Bounds for the positions endpoints. FR24's docs give "north,south,west,east"; some client
 * libraries document lat/lon corner pairs. Override with FR24_BOUNDS_ORDER=swne if the
 * search comes back empty or 400s for an area you know had traffic.
 */
export function formatBounds(box: ReturnType<typeof boundingBox>, order = process.env.FR24_BOUNDS_ORDER ?? "nswe") {
  const f = (v: number) => v.toFixed(4);
  return order === "swne"
    ? [box.south, box.west, box.north, box.east].map(f).join(",")
    : [box.north, box.south, box.west, box.east].map(f).join(",");
}

export class Flightradar24 implements TrackSource {
  readonly name = "fr24" as const;

  constructor(private readonly token = requireEnv("FR24_API_TOKEN", "Flightradar24 API token")) {}

  async findTracks(clip: ClipInfo, o: FindOptions): Promise<FlightTrack[]> {
    const ids = o.flightId ? [o.flightId] : await this.flightsNear(clip, o);
    const tracks = await Promise.all(ids.map((id) => this.track(id)));
    return tracks.filter((t): t is FlightTrack => t !== undefined);
  }

  async track(flightId: string): Promise<FlightTrack | undefined> {
    const raw = await this.get("/flight-tracks", { flight_id: flightId });
    return raw === undefined ? undefined : toFlightTrack(FR24Tracks.parse(raw), flightId);
  }

  /** Flights inside the search box at the clip's midpoint (filtered by callsign if given). */
  async flightsNear(clip: ClipInfo, o: FindOptions): Promise<string[]> {
    const params: Record<string, string> = {
      bounds: formatBounds(boundingBox(clip.location, o.radiusKm)),
      timestamp: String(clipMidpoint(clip)),
    };
    if (o.callsign) params.callsigns = o.callsign.trim().toUpperCase();
    const raw = await this.get("/historic/flight-positions/full", params);
    if (raw === undefined) return [];
    let rows = FR24Positions.parse(raw).data;
    if (o.icao24) rows = rows.filter((r) => r.hex?.toLowerCase() === o.icao24!.toLowerCase());
    return [...new Set(rows.map((r) => r.fr24_id))];
  }

  private get(path: string, params: Record<string, string>) {
    return fetchJSON(`${API}${path}?${new URLSearchParams(params)}`, {
      headers: { Accept: "application/json", "Accept-Version": "v1", Authorization: `Bearer ${this.token}` },
    });
  }
}
