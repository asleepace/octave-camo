import { describe, expect, test } from "bun:test";
import { boundingBox, norm, toENU } from "../src/geo.ts";
import { groundTruth, predictedDopplerRatio } from "../src/track.ts";
import { PHONE, clipInfo, fromENU, straightTrack } from "./helpers.ts";

describe("geo", () => {
  test("ENU of a point 1 km north and 500 m up", () => {
    const [e, n, u] = toENU(fromENU([0, 1000, 500], PHONE), PHONE);
    expect(e).toBeCloseTo(0, 1);
    expect(n).toBeCloseTo(1000, -1); // within a few meters
    expect(u).toBeCloseTo(500, 0);
  });

  test("ENU round trip is exact at 7 km", () => {
    const p: [number, number, number] = [-7000, 900, 1200];
    const back = toENU(fromENU(p, PHONE), PHONE);
    expect(norm([back[0] - p[0], back[1] - p[1], back[2] - p[2]])).toBeLessThan(0.01);
  });

  test("bounding box spans ±radius", () => {
    const b = boundingBox(PHONE, 15);
    expect((b.north - b.south) * 111.32).toBeCloseTo(30, 1);
    expect(b.west).toBeLessThan(PHONE.lon);
    expect(b.east).toBeGreaterThan(PHONE.lon);
  });
});

describe("ground truth", () => {
  const track = straightTrack({ offsetNorthM: 900, heightM: 1200, speed: 75, t0: 30 });
  const truth = groundTruth(track, clipInfo())!;

  test("closest approach distance, speed, height", () => {
    expect(truth.distanceM).toBeCloseTo(1500, -1);
    expect(truth.speedMps).toBeCloseTo(75, 0);
    expect(truth.heightM).toBeCloseTo(1200, -1);
    expect(truth.horizontalDistanceM).toBeCloseTo(900, -1);
  });

  test("t0 is the heard time, including travel time", () => {
    expect(truth.t0).toBeCloseTo(30, 0);
    expect(truth.inClip).toBe(true);
  });

  test("closest approach outside the clip is flagged", () => {
    const late = groundTruth(straightTrack({ offsetNorthM: 900, heightM: 1200, speed: 75, t0: 90 }), clipInfo())!;
    expect(late.inClip).toBe(false);
  });

  test("no overlap with the clip window gives no truth", () => {
    const far = straightTrack({ offsetNorthM: 900, heightM: 1200, speed: 75, t0: 3_600 });
    expect(groundTruth(far, clipInfo())).toBeUndefined();
  });

  test("predicted Doppler is unshifted at t0, higher before, lower after", () => {
    const [before, at, after] = predictedDopplerRatio(track, clipInfo(), [0, truth.t0, 60]);
    expect(at!).toBeCloseTo(1, 3);
    expect(before!).toBeGreaterThan(1.05);
    expect(after!).toBeLessThan(0.95);
  });
});
