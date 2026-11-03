/**
 * Browser end-to-end test of the built site with the real WebAssembly scrubber.
 *
 * CI builds the site exactly as deployed (Content-Security-Policy on), serves it, and points
 * E2E_URL at it. Locally:
 *   scripts/build-wasm.sh && (cd web && bunx vite build && bunx vite preview --port 4173 &)
 *   E2E_URL=http://localhost:4173/octave-camo/ bun test e2e/
 * Needs ffmpeg and Playwright's Chromium. E2E_CHROME=1 adds the H.264/AAC MOV case, which needs
 * Google Chrome (Playwright's Chromium has no H.264 or AAC decoders): `bunx playwright install chrome`.
 * Media edge cases (containers, codecs, rates, broken files) are in media.test.ts.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { type Browser, chromium } from "playwright";
import { expectClean, FAKE_GPS, ffmpeg, flybyWav, pictureHash, probe, row, Session, URL_, videoHash, workDir } from "./helpers.ts";

const dir = workDir();

/** Luma of the spectrogram canvas, downsampled to 64 × 32 (once its colors have settled). */
async function heatmapPixels(page: import("playwright").Page): Promise<number[]> {
  await page.waitForTimeout(100);
  return page.evaluate(() => {
    const source = document.querySelector<HTMLCanvasElement>("#spec")!, w = 64, h = 32;
    const small = document.createElement("canvas");
    small.width = w; small.height = h;
    const ctx = small.getContext("2d")!;
    ctx.drawImage(source, 0, 0, w, h);
    const px = ctx.getImageData(0, 0, w, h).data, out: number[] = [];
    for (let i = 0; i < px.length; i += 4) out.push(0.2126 * px[i]! + 0.7152 * px[i + 1]! + 0.0722 * px[i + 2]!);
    return out;
  });
}

/** VP9/Opus WebM with a fake GPS tag; optionally with 100 Hz rolling-shutter bands. */
function webm(name: string, opts: { flicker?: boolean; seconds?: number } = {}): string {
  const out = join(dir, `${name}.webm`), seconds = String(opts.seconds ?? 20);
  const bands = "geq=lum='clip(lum(X,Y)*(1+0.03*cos(2*PI*100*(T+Y/H*0.6/30))),0,255)':cb='cb(X,Y)':cr='cr(X,Y)'";
  ffmpeg("-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-i", join(dir, "audio.wav"), "-t", seconds,
    "-map", "0:v", "-map", "1:a", "-vf", opts.flicker ? `format=yuv420p,${bands}` : "format=yuv420p",
    "-c:v", "libvpx-vp9", "-b:v", "800k", "-deadline", "realtime", "-cpu-used", "8",
    "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv",
    "-c:a", "libopus", "-b:a", "96k", "-metadata", `location=${FAKE_GPS}`, "-metadata", "creation_time=2026-01-01T12:00:00Z", out);
  return out;
}

