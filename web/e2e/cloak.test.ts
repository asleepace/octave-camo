/**
 * Browser end-to-end test of the built site with the real WebAssembly scrubber.
 *
 * CI builds the site exactly as deployed (Content-Security-Policy on), serves it, and points
 * E2E_URL at it. Locally:
 *   scripts/build-wasm.sh && (cd web && bunx vite build && bunx vite preview --port 4173 &)
 *   E2E_URL=http://localhost:4173/octave-camo/ bun test e2e/
 * Needs ffmpeg and Playwright's Chromium.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type Browser, chromium, type Page } from "playwright";

const URL_ = process.env.E2E_URL;
const dir = mkdtempSync(join(tmpdir(), "octave-camo-e2e-"));
const FAKE_GPS = "+37.7749-122.4194/";

const ffmpeg = (...args: string[]) => execFileSync("ffmpeg", ["-v", "error", "-y", ...args]);
const probe = (file: string, ...args: string[]) =>
  execFileSync("ffprobe", ["-v", "error", ...args, "-of", "json", file], { encoding: "utf8" });
const videoHash = (file: string) =>
  execFileSync("ffmpeg", ["-v", "error", "-i", file, "-map", "0:v:0", "-c", "copy", "-f", "streamhash", "-hash", "sha256", "-"],
    { encoding: "utf8" }).trim();

/** 20 s mono WAV at 48 kHz: a jet-like flyby (Doppler tone + harmonics), 60 Hz hum, noise. */
function flybyWav(path: string) {
  const sr = 48_000, n = sr * 20, c = 343, speed = 90, distance = 300, t0 = 10, f0 = 180;
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

/** VP9/Opus WebM (Playwright's Chromium has no H.264/AAC decoders) with a fake GPS tag. */
function clip(name: string, flicker: boolean): string {
  const out = join(dir, `${name}.webm`);
  // Rolling-shutter banding: 100 Hz flicker, readout 60 % of the frame period, 3 % deep.
  const bands = "geq=lum='clip(lum(X,Y)*(1+0.03*cos(2*PI*100*(T+Y/H*0.6/30))),0,255)':cb='cb(X,Y)':cr='cr(X,Y)'";
  ffmpeg("-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-i", join(dir, "audio.wav"), "-t", "20",
    "-map", "0:v", "-map", "1:a", "-vf", flicker ? `format=yuv420p,${bands}` : "format=yuv420p",
    "-c:v", "libvpx-vp9", "-b:v", "800k", "-deadline", "realtime", "-cpu-used", "8",
    "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv",
    "-c:a", "libopus", "-b:a", "96k", "-metadata", `location=${FAKE_GPS}`, "-metadata", "creation_time=2026-01-01T12:00:00Z", out);
  return out;
}

/** "in → out" cells of a Detected levels row, by its label. */
async function row(page: Page, label: string): Promise<string> {
  const rows = await page.$$eval("#trace tr", (trs) => trs.map((tr) => [...tr.querySelectorAll("td")].map((td) => td.textContent?.replace(/\s+/g, " ").trim() ?? "")));
  const match = rows.find((cells) => cells[0]?.startsWith(label));
  if (!match) throw new Error(`no row ${label}`);
  return match[2] ?? "";
}

describe.skipIf(!URL_)("cloak in the browser", () => {
  let browser: Browser;
  let clean: string, banded: string;
  const problems: string[] = [];

  beforeAll(async () => {
    flybyWav(join(dir, "audio.wav"));
    clean = clip("clean", false);
    banded = clip("banded", true);
    browser = await chromium.launch();
  }, 300_000);

  afterAll(async () => {
    await browser?.close();
    rmSync(dir, { recursive: true, force: true });
  });

  async function open(file: string): Promise<Page> {
    const context = await browser.newContext({ acceptDownloads: true });
    const page = await context.newPage();
    page.on("pageerror", (e) => problems.push(`page error: ${e.message}`));
    page.on("console", (m) => { if (/Content Security Policy|Refused to/i.test(m.text())) problems.push(`csp: ${m.text()}`); });
    page.on("request", (r) => { if (!r.url().startsWith(URL_!) && !/^(blob|data):/.test(r.url())) problems.push(`external request: ${r.url()}`); });
    page.on("console", (m) => { if (m.type() === "error") problems.push(`console error: ${m.text()}`); });
    await page.goto(URL_!);
    await page.setInputFiles("#file", file);
    try {
      await page.waitForFunction(() => /exposed|no trackable/.test(document.querySelector("#status")?.textContent ?? ""), null, { timeout: 180_000 });
    } catch (error) {
      throw new Error(`page never finished analysis; status "${await page.textContent("#status")}"; ${problems.join(" | ")}`);
    }
    return page;
  }

  async function cloakAndSave(page: Page, name: string): Promise<string> {
    await page.click("#cloak");
    await page.waitForFunction(() => /^SAVE/.test(document.querySelector("#cloak")?.textContent ?? ""), null, { timeout: 300_000 });
    const [download] = await Promise.all([page.waitForEvent("download", { timeout: 600_000 }), page.click("#cloak")]);
    const out = join(dir, name);
    await download.saveAs(out);
    return out;
  }

  test("clean clip: flyby and hum gone, metadata gone, picture copied bit for bit", async () => {
    const page = await open(clean);
    expect(Number((await row(page, "doppler curves")).split(" ")[0])).toBeGreaterThan(0);
    expect(Number((await row(page, "mains hum")).split(" ")[0])).toBeGreaterThan(0);
    await page.waitForFunction(() => !/scanning/.test(document.querySelector("#trace")?.textContent ?? ""), null, { timeout: 180_000 });
    expect(await row(page, "light flicker")).toStartWith("none");

    const out = await cloakAndSave(page, "clean.camo.mp4");
    expect(await row(page, "doppler curves")).toMatch(/→ 0$/);
    expect(await row(page, "mains hum")).toMatch(/→ 0$/);

    const info = JSON.parse(probe(out, "-show_entries", "stream=codec_type,codec_name,channels:stream_tags:format_tags"));
    const tags = JSON.stringify([info.format?.tags ?? {}, ...info.streams.map((s: { tags?: object }) => s.tags ?? {})]);
    expect(tags).not.toContain("location");
    expect(tags).not.toContain("creation_time");
    expect(tags).not.toContain(FAKE_GPS.slice(0, 8));
    const audio = info.streams.find((s: { codec_type: string }) => s.codec_type === "audio");
    expect(audio).toMatchObject({ codec_name: "aac", channels: 1 });
    expect(videoHash(out)).toBe(videoHash(clean));
    expect(problems).toEqual([]);
  }, 900_000);

  test("banded clip: light flicker found, removed on save, and gone from the saved picture", async () => {
    const page = await open(banded);
    await page.waitForSelector("#picture:not(.hidden)", { timeout: 180_000 });
    expect(await row(page, "light flicker")).toMatch(/^100 Hz/);
    expect(await page.isChecked("#fix-picture")).toBe(true);

    const out = await cloakAndSave(page, "banded.camo.mp4");
    await page.waitForFunction(() => /→ (gone|left)/.test(document.querySelector("#trace")?.textContent ?? ""), null, { timeout: 120_000 });
    expect(await row(page, "light flicker")).toMatch(/→ gone$/);
    expect(videoHash(out)).not.toBe(videoHash(banded));            // re-encoded, as the toggle says
    const info = JSON.parse(probe(out, "-show_entries", "format_tags:stream_tags"));
    expect(JSON.stringify(info)).not.toContain("location");
    expect(problems).toEqual([]);
  }, 900_000);
});
