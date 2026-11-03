/**
 * Strips SEI from H.264 and HEVC streams before they are copied into the cloaked file.
 *
 * SEI ("supplemental enhancement information") NAL units ride inside the video packets, not the
 * container, so dropping container metadata doesn't touch them. Encoders and cameras put things
 * there that identify the recording: x264 writes its version and every setting, camcorders
 * (AVCHD) write the recording date and GPS, some drones write telemetry. Decoders don't need SEI
 * to show the picture; HDR and caption SEI go too, which at worst changes how HDR is tone-mapped.
 *
 * Packets come either length-prefixed (MP4/MOV/MKV: the decoder config's `description` gives the
 * prefix size) or in Annex B (start codes, e.g. MPEG-TS with no description).
 */

export type NalCodec = "avc" | "hevc";

/** NAL unit type of a NAL unit's first byte(s). */
const nalType = (codec: NalCodec, first: number) => (codec === "avc" ? first & 0x1f : (first >> 1) & 0x3f);
/** SEI: H.264 type 6; HEVC prefix (39) and suffix (40) SEI. */
const isSei = (codec: NalCodec, type: number) => (codec === "avc" ? type === 6 : type === 39 || type === 40);

/** Length-prefix size from an avcC or hvcC record (1, 2 or 4 bytes). */
export function lengthSize(codec: NalCodec, description: Uint8Array): number {
  const at = codec === "avc" ? 4 : 21;
  if (description.length <= at) throw new Error("video codec configuration is too short");
  return (description[at]! & 0x03) + 1;
}

/** NAL units of a length-prefixed packet, as subarrays; null if the lengths don't add up. */
function splitLengthPrefixed(data: Uint8Array, size: number): Uint8Array[] | null {
  const units: Uint8Array[] = [];
  let i = 0;
  while (i < data.length) {
    if (i + size > data.length) return null;
    let n = 0;
    for (let k = 0; k < size; k++) n = n * 256 + data[i + k]!;
    i += size;
    if (n === 0 || i + n > data.length) return null;
    units.push(data.subarray(i, i + n));
    i += n;
  }
  return units;
}

/** NAL units of an Annex B packet (between 00 00 01 / 00 00 00 01 start codes). */
function splitAnnexB(data: Uint8Array): Uint8Array[] {
  const starts: { at: number; code: number }[] = [];
  for (let i = 0; i + 2 < data.length; i++) {
    if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 1) {
      starts.push({ at: i + 3, code: i > 0 && data[i - 1] === 0 ? 4 : 3 });
      i += 2;
    }
  }
  return starts.map((s, k) => {
    const next = starts[k + 1];
    let end = next ? next.at - next.code : data.length;
    while (end > s.at && data[end - 1] === 0 && next) end--;     // trailing_zero_8bits
    return data.subarray(s.at, end);
  });
}

const isAnnexB = (data: Uint8Array) =>
  data.length >= 4 && data[0] === 0 && data[1] === 0 && (data[2] === 1 || (data[2] === 0 && data[3] === 1));

/**
 * The packet without SEI NAL units. Returns the input itself when there were none. Throws if the
 * packet can't be parsed (rather than copying something it couldn't inspect).
 */
export function stripSei(codec: NalCodec, data: Uint8Array, prefixSize: number | null): Uint8Array {
  const annexB = prefixSize === null || (isAnnexB(data) && splitLengthPrefixed(data, prefixSize) === null);
  const units = annexB ? (isAnnexB(data) ? splitAnnexB(data) : null) : splitLengthPrefixed(data, prefixSize!);
  if (!units || !units.length) throw new Error("couldn't parse a video packet to remove embedded data");
  const kept = units.filter((u) => u.length > 0 && !isSei(codec, nalType(codec, u[0]!)));
  if (kept.length === units.length) return data;
  const size = annexB ? 4 : prefixSize!;
  const out = new Uint8Array(kept.reduce((n, u) => n + size + u.length, 0));
  let i = 0;
  for (const u of kept) {
    if (annexB) out.set([0, 0, 0, 1], i);
    else for (let k = 0; k < size; k++) out[i + k] = (u.length >>> (8 * (size - 1 - k))) & 0xff;
    out.set(u, i + size);
    i += size + u.length;
  }
  return out;
}

/** True if any NAL unit in the packet is SEI. */
export function hasSei(codec: NalCodec, data: Uint8Array, prefixSize: number | null): boolean {
  return stripSei(codec, data, prefixSize) !== data;
}

/**
 * An hvcC record without its SEI arrays (HEVC configurations can carry prefix/suffix SEI for the
 * decoder to apply up front). avcC holds only parameter sets and is returned as is.
 */
export function stripSeiFromConfig(codec: NalCodec, description: Uint8Array): Uint8Array {
  if (codec !== "hevc") return description;
  if (description.length < 23) throw new Error("video codec configuration is too short");
  const arrays: Uint8Array[] = [];
  let i = 23, removed = false;
  for (let a = 0; a < description[22]!; a++) {
    if (i + 3 > description.length) throw new Error("malformed HEVC configuration");
    const start = i, type = description[i]! & 0x3f, count = (description[i + 1]! << 8) | description[i + 2]!;
    i += 3;
    for (let k = 0; k < count; k++) {
      if (i + 2 > description.length) throw new Error("malformed HEVC configuration");
      i += 2 + ((description[i]! << 8) | description[i + 1]!);
    }
    if (i > description.length) throw new Error("malformed HEVC configuration");
    if (isSei("hevc", type)) removed = true;
    else arrays.push(description.subarray(start, i));
  }
  if (!removed) return description;
  const out = new Uint8Array(23 + arrays.reduce((n, a) => n + a.length, 0));
  out.set(description.subarray(0, 22));
  out[22] = arrays.length;
  let at = 23;
  for (const a of arrays) { out.set(a, at); at += a.length; }
  return out;
}
