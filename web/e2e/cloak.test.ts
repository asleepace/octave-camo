/**
 * Browser end-to-end test of the built site with the real WebAssembly scrubber.
 *
 * CI builds the site exactly as deployed (Content-Security-Policy on), serves it, and points
 * E2E_URL at it. Locally:
 *   scripts/build-wasm.sh && (cd web && bunx vite build && bunx vite preview --port 4173 &)
 *   E2E_URL=http://localhost:4173/octave-camo/ bun test e2e/
 * Needs ffmpeg and Playwright's Chromium. E2E_CHROME=1 adds the H.264/AAC MOV case, which needs
 * Google Chrome (Playwright's Chromium has no H.264 or AAC decoders): `bunx playwright install chrome`.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type Browser, chromium, type Page } from "playwright";

const URL_ = process.env.E2E_URL;
const dir = mkdtempSync(join(tmpdir(), "octave-camo-e2e-"));
const FAKE_GPS = "+37.7749-122.4194/";

const ffmpeg = (...args: string[]) => execFileSync("ffmpeg", ["-v", "error", "-y", ...args]);
type Stream = { codec_type: string; codec_name: string; channels?: number; tags?: Record<string, string>;
  side_data_list?: { rotation?: number }[] };
const probe = (file: string): { streams: Stream[]; format: { tags?: Record<string, string> } } =>
  JSON.parse(execFileSync("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", file], { encoding: "utf8" }));
const videoHash = (file: string) =>
  execFileSync("ffmpeg", ["-v", "error", "-i", file, "-map", "0:v:0", "-c", "copy", "-f", "streamhash", "-hash", "sha256", "-"],
    { encoding: "utf8" }).trim();

/** WAV of a jet-like flyby (Doppler tone + harmonics), 60 Hz hum and noise, 48 kHz mono. */
function flybyWav(path: string, seconds = 20) {
  const sr = 48_000, n = sr * seconds, c = 343, speed = 90, distance = 300, t0 = seconds / 2, f0 = 180;
  const pcm = new Int16Array(n);
  let seed = 7, phase = 0;
  const rand = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32);
  for (let i = 0; i < n; i++) {
    const t = i / sr, dx = speed * (t - t0), r = Math.hypot(dx, distance);
    phase += (2 * Math.PI * f0) / (1 + (speed * dx) / (r * c)) / sr;
    const level = 0.08 * Math.min(1, 300 / r);
    let s = 0;
    for (let h = 1; h <= 3; h++) s += (level / h) * Math.sin(h * phase);
    s += 0.01 * Math.sin(2 * Math.PI * 60 * t) + 0.005 * Math.sin(2 * Math.PI * 120 * t);
    pcm[i] = Math.round(32767 * Math.max(-1, Math.min(1, s + 0.01 * (rand() + rand() + rand() - 1.5))));
  }
  const header = Buffer.alloc(44);
  header.write("RIFF", 0); header.writeUInt32LE(36 + n * 2, 4); header.write("WAVEfmt ", 8);
  header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22);
  header.writeUInt32LE(sr, 24); header.writeUInt32LE(sr * 2, 28); header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34);
  header.write("data", 36); header.writeUInt32LE(n * 2, 40);
  writeFileSync(path, Buffer.concat([header, Buffer.from(pcm.buffer)]));
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

/** "in → out" cell of a Detected levels row, by its label. */
async function row(page: Page, label: string): Promise<string> {
  const rows = await page.$$eval("#trace tr", (trs) => trs.map((tr) => [...tr.querySelectorAll("td")].map((td) => td.textContent?.replace(/\s+/g, " ").trim() ?? "")));
  const match = rows.find((cells) => cells[0]?.startsWith(label));
  if (!match) throw new Error(`no row ${label}`);
  return match[2] ?? "";
}

/** Things every saved file must satisfy. */
function expectClean(out: string, expected: { video: boolean }) {
  const info = probe(out);
  const tags = JSON.stringify([info.format.tags ?? {}, ...info.streams.map((s) => s.tags ?? {})]);
  expect(tags).not.toContain("location");
  expect(tags).not.toContain("creation_time");
  expect(tags).not.toContain(FAKE_GPS.slice(0, 8));
  expect(readFileSync(out).includes(Buffer.from("Mediabunny"))).toBe(false);       // no tool name in the file
  expect(info.streams.map((s) => s.codec_type).sort()).toEqual(expected.video ? ["audio", "video"] : ["audio"]);
  expect(info.streams.find((s) => s.codec_type === "audio")).toMatchObject({ codec_name: "aac", channels: 1 });
  return info;
}

