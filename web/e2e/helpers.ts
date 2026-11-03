/** Shared pieces of the browser end-to-end tests: clip generation, probing, driving the page. */
import { expect } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Browser, Page } from "playwright";

export const URL_ = process.env.E2E_URL;
export const FAKE_GPS = "+37.7749-122.4194/";
export const workDir = () => mkdtempSync(join(tmpdir(), "octave-camo-e2e-"));

export const ffmpeg = (...args: string[]) => execFileSync("ffmpeg", ["-v", "error", "-y", ...args]);

export type Stream = {
  index: number; codec_type: string; codec_name: string; channels?: number; sample_rate?: string;
  start_time?: string; duration?: string; tags?: Record<string, string>; side_data_list?: { rotation?: number }[];
};
export type Probe = { streams: Stream[]; format: { tags?: Record<string, string>; duration?: string } };
export const probe = (file: string): Probe =>
  JSON.parse(execFileSync("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", file], { encoding: "utf8" }));

/** SHA-256 of the first video stream's packets (identical means the picture was copied, not re-encoded). */
export const videoHash = (file: string) =>
  execFileSync("ffmpeg", ["-v", "error", "-i", file, "-map", "0:v:0", "-c", "copy", "-f", "streamhash", "-hash", "sha256", "-"],
    { encoding: "utf8" }).trim();

/**
 * SHA-256 of every decoded frame of the first video stream (no auto-rotation). Equal means the
 * picture is the same pixel for pixel, e.g. when only SEI (which decoders don't need) was removed.
 */
export const pictureHash = (file: string) =>
  execFileSync("ffmpeg", ["-v", "error", "-noautorotate", "-i", file, "-map", "0:v:0", "-f", "hash", "-hash", "sha256", "-"],
    { encoding: "utf8" }).trim();

/** Decoded length of the first audio stream, s, by counting samples (container durations can be missing or wrong). */
export function decodedAudioSeconds(file: string): number {
  const pcm = execFileSync("ffmpeg", ["-v", "error", "-i", file, "-map", "0:a:0", "-ac", "1", "-ar", "8000", "-f", "s16le", "-"],
    { maxBuffer: 1 << 28 });
  return pcm.length / 2 / 8000;
}

/** RMS level of the first audio stream in dBFS. */
export function audioLevelDB(file: string): number {
  const { stderr } = spawnSync("ffmpeg", ["-v", "info", "-nostats", "-i", file, "-map", "0:a:0", "-af", "volumedetect", "-f", "null", "-"],
    { encoding: "utf8" });
  const m = /mean_volume: (-?[\d.]+|-inf) dB/.exec(stderr);
  return !m ? Number.NaN : m[1] === "-inf" ? -Infinity : Number(m[1]);
}

