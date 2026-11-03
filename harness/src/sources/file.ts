import { z } from "zod";
import type { FlightTrack } from "../track.ts";
import * as fr24 from "./fr24.ts";
import * as opensky from "./opensky.ts";

const SavedTrack = z.object({
  source: z.enum(["opensky", "fr24", "file"]),
  id: z.string(),
  callsign: z.string().optional(),
  altitudeKind: z.enum(["barometric", "geometric"]),
  points: z.array(z.object({ t: z.number(), lat: z.number(), lon: z.number(), altM: z.number() })),
});
const SavedTracks = z.union([SavedTrack, z.array(SavedTrack)]);

/**
 * Loads tracks from disk: a file written by --save-track, or a raw OpenSky /tracks/all or
 * Flightradar24 /flight-tracks response. Replaying saved tracks costs no API credits.
 */
export async function loadTracks(path: string): Promise<FlightTrack[]> {
  const json: unknown = await Bun.file(path).json();
  const saved = SavedTracks.safeParse(json);
  if (saved.success) return Array.isArray(saved.data) ? saved.data : [saved.data];
  const os = opensky.OpenSkyTrack.safeParse(json);
  if (os.success) return [opensky.toFlightTrack(os.data)];
  const fr = fr24.FR24Tracks.safeParse(json);
  if (fr.success) return [fr24.toFlightTrack(fr.data, path)];
  throw new Error(`${path}: not a saved track, OpenSky track or Flightradar24 track`);
}

export async function saveTracks(path: string, tracks: FlightTrack[]): Promise<void> {
  await Bun.write(path, JSON.stringify(tracks, null, 2));
}
