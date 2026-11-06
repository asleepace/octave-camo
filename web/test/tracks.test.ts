import { describe, expect, test } from "bun:test";
import { archiveBytes, archiveFiles, concat, fromUtcField, looksLikeArchive, parseIso6709, recordedFrom, toUtcField } from "../src/tracks.ts";
import { writeArchive } from "./archive.ts";

describe("where and when, from the file", () => {
  test("ISO 6709 as phones write it", () => {
    expect(parseIso6709("+37.7749-122.4194+012.345/")).toEqual({ latitude: 37.7749, longitude: -122.4194, altitude: 12.345 });
    expect(parseIso6709("-33.8688+151.2093/")).toEqual({ latitude: -33.8688, longitude: 151.2093 });
    expect(parseIso6709("+95.0000+000.0000/")).toEqual({});
    expect(parseIso6709("nonsense")).toEqual({});
  });

  test("Apple's key, the older ©xyz atom, and the dates", () => {
    const date = new Date(Date.UTC(2026, 10, 5, 8, 38, 25));
    expect(recordedFrom({ raw: { "com.apple.quicktime.location.ISO6709": "+40.0000-100.0000+001.000/" }, date }))
      .toEqual({ latitude: 40, longitude: -100, altitude: 1, time: date.getTime() / 1000 });
    // ©xyz: a 2-byte length and a 2-byte language code before the text.
    const xyz = new Uint8Array([0, 18, 0x15, 0xc7, ...new TextEncoder().encode("+40.0000-100.0000/")]);
    expect(recordedFrom({ raw: { "©xyz": xyz }, creationTime: date })).toEqual({ latitude: 40, longitude: -100, time: date.getTime() / 1000 });
    // A movie header left at its 1904 epoch, or a date in the future, is not a recording time.
    expect(recordedFrom({ creationTime: new Date(Date.UTC(1904, 0, 1)) })).toEqual({});
    expect(recordedFrom({ date: new Date(Date.now() + 10 * 86_400_000) })).toEqual({});
    expect(recordedFrom({})).toEqual({});
  });

  test("the UTC field round-trips, and a minute-only value parses", () => {
    const t = Date.UTC(2026, 10, 5, 8, 38, 25) / 1000;
    expect(fromUtcField(toUtcField(t))).toBe(t);
    expect(fromUtcField("2026-11-05T08:38")).toBe(t - 25);
    expect(fromUtcField("")).toBeNull();
  });
});

describe("the archive", () => {
  const start = Date.UTC(2026, 10, 5, 8, 38, 25) / 1000;

  test("names the half-hour files covering a clip, with two minutes either side", () => {
    expect(archiveFiles(start, 60).map((f) => f.url)).toEqual(["https://adsb.lol/globe_history/2026/11/05/heatmap/17.bin.ttf"]);
    expect(archiveFiles(start, 60)[0]!.label).toBe("2026-11-05 08:30–09:00 UTC");
    // Ends within two minutes of 09:00: the next file too.
    expect(archiveFiles(start, 1_200).map((f) => f.name)).toEqual(["2026-11-05-17.bin.ttf", "2026-11-05-18.bin.ttf"]);
    // Across midnight.
    expect(archiveFiles(Date.UTC(2026, 11, 31, 23, 59) / 1000, 10).map((f) => f.name)).toEqual(["2026-12-31-47.bin.ttf", "2027-01-01-00.bin.ttf"]);
  });

  test("recognises an archive by its structure, gzipped or not", async () => {
    const a = writeArchive([{ time: start, aircraft: [{ id: 0xabc123, lat: 40, lon: -100, feet: 4_500, knots: 250 }] }, { time: start + 10, aircraft: [] }]);
    expect(looksLikeArchive(a)).toBe(true);
    expect(looksLikeArchive(a.subarray(0, a.length - 4))).toBe(false);
    expect(looksLikeArchive(new TextEncoder().encode("<html>not found</html>".padEnd(48)))).toBe(false);
    const gz = new Uint8Array(await new Response(new Blob([a]).stream().pipeThrough(new CompressionStream("gzip"))).arrayBuffer());
    expect(await archiveBytes(new Blob([gz]))).toEqual(a);
    expect(await archiveBytes(new Blob([a]))).toEqual(a);
    expect(concat([a, a]).length).toBe(2 * a.length);
  });
});
