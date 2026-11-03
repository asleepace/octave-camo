import { z } from "zod";
import type { LatLonAlt } from "./geo.ts";

/** What the clip's own metadata says: where and when it was recorded. Used as ground truth. */
export type ClipInfo = {
  path: string;
  location: LatLonAlt;
  /** Horizontal accuracy reported by the phone, m (undefined if absent). */
  locationAccuracyM?: number;
  /** Recording start, Unix seconds (QuickTime metadata has 1 s resolution). */
  startTime: number;
  durationS: number;
  device?: string;
};

const FFProbe = z.object({
  format: z.object({
    duration: z.coerce.number(),
    tags: z.record(z.string(), z.string()).default({}),
  }),
});

/** "+37.7465-122.4334+106.217/" → lat, lon, altitude (m). */
export function parseISO6709(s: string): LatLonAlt {
  const m = /^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)?(?:CRS[^/]*)?\/?$/.exec(s.trim());
  if (!m) throw new Error(`unrecognized ISO 6709 location: ${s}`);
  return { lat: Number(m[1]), lon: Number(m[2]), altM: m[3] ? Number(m[3]) : 0 };
}

/** Accepts "2026-11-02T18:33:13-0800" (Apple) and "2026-11-03T02:33:13.000000Z" (ffmpeg). */
export function parseTimestamp(s: string): number {
  const normalized = s.trim().replace(/([+-]\d{2})(\d{2})$/, "$1:$2");
  const ms = Date.parse(normalized);
  if (Number.isNaN(ms)) throw new Error(`unrecognized timestamp: ${s}`);
  return ms / 1000;
}

function firstTag(tags: Record<string, string>, keys: string[]): string | undefined {
  for (const k of keys) if (tags[k]) return tags[k];
  return undefined;
}

export async function readClipInfo(path: string): Promise<ClipInfo> {
  const out = await run(["ffprobe", "-v", "error", "-show_entries", "format=duration:format_tags", "-of", "json", path]);
  const { format } = FFProbe.parse(JSON.parse(out));
  const tags = format.tags;

  const loc = firstTag(tags, ["com.apple.quicktime.location.ISO6709", "location", "location-eng"]);
  if (!loc) throw new Error(`${path} has no location metadata (was it already stripped?)`);
  const time = firstTag(tags, ["com.apple.quicktime.creationdate", "creation_time"]);
  if (!time) throw new Error(`${path} has no creation time metadata`);
  const accuracy = tags["com.apple.quicktime.location.accuracy.horizontal"];

  return {
    path,
    location: parseISO6709(loc),
    locationAccuracyM: accuracy ? Number(accuracy) : undefined,
    startTime: parseTimestamp(time),
    durationS: format.duration,
    device: firstTag(tags, ["com.apple.quicktime.model"]),
  };
}

/** First audio track as 48 kHz stereo float WAV (iPhones add a 4-channel spatial track; skip it). */
export async function extractAudio(videoPath: string, wavPath: string): Promise<void> {
  await run(["ffmpeg", "-loglevel", "error", "-y", "-i", videoPath, "-map", "0:a:0", "-vn",
             "-ac", "2", "-ar", "48000", "-c:a", "pcm_f32le", wavPath]);
}

export async function run(cmd: string[], env?: Record<string, string>): Promise<string> {
  const proc = Bun.spawn(cmd, { stdout: "pipe", stderr: "pipe", env: { ...process.env, ...env } });
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (code !== 0) throw new Error(`${cmd[0]} exited ${code}: ${stderr.trim()}`);
  return stdout;
}