describe.skipIf(!URL_)("cloak in the browser", () => {
  let browser: Browser;
  let session: Session;
  const fresh = () => (session = new Session(browser, dir));

  beforeAll(async () => {
    flybyWav(join(dir, "audio.wav"));
    browser = await chromium.launch();
  }, 300_000);

  afterAll(async () => {
    await browser?.close();
    rmSync(dir, { recursive: true, force: true });
  });

  test("clean clip: flyby and hum gone, metadata gone, picture copied bit for bit", async () => {
    const input = webm("clean");
    const page = await fresh().open(input);
    expect(Number((await row(page, "doppler curves")).split(" ")[0])).toBeGreaterThan(0);
    expect(Number((await row(page, "mains hum")).split(" ")[0])).toBeGreaterThan(0);
    await session.pictureChecked();
    expect(await row(page, "light flicker")).toStartWith("none");

    const out = await session.cloakAndSave();
    expect(await row(page, "doppler curves")).toMatch(/→ 0$/);
    expect(await row(page, "mains hum")).toMatch(/→ 0$/);
    expectClean(out, { video: true });
    expect(videoHash(out)).toBe(videoHash(input));
    expect(session.problems).toEqual([]);
    await session.close();
  }, 900_000);

  test("banded clip: light flicker found, removed, and gone when the saved file is decoded again", async () => {
    const input = webm("banded", { flicker: true });
    const page = await fresh().open(input);
    await page.waitForSelector("#picture:not(.hidden)", { timeout: 180_000 });
    expect(await row(page, "light flicker")).toMatch(/^100 Hz/);
    expect(await page.isChecked("#fix-picture")).toBe(true);                     // on when flicker is found
    await page.click("#fix-picture");                                             // unticked: the page says it's kept
    expect(await session.status()).toContain("flicker found and kept");
    await page.click("#fix-picture");
    expect(await page.isChecked("#fix-picture")).toBe(true);

    const out = await session.cloakAndSave();
    await page.waitForFunction(() => /→ (gone|left)/.test(document.querySelector("#trace")?.textContent ?? ""), null, { timeout: 180_000 });
    expect(await row(page, "light flicker")).toMatch(/→ gone$/);
    expectClean(out, { video: true });
    expect(videoHash(out)).not.toBe(videoHash(input));            // re-encoded, as the toggle says
    expect(session.problems).toEqual([]);
    await session.close();
  }, 900_000);

  test("audio-only file: cloaked to a single mono AAC track", async () => {
    const page = await fresh().open(join(dir, "audio.wav"));
    expect(await row(page, "light flicker")).toStartWith("no picture");
    const out = await session.cloakAndSave();
    expect(out).toEndWith(".m4a");
    expectClean(out, { video: false });

    // The spectrogram shows the cloaked sound after cloaking, follows "listen to", and differs
    // from the original (the plane's harmonics and the hum are gone).
    const pressed = (id: string) => page.getAttribute(id, "aria-pressed");
    expect(await pressed("#spec-out")).toBe("true");
    const after = await heatmapPixels(page);
    await page.click("#spec-in");
    expect(await pressed("#side-in")).toBe("true");
    const before = await heatmapPixels(page);
    expect(after.length).toBe(before.length);
    let diff = 0;
    for (let i = 0; i < before.length; i++) diff += Math.abs(before[i]! - after[i]!);
    expect(diff / before.length).toBeGreaterThan(2);
    expect(await page.getAttribute("#spec", "aria-label")).toContain("original");
    expect(session.problems).toEqual([]);
    await session.close();
  }, 900_000);

  test("a clip too short to scan says so instead of reading as clean", async () => {
    const page = await fresh().open(webm("short", { seconds: 3 }));
    expect(await row(page, "light flicker")).toStartWith("too short");
    expect(await session.status()).toContain("too short");
    expect(session.problems).toEqual([]);
    await session.close();
  }, 300_000);

  test("the page shows its version, commit and the hash of the wasm it runs, and checksums.txt matches what's served", async () => {
    const page = await fresh().start();
    await page.waitForSelector("#engine-hash", { timeout: 60_000 });
    const shown = (await page.textContent("#engine-hash"))!.trim();
    expect(shown).toMatch(/^[0-9a-f]{64}$/);
    expect(await page.textContent("#engine")).toMatch(/^v\d+\.\d+\.\d+ · [0-9a-f]{7} · /);
    const sha256 = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");
    const get = async (path: string) => Buffer.from(await (await page.request.get(new URL(path, URL_).href)).body());
    const listed = Object.fromEntries((await get("checksums.txt")).toString().trim().split("\n").map((line) => {
      const [hash, file] = line.split(/\s+/);
      return [file!, hash!];
    }));
    expect(listed["octave-camo.wasm"]).toBe(shown);                       // the hash the page computed at runtime
    expect(listed["index.html"]).toBeDefined();
    for (const [file, hash] of Object.entries(listed)) expect(sha256(await get(file))).toBe(hash);
    expect(session.problems).toEqual([]);
    await session.close();
  }, 300_000);

  describe.skipIf(!process.env.E2E_CHROME)("Google Chrome: an H.264/AAC MOV like a phone's", () => {
    let chrome: Browser;
    beforeAll(async () => { chrome = await chromium.launch({ channel: "chrome" }); }, 120_000);
    afterAll(async () => { await chrome?.close(); });

    const open = async (file: string) => { const s = new Session(chrome, dir); await s.open(file); return s; };

    test("rotation kept, extra audio track dropped, metadata gone, picture copied", async () => {
      // A rotated portrait-style clip with a second (spatial-audio-like) track and a GPS tag.
      // libx264's defaults use B-frames, so packets arrive out of presentation order.
      const plain = join(dir, "plain.mov"), input = join(dir, "phone.mov");
      ffmpeg("-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-i", join(dir, "audio.wav"),
        "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000", "-t", "20", "-map", "0:v", "-map", "1:a", "-map", "2:a",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", plain);
      ffmpeg("-display_rotation", "90", "-i", plain, "-map", "0", "-c", "copy", "-metadata", `location=${FAKE_GPS}`, input);

      const s = await open(input);
      const out = await s.cloakAndSave();
      const info = expectClean(out, { video: true });
      const rotation = info.streams.find((st) => st.codec_type === "video")?.side_data_list?.find((d) => d.rotation !== undefined)?.rotation;
      expect(Math.abs(rotation ?? 0)).toBe(90);
      // The picture is copied packet for packet, minus SEI (x264 writes its version and settings
      // there), so it decodes to exactly the same frames.
      expect(readFileSync(input).includes("x264 - core")).toBe(true);
      expect(readFileSync(out).includes("x264")).toBe(false);
      expect(pictureHash(out)).toBe(pictureHash(input));
      expect(s.problems).toEqual([]);
      await s.close();
    }, 900_000);

    test("GPS written into the stream itself (SEI user data, as camcorders do) is removed", async () => {
      const input = join(dir, "PXL_20260101_120000_sei.mov");
      ffmpeg("-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-i", join(dir, "audio.wav"), "-t", "8", "-map", "0:v", "-map", "1:a",
        "-c:v", "libx264", "-bf", "2", "-pix_fmt", "yuv420p", "-c:a", "aac",
        "-bsf:v", "h264_metadata=sei_user_data=086f3693-b7b3-4f2c-9653-21492feee5b8+GPS_37.7749_-122.4194", input);
      expect(readFileSync(input).includes("GPS_37.7749")).toBe(true);
      const s = await open(input);
      const out = await s.cloakAndSave();
      expectClean(out, { video: true });
      expect(readFileSync(out).includes("GPS_37.7749")).toBe(false);
      expect(pictureHash(out)).toBe(pictureHash(input));
      expect(s.problems).toEqual([]);
      await s.close();
    }, 900_000);

    test("an MPEG-TS starting an hour in comes out starting at zero", async () => {
      const input = join(dir, "PXL_20260101_120000_offset.ts");
      ffmpeg("-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-i", join(dir, "audio.wav"), "-t", "8", "-map", "0:v", "-map", "1:a",
        "-c:v", "libx264", "-bf", "3", "-pix_fmt", "yuv420p", "-c:a", "aac", "-output_ts_offset", "3600", "-f", "mpegts", input);
      expect(Number(probe(input).streams[0]!.start_time)).toBeGreaterThan(3_000);
      const s = await open(input);
      const out = await s.cloakAndSave();
      expectClean(out, { video: true });                 // includes: every stream starts near zero
      expect(s.problems).toEqual([]);
      await s.close();
    }, 900_000);

    test("a stream cut mid-GOP starts at its first keyframe", async () => {
      const whole = join(dir, "gop.ts"), input = join(dir, "PXL_20260101_120000_cut.ts");
      ffmpeg("-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-i", join(dir, "audio.wav"), "-t", "12", "-map", "0:v", "-map", "1:a",
        "-c:v", "libx264", "-g", "60", "-pix_fmt", "yuv420p", "-c:a", "aac", "-f", "mpegts", whole);
      const bytes = readFileSync(whole), cut = Math.floor(bytes.length / 2 / 188) * 188 + 188 * 7;
      writeFileSync(input, bytes.subarray(cut));
      const s = await open(input);
      const out = await s.cloakAndSave();
      expectClean(out, { video: true });
      expect(s.problems).toEqual([]);
      await s.close();
    }, 900_000);
  });
});