/** 16-bit PCM WAV of a jet-like flyby (Doppler tone + harmonics), 60 Hz hum and noise. */
export function flybyWav(path: string, seconds = 20, sr = 48_000) {
  const n = sr * seconds, c = 343, speed = 90, distance = 300, t0 = seconds / 2, f0 = 180;
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

/** "in → out" cell of a Detected levels row, by its label. */
export async function row(page: Page, label: string): Promise<string> {
  const rows = await page.$$eval("#trace tr", (trs) => trs.map((tr) => [...tr.querySelectorAll("td")].map((td) => td.textContent?.replace(/\s+/g, " ").trim() ?? "")));
  const match = rows.find((cells) => cells[0]?.startsWith(label));
  if (!match) throw new Error(`no row ${label}`);
  return match[2] ?? "";
}

/** Things every saved file must satisfy. */
/** `audio: false`: a silent video, saved as the picture alone. */
export function expectClean(out: string, expected: { video: boolean; audio?: boolean }): Probe {
  const audio = expected.audio ?? true;
  const info = probe(out);
  const tags = JSON.stringify([info.format.tags ?? {}, ...info.streams.map((s) => s.tags ?? {})]);
  expect(tags).not.toContain("location");
  expect(tags).not.toContain("creation_time");
  expect(tags).not.toContain(FAKE_GPS.slice(0, 8));
  expect(readFileSync(out).includes(Buffer.from("Mediabunny"))).toBe(false);       // no tool name in the file
  expect(info.streams.map((s) => s.codec_type).sort()).toEqual([...(audio ? ["audio"] : []), ...(expected.video ? ["video"] : [])]);
  if (audio) expect(info.streams.find((s) => s.codec_type === "audio")).toMatchObject({ codec_name: "aac", channels: 1 });
  // Timestamps start at zero (a source's absolute start time would carry its clock over).
  expect(Math.min(...info.streams.map((s) => Number(s.start_time ?? 0)))).toBeLessThan(0.1);
  return info;
}

/** One browser context per opened file; collects page errors, CSP reports and outside requests. */
export class Session {
  readonly problems: string[] = [];
  /** URLs of the workers the page started (each must be a blob: URL, so the page's CSP covers it). */
  readonly workers: string[] = [];
  page!: Page;

  constructor(private readonly browser: Browser, private readonly dir: string) {}

  async start(): Promise<Page> {
    const context = await this.browser.newContext({ acceptDownloads: true });
    const page = (this.page = await context.newPage());
    page.on("pageerror", (e) => this.problems.push(`page error: ${e.message}`));
    page.on("console", (m) => {
      if (/Content Security Policy|Refused to/i.test(m.text())) this.problems.push(`csp: ${m.text()}`);
      else if (m.type() === "error") this.problems.push(`console error: ${m.text()}`);
    });
    page.on("worker", (w) => {
      this.workers.push(w.url());
      if (!w.url().startsWith("blob:")) this.problems.push(`worker outside the page's CSP: ${w.url()}`);
    });
    page.on("request", (r) => {
      if (!r.url().startsWith(URL_!) && !/^(blob|data):/.test(r.url())) this.problems.push(`external request: ${r.url()}`);
    });
    await page.goto(URL_!);
    return page;
  }

  async status(): Promise<string> {
    return (await this.page.textContent("#status")) ?? "";
  }

  /** Opens a file and waits for the analysis to finish. */
  async open(file: string, timeout = 180_000): Promise<Page> {
    if (!this.page) await this.start();
    await this.page.setInputFiles("#file", file);
    try {
      await this.page.waitForFunction(() => /exposed|no trackable|no sound to cloak/.test(document.querySelector("#status")?.textContent ?? ""), null, { timeout });
    } catch {
      throw new Error(`page never finished analysis; status "${await this.status()}"; ${this.problems.join(" | ")}`);
    }
    return this.page;
  }

  /** Opens a file the page must refuse; returns the error it shows. */
  async refuse(file: string): Promise<string> {
    if (!this.page) await this.start();
    await this.page.setInputFiles("#file", file);
    try {
      await this.page.waitForSelector("#status .text-red-400", { timeout: 60_000 });
    } catch {
      throw new Error(`no error shown; status "${await this.status()}"`);
    }
    // The page must be usable again: the drop zone back, the button off.
    expect(await this.page.isDisabled("#cloak")).toBe(true);
    return (await this.page.textContent("#status .text-red-400")) ?? "";
  }

  async cloak(timeout = 300_000): Promise<void> {
    await this.page.click("#cloak");
    await this.page.waitForFunction(() => /^SAVE/.test(document.querySelector("#cloak")?.textContent ?? ""), null, { timeout });
  }

  async save(): Promise<string> {
    // Whichever comes first: the download, or an error on the page (reported as the failure).
    const failed = this.page.waitForSelector("#status .text-red-400", { timeout: 600_000 })
      .then(async (el) => { throw new Error(`saving failed on the page: ${await el?.textContent()}`); });
    failed.catch(() => {});
    const [download] = await Promise.all([Promise.race([this.page.waitForEvent("download", { timeout: 600_000 }), failed]),
      this.page.click("#cloak")]);
    expect(download.suggestedFilename()).toMatch(/^camo-[a-z2-9]{6}\.(mp4|m4a)$/);   // nothing from the original name
    const out = join(this.dir, download.suggestedFilename());
    await download.saveAs(out);
    return out;
  }

  async cloakAndSave(): Promise<string> {
    await this.cloak();
    return this.save();
  }

  pictureChecked() {
    return this.page.waitForFunction(() => !/scanning/.test(document.querySelector("#trace")?.textContent ?? ""), null, { timeout: 180_000 });
  }

  async close() {
    await this.page?.context().close();
  }
}