describe.skipIf(!URL_)("cloak in the browser", () => {
  let chromiumBrowser: Browser;
  const problems: string[] = [];

  beforeAll(async () => {
    flybyWav(join(dir, "audio.wav"));
    chromiumBrowser = await chromium.launch();
  }, 300_000);

  afterAll(async () => {
    await chromiumBrowser?.close();
    rmSync(dir, { recursive: true, force: true });
  });

  async function open(file: string, browser = chromiumBrowser): Promise<Page> {
    problems.length = 0;
    const context = await browser.newContext({ acceptDownloads: true });
    const page = await context.newPage();
    page.on("pageerror", (e) => problems.push(`page error: ${e.message}`));
    page.on("console", (m) => {
      if (/Content Security Policy|Refused to/i.test(m.text())) problems.push(`csp: ${m.text()}`);
      else if (m.type() === "error") problems.push(`console error: ${m.text()}`);
    });
    page.on("request", (r) => { if (!r.url().startsWith(URL_!) && !/^(blob|data):/.test(r.url())) problems.push(`external request: ${r.url()}`); });
    await page.goto(URL_!);
    await page.setInputFiles("#file", file);
    try {
      await page.waitForFunction(() => /exposed|no trackable/.test(document.querySelector("#status")?.textContent ?? ""), null, { timeout: 180_000 });
    } catch {
      throw new Error(`page never finished analysis; status "${await page.textContent("#status")}"; ${problems.join(" | ")}`);
    }
    return page;
  }

  async function cloakAndSave(page: Page): Promise<string> {
    await page.click("#cloak");
    await page.waitForFunction(() => /^SAVE/.test(document.querySelector("#cloak")?.textContent ?? ""), null, { timeout: 300_000 });
    const [download] = await Promise.all([page.waitForEvent("download", { timeout: 600_000 }), page.click("#cloak")]);
    expect(download.suggestedFilename()).toMatch(/^camo-[a-z2-9]{6}\.(mp4|m4a)$/);   // nothing from the original name
    const out = join(dir, download.suggestedFilename());
    await download.saveAs(out);
    return out;
  }

  const pictureChecked = (page: Page) =>
    page.waitForFunction(() => !/scanning/.test(document.querySelector("#trace")?.textContent ?? ""), null, { timeout: 180_000 });

  test("clean clip: flyby and hum gone, metadata gone, picture copied bit for bit", async () => {
    const input = webm("clean");
    const page = await open(input);
    expect(Number((await row(page, "doppler curves")).split(" ")[0])).toBeGreaterThan(0);
    expect(Number((await row(page, "mains hum")).split(" ")[0])).toBeGreaterThan(0);
    await pictureChecked(page);
    expect(await row(page, "light flicker")).toStartWith("none");

    const out = await cloakAndSave(page);
    expect(await row(page, "doppler curves")).toMatch(/→ 0$/);
    expect(await row(page, "mains hum")).toMatch(/→ 0$/);
    expectClean(out, { video: true });
    expect(videoHash(out)).toBe(videoHash(input));
    expect(problems).toEqual([]);
  }, 900_000);

  test("banded clip: light flicker found, removed, and gone when the saved file is decoded again", async () => {
    const input = webm("banded", { flicker: true });
    const page = await open(input);
    await page.waitForSelector("#picture:not(.hidden)", { timeout: 180_000 });
    expect(await row(page, "light flicker")).toMatch(/^100 Hz/);
    expect(await page.isChecked("#fix-picture")).toBe(true);

    const out = await cloakAndSave(page);
    await page.waitForFunction(() => /→ (gone|left)/.test(document.querySelector("#trace")?.textContent ?? ""), null, { timeout: 180_000 });
    expect(await row(page, "light flicker")).toMatch(/→ gone$/);
    expectClean(out, { video: true });
    expect(videoHash(out)).not.toBe(videoHash(input));            // re-encoded, as the toggle says
    expect(problems).toEqual([]);
  }, 900_000);

  test("audio-only file: cloaked to a single mono AAC track", async () => {
    const page = await open(join(dir, "audio.wav"));
    expect(await row(page, "light flicker")).toStartWith("no picture");
    const out = await cloakAndSave(page);
    expect(out).toEndWith(".m4a");
    expectClean(out, { video: false });
    expect(problems).toEqual([]);
  }, 900_000);

  test("a clip too short to scan says so instead of reading as clean", async () => {
    const page = await open(webm("short", { seconds: 3 }));
    expect(await row(page, "light flicker")).toStartWith("too short");
    expect(await page.textContent("#status")).toContain("too short");
    expect(problems).toEqual([]);
  }, 300_000);

  describe.skipIf(!process.env.E2E_CHROME)("Google Chrome: an H.264/AAC MOV like a phone's", () => {
    let chrome: Browser;
    beforeAll(async () => { chrome = await chromium.launch({ channel: "chrome" }); }, 120_000);
    afterAll(async () => { await chrome?.close(); });

    test("rotation kept, extra audio track dropped, metadata gone, picture copied", async () => {
      // A rotated portrait-style clip with a second (spatial-audio-like) track and a GPS tag.
      const plain = join(dir, "plain.mov"), input = join(dir, "phone.mov");
      ffmpeg("-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-i", join(dir, "audio.wav"),
        "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000", "-t", "20", "-map", "0:v", "-map", "1:a", "-map", "2:a",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", plain);
      ffmpeg("-display_rotation", "90", "-i", plain, "-map", "0", "-c", "copy", "-metadata", `location=${FAKE_GPS}`, input);

      const page = await open(input, chrome);
      const out = await cloakAndSave(page);
      const info = expectClean(out, { video: true });
      const rotation = info.streams.find((s) => s.codec_type === "video")?.side_data_list?.find((d) => d.rotation !== undefined)?.rotation;
      expect(Math.abs(rotation ?? 0)).toBe(90);
      expect(videoHash(out)).toBe(videoHash(input));
      expect(problems).toEqual([]);
    }, 900_000);
  });
});
