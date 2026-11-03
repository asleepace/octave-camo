import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { parseISO6709, parseTimestamp } from "../src/clip.ts";
import { FEET, boundingBox } from "../src/geo.ts";
import { loadTracks, saveTracks } from "../src/sources/file.ts";
import { formatBounds } from "../src/sources/fr24.ts";
import { PHONE, straightTrack } from "./helpers.ts";

const fixture = (name: string) => join(import.meta.dir, "fixtures", name);

describe("clip metadata parsing", () => {
  test("ISO 6709 with altitude (iPhone)", () => {
    expect(parseISO6709("+37.7465-122.4334+106.217/")).toEqual({ lat: 37.7465, lon: -122.4334, altM: 106.217 });
  });
  test("ISO 6709 without altitude", () => {
    expect(parseISO6709("-33.8688+151.2093/")).toEqual({ lat: -33.8688, lon: 151.2093, altM: 0 });
  });
  test("Apple local timestamp and ffmpeg UTC timestamp agree", () => {
    expect(parseTimestamp("2026-11-02T18:33:13-0800")).toBe(parseTimestamp("2026-11-03T02:33:13.000000Z"));
  });
  test("garbage is rejected", () => {
    expect(() => parseISO6709("somewhere")).toThrow();
    expect(() => parseTimestamp("yesterday")).toThrow();
  });
});

describe("track files", () => {
  test("OpenSky /tracks/all response: drops nulls and on-ground rows", async () => {
    const [t] = await loadTracks(fixture("opensky-track.json"));
    expect(t!.source).toBe("opensky");
    expect(t!.id).toBe("a1b2c3");
    expect(t!.callsign).toBe("UAL123");
    expect(t!.points).toHaveLength(2);
    expect(t!.points[0]!.altM).toBe(1219);
  });

  test("Flightradar24 /flight-tracks response: feet to meters, ISO times", async () => {
    const [t] = await loadTracks(fixture("fr24-track.json"));
    expect(t!.source).toBe("fr24");
    expect(t!.id).toBe("3cee6c82");
    expect(t!.points[0]!.altM).toBeCloseTo(4000 * FEET, 6);
    expect(t!.points[0]!.t).toBe(Date.parse("2026-11-03T02:33:30Z") / 1000);
  });

  test("saved tracks round trip", async () => {
    const path = join(tmpdir(), `track-${crypto.randomUUID()}.json`);
    const original = straightTrack({ offsetNorthM: 900, heightM: 1200, speed: 75, t0: 30 });
    await saveTracks(path, [original]);
    expect(await loadTracks(path)).toEqual([original]);
  });

  test("anything else is rejected", async () => {
    const path = join(tmpdir(), `junk-${crypto.randomUUID()}.json`);
    await Bun.write(path, JSON.stringify({ hello: "world" }));
    expect(loadTracks(path)).rejects.toThrow();
  });
});

describe("Flightradar24 bounds", () => {
  const box = boundingBox(PHONE, 10);
  test("north,south,west,east by default", () => {
    const [n, s, w, e] = formatBounds(box, "nswe").split(",").map(Number);
    expect(n!).toBeGreaterThan(s!);
    expect(w!).toBeLessThan(e!);
    expect(n!).toBeGreaterThan(37);
  });
  test("south,west,north,east when overridden", () => {
    const [s, w, n] = formatBounds(box, "swne").split(",").map(Number);
    expect(s!).toBeLessThan(n!);
    expect(w!).toBeLessThan(-122);
  });
});
