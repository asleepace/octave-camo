import { describe, expect, test } from "bun:test";
import { Request, WorkerMessage } from "../src/engine/protocol.ts";
import { neutralize, outputName } from "../src/media.ts";
import { BAND_COUNT, bandCenters, F_HI, F_LO, logX, meanBands, mix, percentile, spectrogram } from "../src/spectrum.ts";
import { bandChart } from "../src/ui/bands.ts";
import { formatHz } from "../src/ui/terrain.ts";
import { CONTENT_SECURITY_POLICY } from "../vite.config.ts";

describe("spectrum", () => {
  test("band centers are log spaced from F_LO to F_HI", () => {
    const c = bandCenters();
    expect(c.length).toBe(BAND_COUNT);
    expect(c[0]).toBeCloseTo(F_LO, 6);
    expect(c[BAND_COUNT - 1]).toBeCloseTo(F_HI, 3);
    expect(c[1]! / c[0]!).toBeCloseTo(c[BAND_COUNT - 1]! / c[BAND_COUNT - 2]!, 6);
    expect(logX(F_LO)).toBe(0);
    expect(logX(F_HI)).toBe(1);
    expect(logX(1)).toBe(0);
  });

  test("a sine peaks in its own band at about its level", () => {
    const sr = 16_000, x = new Float32Array(sr * 2);
    for (let i = 0; i < x.length; i++) x[i] = 0.5 * Math.sin((2 * Math.PI * 440 * i) / sr);
    const s = spectrogram(x, sr), mid = Math.floor(s.frames / 2), B = s.centers.length;
    const row = Array.from(s.db.subarray(mid * B, (mid + 1) * B));
    const peak = row.indexOf(Math.max(...row));
    expect(Math.abs(Math.log2(s.centers[peak]! / 440))).toBeLessThan(0.15);
    const quiet = row[row.length - 10]!;                 // a band far above the tone
    expect(row[peak]! - quiet).toBeGreaterThan(60);
    expect(meanBands(s)[peak]! - meanBands(s)[row.length - 10]!).toBeGreaterThan(60);
    expect(percentile(s, 0.999)).toBeGreaterThan(percentile(s, 0.1));
  });

  test("mix averages channels", () => {
    expect(Array.from(mix([Float32Array.of(1, 0), Float32Array.of(0, 1)]))).toEqual([0.5, 0.5]);
  });

  test("frequency labels", () => {
    expect([formatHz(31.5), formatHz(250), formatHz(1000), formatHz(1500), formatHz(16000)]).toEqual(["32", "250", "1k", "1.5k", "16k"]);
  });
});

describe("worker protocol", () => {
  const clip = { token: 1, sampleRate: 48_000, channels: [new Float32Array(10)] };
  test("accepts well-formed requests", () => {
    expect(Request.parse({ type: "analyze", ...clip }).type).toBe("analyze");
    expect(Request.parse({ type: "scrub", ...clip, steps: ["mono", "hum"], seed: 3, cutoff: 300, keepVoice: true }).type).toBe("scrub");
  });
  test("rejects malformed ones", () => {
    expect(() => Request.parse({ type: "scrub", ...clip, steps: ["rm -rf"], seed: 3, cutoff: 300, keepVoice: true })).toThrow();
    expect(() => Request.parse({ type: "scrub", ...clip, steps: [], seed: 0, cutoff: 300, keepVoice: true })).toThrow();
    expect(() => Request.parse({ type: "analyze", sampleRate: 100, channels: [] })).toThrow();
    expect(() => Request.parse({ type: "flicker", token: 1, frames: 1, strips: 6, rows: 4, values: new Float32Array(), times: new Float32Array(), clean: true, purpose: "clip" })).toThrow();
    expect(() => Request.parse({ type: "analyze", sampleRate: 48_000, channels: [new Float32Array(10)] })).toThrow();   // no token
  });
  test("worker messages are validated too", () => {
    expect(WorkerMessage.safeParse({ type: "stage", token: 1, stage: "analyzing" }).success).toBe(true);
    expect(WorkerMessage.safeParse({ type: "stage", stage: "analyzing" }).success).toBe(false);          // token is required
    expect(WorkerMessage.safeParse({ type: "error", token: 1, message: "x" }).success).toBe(false);      // so is scope
  });
});

describe("output", () => {
  const loaded = (video: boolean) => ({ video: video ? {} : null }) as Parameters<typeof outputName>[0];
  test("names are neutral and random, never derived from the original (which may hold a date)", () => {
    expect(outputName(loaded(true))).toMatch(/^camo-[a-z2-9]{6}\.mp4$/);
    expect(outputName(loaded(false))).toMatch(/^camo-[a-z2-9]{6}\.m4a$/);
    expect(outputName(loaded(true))).not.toBe(outputName(loaded(true)));
  });
  test("the muxer's name is removed from the file without changing its size", () => {
    const enc = new TextEncoder();
    const file = new Uint8Array([...enc.encode("xxMediabunnyVideoHandler\0yy"), 18, ...enc.encode("Mediabunny v1.65.0"), 0, 7,
      ...enc.encode("MediabunnySoundHandler\0")]);
    const out = neutralize(file.slice());
    const text = new TextDecoder().decode(out);
    expect(out.length).toBe(file.length);
    expect(text).not.toContain("Mediabunny");
    expect(text).toContain("VideoHandler");
    expect(text).toContain("SoundHandler");
    expect(out[out.indexOf(7) - 1]).toBe(0);              // compressor name cleared, bytes after untouched
  });
  test("the band chart marks the cutoff and draws both curves", () => {
    const c = bandCenters(), level = Float32Array.from(c, () => -40);
    const svg = bandChart(c, level, level, 300);
    expect(svg).toContain("regenerated below 300 Hz");
    expect(svg.match(/<path /g)?.length).toBe(3);   // fill + in + out
  });
});

describe("content security policy", () => {
  test("only the page's own origin can be contacted", () => {
    const directives: Record<string, string[]> = Object.fromEntries(CONTENT_SECURITY_POLICY.split("; ").map((d) => [d.split(" ")[0]!, d.split(" ").slice(1)]));
    expect(directives["default-src"]).toEqual(["'none'"]);
    expect(directives["connect-src"]).toEqual(["'self'", "blob:"]);
    expect(directives["script-src"]).not.toContain("'unsafe-eval'");
    expect(directives["script-src"]).not.toContain("'unsafe-inline'");
    for (const sources of Object.values(directives)) for (const s of sources) expect(s).not.toMatch(/^https?:|\*/);
  });
});
