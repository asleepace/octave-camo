/** Parsing and error handling at the edges: API payloads, analyzer JSON, secrets, matched helpers. */
import { afterEach, describe, expect, test } from "bun:test";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { AnalysisJSON } from "../src/analyzer.ts";
import { compare, tolerances } from "../src/report.ts";
import { loadTracks } from "../src/sources/file.ts";
import { HttpError, fetchJSON, requireEnv } from "../src/sources/types.ts";
import { maskPath, peaks, squareGrid, zScores, type Spectrogram } from "../src/matched.ts";
import { defaultMatchedConfig } from "../src/matched.ts";
import { groundTruth } from "../src/track.ts";
import { clipInfo, straightTrack } from "./helpers.ts";

const tmp = (name: string) => join(tmpdir(), `${crypto.randomUUID()}-${name}`);

describe("flight data payloads", () => {
  test("OpenSky: the misspelled 'calllsign' field is accepted and trimmed", async () => {
    const path = tmp("os.json");
    await Bun.write(path, JSON.stringify({ icao24: "abc123", startTime: 1, endTime: 2, calllsign: "SWA42   ",
                                           path: [[1, 37.7, -122.4, 1000, 90, false], [2, 37.71, -122.41, 1000, 90, false]] }));
    const [t] = await loadTracks(path);
    expect(t!.callsign).toBe("SWA42");
  });

  test("Flightradar24: a single object (not an array) is accepted", async () => {
    const path = tmp("fr.json");
    await Bun.write(path, JSON.stringify({ fr24_id: "abc", tracks: [{ timestamp: "2026-11-03T02:33:30Z", lat: 37.7, lon: -122.4, alt: 1000 }] }));
    const [t] = await loadTracks(path);
    expect(t!.id).toBe("abc");
    expect(t!.points[0]!.altM).toBeCloseTo(304.8, 6);
  });

  test("a track with too few points can't produce ground truth", () => {
    const track = { ...straightTrack({ offsetNorthM: 900, heightM: 1200, speed: 75, t0: 30 }), points: [] };
    expect(() => groundTruth(track, clipInfo())).toThrow(/fewer than 2 points/);
  });
});

describe("secrets and HTTP errors", () => {
  const saved = process.env.OPENSKY_CLIENT_ID;
  afterEach(() => { if (saved === undefined) delete process.env.OPENSKY_CLIENT_ID; else process.env.OPENSKY_CLIENT_ID = saved; });

  test("missing credentials name the variable and point at .env.example", () => {
    delete process.env.OPENSKY_CLIENT_ID;
    expect(() => requireEnv("OPENSKY_CLIENT_ID", "OpenSky API client id")).toThrow(/OPENSKY_CLIENT_ID.*\.env\.example/);
  });

  test("error messages never include the query string", () => {
    const e = new HttpError(400, "https://api.example.com/x?token=SECRET&lat=37.7", "bad");
    expect(e.message).not.toContain("SECRET");
    expect(e.message).not.toContain("37.7");
  });

  test("404 means 'no data', other failures carry the retry hint", async () => {
    const server = Bun.serve({
      port: 0,
      fetch: (req) => new URL(req.url).pathname === "/missing"
        ? new Response("", { status: 404 })
        : new Response("slow down", { status: 429, headers: { "X-Rate-Limit-Retry-After-Seconds": "17" } }),
    });
    try {
      expect(await fetchJSON(`http://localhost:${server.port}/missing`, {})).toBeUndefined();
      const err = await fetchJSON(`http://localhost:${server.port}/busy`, {}).catch((e) => e);
      expect(err).toBeInstanceOf(HttpError);
      expect((err as HttpError).status).toBe(429);
      expect((err as HttpError).retryAfterS).toBe(17);
    } finally {
      server.stop(true);
    }
  });
});

describe("analyzer JSON (the Swift CLI's payload)", () => {
  test("a missing consensus is fine (Swift omits nil optionals)", () => {
    const a = AnalysisJSON.parse({ tracks: [{ kind: "noFit", meanFrequency: 100, minFrequency: 90, maxFrequency: 110, duration: 3 }] });
    expect(a.consensus).toBeUndefined();
  });
  test("unknown track kinds are rejected", () => {
    expect(() => AnalysisJSON.parse({ tracks: [{ kind: "ufo", meanFrequency: 1, minFrequency: 1, maxFrequency: 1, duration: 1 }] })).toThrow();
  });
});

describe("verify comparison", () => {
  const truth = groundTruth(straightTrack({ offsetNorthM: 900, heightM: 1200, speed: 75, t0: 30 }), clipInfo())!;
  test("barometric tracks get a wider distance tolerance", () => {
    expect(tolerances(truth).distanceM).toBeCloseTo(0.1 * truth.distanceM + 20, 6); // helper tracks are geometric
    expect(tolerances({ ...truth, altitudeKind: "barometric" }).distanceM).toBeCloseTo(0.1 * truth.distanceM + 100, 6);
  });
  test("recovered needs both distance and time within tolerance", () => {
    const at = (distance: number, t0: number) => compare(truth, { tracks: [], consensus: { f0: 120, speed: 75, t0, distance } });
    expect(at(truth.distanceM, truth.t0).recovered).toBe(true);
    expect(at(truth.distanceM * 1.5, truth.t0).recovered).toBe(false);
    expect(at(truth.distanceM, truth.t0 + 5).recovered).toBe(false);
    expect(compare(truth, { tracks: [] }).recovered).toBe(false);
  });
});

describe("matched-attack helpers", () => {
  test("square grid has (2n+1)² cells including the center", () => {
    const g = squareGrid({ east: 0, north: 0 }, 2_000, 1_000);
    expect(g).toHaveLength(25);
    expect(g.some((c) => c.east === 0 && c.north === 0)).toBe(true);
  });
  test("robust z-scores ignore a single outlier when estimating spread", () => {
    const z = zScores(Float64Array.from([1, 2, 1, 2, 1, 2, 100]));
    expect(z[6]!).toBeGreaterThan(50);
    expect(Math.abs(z[0]!)).toBeLessThan(2);
  });
  test("peaks keep the minimum separation", () => {
    const cells = [{ east: 0, north: 0 }, { east: 100, north: 0 }, { east: 5_000, north: 0 }];
    const p = peaks(cells, Float64Array.from([10, 9, 8]), 3, 1_000);
    expect(p.map((c) => c.east)).toEqual([0, 5_000]);
  });
  test("maskPath zeroes the path and its harmonics", () => {
    const bins = 200, frames = 4;
    const spec: Spectrogram = { times: Float64Array.from([0, 1, 2, 3]), binHz: 1, bins, data: new Float32Array(frames * bins).fill(5) };
    maskPath(spec, Float64Array.from([1, 1, 1, 1]), 50, { ...defaultMatchedConfig, harmonics: 2, maskHalfWidthBins: 1 });
    for (let t = 0; t < frames; t++) {
      for (const k of [49, 50, 51, 99, 100, 101]) expect(spec.data[t * bins + k]).toBe(0);
      expect(spec.data[t * bins + 75]).toBe(5);
    }
  });
});
