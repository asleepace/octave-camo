import { describe, expect, test } from "bun:test";
import { Request, WorkerMessage } from "../src/engine/protocol.ts";
import { neutralize, outputName } from "../src/media.ts";
import { hasSei, lengthSize, stripSei, stripSeiFromConfig } from "../src/sei.ts";
import { BAND_COUNT, bandCenters, DETAIL_MAX_COLUMNS, DETAIL_ROWS, demoDetail, detail, detailHz, detailPercentile, F_HI, F_LO, logX, meanBands, mix, percentile, spectrogram } from "../src/spectrum.ts";
import { LUT, markBoxes, paint, timeTicks } from "../src/ui/heatmap.ts";
import { bandChart } from "../src/ui/bands.ts";
import { formatHz } from "../src/ui/terrain.ts";
import { CONTENT_SECURITY_POLICY } from "../vite.config.ts";
import { seededRandom } from "../src/random.ts";

describe("heatmap spectrogram", () => {
  const sine = (sr: number, seconds: number, hz: number, amp = 0.5) => {
    const x = new Float32Array(Math.round(sr * seconds));
    for (let i = 0; i < x.length; i++) x[i] = amp * Math.sin((2 * Math.PI * hz * i) / sr);
    return x;
  };
  const columnPeak = (d: ReturnType<typeof detail>, c: number) => {
    const col = Array.from(d.db.subarray(c * d.rows, (c + 1) * d.rows));
    return col.indexOf(Math.max(...col));
  };

  test("a tone is a thin line in its own row, low and high", () => {
    for (const hz of [60, 440, 3_000]) {
      const d = detail(sine(48_000, 3, hz), 48_000), c = Math.floor(d.columns / 2), peak = columnPeak(d, c);
      expect(Math.abs(Math.log2(detailHz(d, peak) / hz))).toBeLessThan(1 / 24);
      // A third of an octave away it is far down: a line, not a smear.
      const away = Math.round(d.rows / Math.log2(d.fHi / d.fLo) / 3);
      expect(d.db[c * d.rows + peak]! - d.db[c * d.rows + Math.min(d.rows - 1, peak + away)]!).toBeGreaterThan(30);
    }
  });

  test("shape: rows, columns capped, span, and a low sample rate's ceiling", () => {
    const d = detail(sine(48_000, 2, 440), 48_000);
    expect(d.rows).toBe(DETAIL_ROWS);
    expect(d.db.length).toBe(d.columns * d.rows);
    expect(d.seconds).toBeCloseTo(2, 6);
    expect(d.db.every(Number.isFinite)).toBe(true);
    const long = detail(new Float32Array(8_000 * 600), 8_000);
    expect(long.columns).toBe(DETAIL_MAX_COLUMNS);
    expect(long.fHi).toBeLessThan(4_000);
    expect(detailHz(long, long.rows - 1)).toBeCloseTo(long.fHi, 6);
  });

  test("pooling keeps a short tone in a long clip", () => {
    const sr = 8_000, x = new Float32Array(sr * 600);
    const at = sr * 300;                                 // 150 ms of 1 kHz, halfway through ten minutes
    for (let i = 0; i < sr * 0.15; i++) x[at + i] = 0.5 * Math.sin((2 * Math.PI * 1_000 * i) / sr);
    const d = detail(x, sr), c = Math.floor(d.columns / 2);
    const loudest = Math.max(...Array.from({ length: 5 }, (_, k) => d.db[(c - 2 + k) * d.rows + columnPeak(d, c)]!));
    expect(Math.abs(Math.log2(detailHz(d, columnPeak(d, c)) / 1_000))).toBeLessThan(1 / 24);
    expect(loudest).toBeGreaterThan(-20);
  });

  test("paint: low frequencies at the bottom, colors from the ramp", () => {
    const d = { db: new Float32Array([-100, 0, -100, 0]), columns: 2, rows: 2, seconds: 1, fLo: 30, fHi: 8_000 };
    const px = paint(d, [-100, 0]);
    // Row 0 (low, -100 dB) is the bottom pixel row: black. Row 1 (0 dB) is the top: the ramp's end.
    expect(Array.from(px.subarray(8, 11))).toEqual(Array.from(LUT.subarray(0, 3)));
    expect(Array.from(px.subarray(0, 3))).toEqual(Array.from(LUT.subarray(765, 768)));
    expect(px[3]).toBe(255);
    // Lightness only rises along the ramp.
    for (let i = 1; i < 256; i++) expect(LUT[i * 3]! + LUT[i * 3 + 1]! + LUT[i * 3 + 2]!).toBeGreaterThanOrEqual(LUT[(i - 1) * 3]! + LUT[(i - 1) * 3 + 1]! + LUT[(i - 1) * 3 + 2]!);
  });

  test("outlines: a found tone becomes a box at its time and frequency, at least 8 px tall", () => {
    const d = { seconds: 10, fLo: 30, fHi: 8_000 };
    const [box] = markBoxes([{ start: 2, end: 6, lo: 1_190, hi: 1_210, kind: "steady" }], d, 1000, 240);
    expect(box!.x).toBeCloseTo(200.5, 0);
    expect(box!.w).toBe(400);
    expect(box!.h).toBeGreaterThanOrEqual(8);
    const yOf = (f: number) => 240 * (1 - Math.log(f / 30) / Math.log(8_000 / 30));
    expect(box!.y).toBeLessThan(yOf(1_200));
    expect(box!.y + box!.h).toBeGreaterThan(yOf(1_200));
    // Outside the view: dropped; past the end of the clip: clamped.
    expect(markBoxes([{ start: 0, end: 1, lo: 10, hi: 20, kind: "hum" }], d, 1000, 240)).toEqual([]);
    expect(markBoxes([{ start: 8, end: 30, lo: 100, hi: 110, kind: "noFit" }], d, 1000, 240)[0]!.w).toBe(200);
  });

  test("time ticks are round and span the clip", () => {
    expect(timeTicks(24)).toEqual([0, 5, 10, 15, 20]);
    expect(timeTicks(300)).toEqual([0, 60, 120, 180, 240, 300]);
    expect(timeTicks(0)).toEqual([0]);
    for (const s of [1, 7, 59, 61, 299]) expect(timeTicks(s).length).toBeLessThanOrEqual(6);
  });

  test("the landing example: the illustration differs where the plane and hum were", () => {
    const { input, output } = demoDetail();
    expect(input.columns).toBe(output.columns);
    expect(detailPercentile(input, 0.999)).toBeGreaterThan(detailPercentile(output, 0.999));
  });
});

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
  test("channels must agree in length, and profiles must match their stated size", () => {
    expect(() => Request.parse({ type: "analyze", token: 1, sampleRate: 48_000, channels: [new Float32Array(10), new Float32Array(9)] })).toThrow();
    expect(() => Request.parse({ type: "analyze", token: 1, sampleRate: 48_000, channels: [new Float32Array(0)] })).toThrow();
    const profiles = { type: "flicker", token: 1, frames: 2, strips: 1, rows: 8, times: new Float32Array(2), clean: true, purpose: "clip" };
    expect(Request.parse({ ...profiles, values: new Float32Array(16) }).type).toBe("flicker");
    expect(() => Request.parse({ ...profiles, values: new Float32Array(15) })).toThrow();
  });
  test("worker messages are validated too", () => {
    expect(WorkerMessage.safeParse({ type: "stage", token: 1, stage: "analyzing" }).success).toBe(true);
    expect(WorkerMessage.safeParse({ type: "stage", stage: "analyzing" }).success).toBe(false);          // token is required
    expect(WorkerMessage.safeParse({ type: "error", token: 1, message: "x" }).success).toBe(false);      // so is scope
    const heat = (columns: number) => ({ db: new Float32Array(columns * 4), columns: 2, rows: 4, seconds: 1, fLo: 30, fHi: 8_000 });
    expect(WorkerMessage.safeParse({ type: "demo", token: 0, input: heat(2), output: heat(2) }).success).toBe(true);
    expect(WorkerMessage.safeParse({ type: "demo", token: 0, input: heat(3), output: heat(2) }).success).toBe(false); // size mismatch
    const spectrum = { db: new Float32Array(96), frames: 1, hop: 0.05 };
    const trace = { tones: 0, doppler: 0, hum: 0, flybys: 0, found: [] };
    expect(WorkerMessage.safeParse({ type: "analysis", token: 1, trace, spectrum, engine: "wasm" }).success).toBe(false); // detail required
    expect(WorkerMessage.safeParse({ type: "analysis", token: 1, trace, spectrum, detail: heat(2), engine: "wasm" }).success).toBe(true);
    const box = { start: 1, end: 3, lo: 1_190, hi: 1_210, kind: "steady" };
    const withFound = (found: unknown[]) => WorkerMessage.safeParse({ type: "analysis", token: 1, trace: { ...trace, found }, spectrum, detail: heat(2), engine: "wasm" }).success;
    expect(withFound([box])).toBe(true);
    expect(withFound([{ ...box, end: 0.5 }])).toBe(false);                 // ends before it starts
    expect(withFound([{ ...box, kind: "ufo" }])).toBe(false);
    expect(withFound([{ ...box, lo: -5 }])).toBe(false);
    expect(WorkerMessage.safeParse({ type: "analysis", token: 1, trace: { tones: 0, doppler: 0, hum: 0, flybys: 0 }, spectrum, detail: heat(2), engine: "wasm" }).success).toBe(false); // found is required
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
  test("only boxes outside the media data are touched", () => {
    const enc = new TextEncoder();
    const box = (type: string, body: Uint8Array) => {
      const out = new Uint8Array(8 + body.length);
      new DataView(out.buffer).setUint32(0, out.length);
      out.set(enc.encode(type), 4);
      out.set(body, 8);
      return out;
    };
    const media = enc.encode("....MediabunnySoundHandler....");                     // bytes that happen to match
    const file = new Uint8Array([...box("ftyp", enc.encode("isom")), ...box("moov", enc.encode("xxMediabunnySoundHandler\0")),
      ...box("mdat", media)]);
    const text = new TextDecoder().decode(neutralize(file.slice()));
    expect(text).toContain("xxSoundHandler");
    expect(text).toContain("....MediabunnySoundHandler....");                        // compressed data never edited
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

describe("embedded video data (SEI)", () => {
  // H.264 NAL units: SPS (7), PPS (8), SEI (6, with a GPS-looking payload), IDR slice (5).
  const sps = Uint8Array.of(0x67, 0x42, 0x00, 0x1e), pps = Uint8Array.of(0x68, 0xce, 0x38, 0x80);
  const sei = Uint8Array.of(0x06, 0x05, 0x10, ...new TextEncoder().encode("GPS_37.77_-122.41"), 0x80);
  const idr = Uint8Array.of(0x65, 0x88, 0x84, 0x00, 0x33);
  const prefixed = (units: Uint8Array[], size = 4) => {
    const out: number[] = [];
    for (const u of units) {
      for (let k = size - 1; k >= 0; k--) out.push((u.length >>> (8 * k)) & 0xff);
      out.push(...u);
    }
    return Uint8Array.from(out);
  };
  const annexB = (units: Uint8Array[]) => Uint8Array.from(units.flatMap((u) => [0, 0, 0, 1, ...u]));
  const text = (b: Uint8Array) => new TextDecoder("latin1").decode(b);

  test("removed from length-prefixed H.264 packets, everything else kept byte for byte", () => {
    for (const size of [1, 2, 4]) {
      const out = stripSei("avc", prefixed([sps, pps, sei, idr], size), size);
      expect(text(out)).not.toContain("GPS");
      expect(Array.from(out)).toEqual(Array.from(prefixed([sps, pps, idr], size)));
    }
  });
  test("removed from Annex B packets (MPEG-TS)", () => {
    const out = stripSei("avc", annexB([sei, idr]), null);
    expect(Array.from(out)).toEqual(Array.from(annexB([idr])));
    expect(hasSei("avc", annexB([sps, idr]), null)).toBe(false);
  });
  test("a packet without SEI is returned as is", () => {
    const packet = prefixed([idr]);
    expect(stripSei("avc", packet, 4)).toBe(packet);
  });
  test("HEVC prefix and suffix SEI go, slices stay", () => {
    const nal = (type: number, ...body: number[]) => Uint8Array.of(type << 1, 0x01, ...body);
    const out = stripSei("hevc", prefixed([nal(39, 1, 2), nal(19, 9, 9), nal(40, 3)]), 4);
    expect(Array.from(out)).toEqual(Array.from(prefixed([nal(19, 9, 9)])));
  });
  test("a packet that doesn't parse is refused rather than copied blind", () => {
    expect(() => stripSei("avc", Uint8Array.of(0, 0, 0, 50, 1, 2), 4)).toThrow();
  });
  test("SEI arrays are removed from an HEVC configuration", () => {
    const header = new Uint8Array(23);
    header[21] = 0x03;                                    // 4-byte lengths
    const array = (type: number, ...nalus: number[][]) =>
      [0x80 | type, 0, nalus.length, ...nalus.flatMap((n) => [n.length >> 8, n.length & 0xff, ...n])];
    const config = Uint8Array.from([...header.subarray(0, 22), 3, ...array(32, [64, 1]), ...array(39, [78, 1, 5, 9]), ...array(33, [66, 1])]);
    const out = stripSeiFromConfig("hevc", config);
    expect(out[22]).toBe(2);
    expect(Array.from(out.subarray(23))).toEqual([...array(32, [64, 1]), ...array(33, [66, 1])]);
    expect(lengthSize("hevc", out)).toBe(4);
    expect(stripSeiFromConfig("avc", config)).toBe(config);
  });
});

describe("message validation under garbage", () => {
  // A seeded generator of hostile values: wrong types, NaN, huge numbers, nested junk, typed arrays.
  const rand = seededRandom(1234);
  const pick = <T,>(xs: readonly T[]): T => xs[Math.floor(rand() * xs.length)]!;
  const junk = (depth = 0): unknown => {
    const kinds = ["num", "nan", "inf", "str", "bool", "null", "undef", "arr", "obj", "f32", "big"] as const;
    switch (pick(depth > 2 ? kinds.slice(0, 7) : kinds)) {
      case "num": return Math.floor(rand() * 2e6) - 1e6;
      case "nan": return NaN;
      case "inf": return -Infinity;
      case "str": return pick(["", "wasm", "analysis", "x".repeat(1000), "__proto__"]);
      case "bool": return rand() < 0.5;
      case "null": return null;
      case "undef": return undefined;
      case "arr": return Array.from({ length: Math.floor(rand() * 4) }, () => junk(depth + 1));
      case "obj": return Object.fromEntries(Array.from({ length: Math.floor(rand() * 4) }, () => [pick(["type", "token", "db", "columns", "rows", "channels", "x"]), junk(depth + 1)]));
      case "f32": return new Float32Array(Math.floor(rand() * 8));
      case "big": return 2 ** 60;
    }
  };
  const types = ["engine", "stage", "demo", "analysis", "result", "flicker", "error", "analyze", "scrub", "x"];

  test("5,000 hostile messages are rejected cleanly (no throw), each way", () => {
    for (let i = 0; i < 5_000; i++) {
      const message = { ...(junk() as object), type: pick(types), token: rand() < 0.5 ? 1 : junk() };
      expect(() => WorkerMessage.safeParse(message)).not.toThrow();
      expect(() => Request.safeParse(message)).not.toThrow();
      expect(() => WorkerMessage.safeParse(junk())).not.toThrow();
    }
  });

  test("one wrong field spoils an otherwise valid heatmap message", () => {
    const heat = () => ({ db: new Float32Array(8), columns: 2, rows: 4, seconds: 1, fLo: 30, fHi: 8_000 });
    const valid = { type: "demo", token: 0, input: heat(), output: heat() };
    expect(WorkerMessage.safeParse(valid).success).toBe(true);
    const breakers: [string, unknown][] = [["columns", 0], ["columns", 2.5], ["rows", 1], ["fLo", -1], ["fHi", 10], ["seconds", -1], ["db", [0, 0]], ["db", new Float64Array(8)]];
    for (const [field, value] of breakers) {
      expect(WorkerMessage.safeParse({ ...valid, input: { ...heat(), [field]: value } }).success).toBe(false);
    }
  });
});

describe("spectrogram invariants", () => {
  const noisy = (sr: number, seconds: number) => {
    const random = seededRandom(9), rand = () => random() - 0.5;
    const x = new Float32Array(Math.round(sr * seconds));
    for (let i = 0; i < x.length; i++) x[i] = 0.3 * Math.sin((2 * Math.PI * 220 * i) / sr) + 0.05 * rand();
    return x;
  };

  // (Above the 1e-12 power floor, i.e. cells louder than -60 dB, which stay well above it at -100 dB when quieter.)
  test("scaling the sound shifts every cell by the same dB (the colors are relative)", () => {
    const x = noisy(16_000, 3), quiet = x.map((v) => v * 0.01);
    for (const view of [detail(x, 16_000).db, spectrogram(x, 16_000).db]) expect(view.length).toBeGreaterThan(0);
    const a = detail(x, 16_000), b = detail(quiet, 16_000);
    let worst = 0;
    for (let i = 0; i < a.db.length; i++) if (a.db[i]! > -60) worst = Math.max(worst, Math.abs(a.db[i]! - b.db[i]! - 40));
    expect(worst).toBeLessThan(0.05);
  });

  test("deterministic, and the same at any rate for the same sound", () => {
    const a = detail(noisy(16_000, 2), 16_000), b = detail(noisy(16_000, 2), 16_000);
    expect(Array.from(a.db)).toEqual(Array.from(b.db));
    // 220 Hz peaks in the same row at 16, 44.1 and 48 kHz.
    const peakRow = (sr: number) => {
      const d = detail(noisy(sr, 2), sr), c = Math.floor(d.columns / 2);
      const col = Array.from(d.db.subarray(c * d.rows, (c + 1) * d.rows));
      return col.indexOf(Math.max(...col));
    };
    const r16 = peakRow(16_000);
    for (const sr of [44_100, 48_000]) expect(Math.abs(peakRow(sr) - r16)).toBeLessThanOrEqual(1);
  });
});
