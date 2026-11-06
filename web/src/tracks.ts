/**
 * Flight-track removal on the page: where and when a clip was recorded (from its own metadata, or
 * typed in), and adsb.lol's half-hour flight archive, which the user downloads themselves. The
 * page never fetches it (adsb.lol sends no CORS headers, and the page makes no requests anyway):
 * the link names only a date and half hour, the same worldwide file for everyone, so it says
 * nothing about the place. Everything else stays in the browser.
 */
import type { MetadataTags } from "mediabunny";

/** Where and when, as far as the file says. */
export type Recorded = {
  latitude?: number;
  longitude?: number;
  /** Metres, when the file gives it. */
  altitude?: number;
  /** Unix time the recording started, s. */
  time?: number;
};

/** ISO 6709 as phones write it: "+37.7749-122.4194+012.345/" (decimal degrees, optional height). */
export function parseIso6709(text: string): Recorded {
  const m = /([+-]\d{1,2}(?:\.\d+)?)([+-]\d{1,3}(?:\.\d+)?)([+-]\d+(?:\.\d+)?)?/.exec(text);
  if (!m) return {};
  const latitude = Number(m[1]), longitude = Number(m[2]), altitude = m[3] === undefined ? undefined : Number(m[3]);
  if (!(Math.abs(latitude) <= 90 && Math.abs(longitude) <= 180)) return {};
  return { latitude, longitude, ...(altitude !== undefined && Number.isFinite(altitude) ? { altitude } : {}) };
}

const decodeText = (v: unknown): string | null => {
  if (typeof v === "string") return v;
  if (v instanceof Uint8Array) return new TextDecoder("utf-8", { fatal: false }).decode(v);
  return null;
};

/** A plausible recording time: after 2000 and not in the future (by more than a day). */
const plausible = (d: Date | null | undefined): d is Date =>
  !!d && Number.isFinite(d.getTime()) && d.getTime() > Date.UTC(2000, 0, 1) && d.getTime() < Date.now() + 86_400_000;

/** The place and start time a file's metadata gives: Apple's ISO 6709 key or the older '©xyz'
 *  atom (Android, older iPhones); the QuickTime creation date, else the movie header's time. */
export function recordedFrom(tags: MetadataTags): Recorded {
  const out: Recorded = {};
  for (const [key, value] of Object.entries(tags.raw ?? {})) {
    if (!/ISO6709|xyz|location/i.test(key)) continue;
    const text = decodeText(value);
    // '©xyz' holds a 2-byte length and 2-byte language before the text.
    const place = text ? parseIso6709(text.replace(/^[\s\S]{0,4}?(?=[+-]\d)/, "")) : {};
    if (place.latitude !== undefined) { Object.assign(out, place); break; }
  }
  const date = plausible(tags.date) ? tags.date : plausible(tags.creationTime) ? tags.creationTime : null;
  if (date) out.time = date.getTime() / 1000;
  return out;
}

/** Positions this far beyond the clip help the curves at its edges, s. */
export const MARGIN_SECONDS = 120;

const two = (n: number) => String(n).padStart(2, "0");

/** The half-hour archive files covering a recording (one, or two across a boundary). */
export function archiveFiles(start: number, duration: number): { url: string; name: string; label: string }[] {
  const out: { url: string; name: string; label: string }[] = [];
  const first = Math.floor((start - MARGIN_SECONDS) / 1800), last = Math.floor((start + duration + MARGIN_SECONDS) / 1800);
  for (let k = first; k <= last; k++) {
    const d = new Date(k * 1800 * 1000), half = d.getUTCHours() * 2 + (d.getUTCMinutes() >= 30 ? 1 : 0);
    const day = `${d.getUTCFullYear()}/${two(d.getUTCMonth() + 1)}/${two(d.getUTCDate())}`;
    const end = new Date((k + 1) * 1800 * 1000);
    out.push({
      url: `https://adsb.lol/globe_history/${day}/heatmap/${two(half)}.bin.ttf`,
      name: `${day.replaceAll("/", "-")}-${two(half)}.bin.ttf`,
      label: `${day.replaceAll("/", "-")} ${two(d.getUTCHours())}:${two(d.getUTCMinutes())}–${two(end.getUTCHours())}:${two(end.getUTCMinutes())} UTC`,
    });
  }
  return out;
}

/** The file's bytes, un-gzipped when it's still compressed (a browser usually saves it decoded). */
export async function archiveBytes(file: Blob): Promise<Uint8Array<ArrayBuffer>> {
  const head = new Uint8Array(await file.slice(0, 2).arrayBuffer());
  if (head[0] === 0x1f && head[1] === 0x8b) {
    const stream = file.stream().pipeThrough(new DecompressionStream("gzip"));
    return new Uint8Array(await new Response(stream).arrayBuffer());
  }
  return new Uint8Array(await file.arrayBuffer());
}

/** Does this look like an archive? Whole 16-byte records: a count of its 10 s blocks, a table of
 *  where they start, then the first block's time marker. */
export function looksLikeArchive(bytes: Uint8Array): boolean {
  if (bytes.length < 32 || bytes.length % 16 !== 0) return false;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength), blocks = view.getInt32(0, true);
  return blocks >= 1 && blocks <= 1_000 && (blocks + 1) * 16 <= bytes.length && view.getInt32(blocks * 16, true) === 0x0e7f7c9d;
}

export const concat = (parts: Uint8Array[]): Uint8Array<ArrayBuffer> => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};

/** "2026-11-05T08:38:25" in UTC, for a datetime-local field read as UTC. */
export const toUtcField = (unix: number) => new Date(Math.round(unix) * 1000).toISOString().slice(0, 19);
export const fromUtcField = (text: string): number | null => {
  const t = Date.parse(`${text.length === 16 ? `${text}:00` : text}Z`);
  return Number.isFinite(t) ? t / 1000 : null;
};
