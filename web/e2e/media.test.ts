/**
 * Media edge cases, end to end in Playwright's Chromium (which decodes VP8/VP9/AV1, Opus, Vorbis,
 * FLAC, MP3 and PCM, but not H.264/AAC: those are in cloak.test.ts under Google Chrome).
 *
 * For every file the page accepts, the saved copy must: be fully cloaked (one mono AAC track,
 * no metadata, neutral name), keep the audio's length and its position against the picture, and
 * copy the picture bit for bit. Every file it can't handle must be refused with a message that
 * doesn't echo the file's name, leaving the page usable. Nothing may hang.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { type Browser, chromium } from "playwright";
import {
  audioLevelDB, decodedAudioSeconds, expectClean, FAKE_GPS, ffmpeg, flybyWav, probe, Session, URL_, videoHash, workDir,
} from "./helpers.ts";

const dir = workDir();
const SECONDS = 6;
const tags = ["-metadata", `location=${FAKE_GPS}`, "-metadata", "creation_time=2026-01-01T12:00:00Z"];
const vp9 = ["-c:v", "libvpx-vp9", "-b:v", "400k", "-deadline", "realtime", "-cpu-used", "8"];
const testsrc = (size = "320x180", rate = 30) => ["-f", "lavfi", "-i", `testsrc2=size=${size}:rate=${rate}`];
const wav = () => ["-i", join(dir, "audio.wav")];

/** Builds a clip with ffmpeg; `args` sit between the inputs and the output name. */
function make(name: string, ...args: string[]): string {
  const out = join(dir, name);
  ffmpeg(...args, out);
  return out;
}

type Accepted = { file: string; video: boolean; seconds: number };

describe.skipIf(!URL_)("media edge cases", () => {
  let browser: Browser;
  const sessions: Session[] = [];
  const session = () => { const s = new Session(browser, dir); sessions.push(s); return s; };

  beforeAll(async () => {
    flybyWav(join(dir, "audio.wav"), SECONDS);
    browser = await chromium.launch();
  }, 120_000);

  afterAll(async () => {
    for (const s of sessions) await s.close().catch(() => {});
    await browser?.close();
    rmSync(dir, { recursive: true, force: true });
  });

  /** Open, cloak, save, and check everything a saved file must satisfy. */
  async function roundTrip({ file, video, seconds }: Accepted) {
    const s = session();
    await s.open(file);
    if (video) await s.pictureChecked();
    const out = await s.cloakAndSave();
    const info = expectClean(out, { video });
    if (video) expect(videoHash(out)).toBe(videoHash(file));
    expect(s.workers.length).toBeGreaterThan(0);
    expect(Math.abs(decodedAudioSeconds(out) - seconds)).toBeLessThan(0.15);
    expect(s.problems).toEqual([]);
    await s.close();
    return { out, info, session: s };
  }

  const accepted: [string, () => Accepted][] = [
    ["MKV · VP9 + FLAC at 96 kHz, 6 channels", () => ({
      file: make("surround.mkv", ...testsrc(), ...wav(), "-t", `${SECONDS}`, "-map", "0:v", "-map", "1:a", ...vp9,
        "-af", "pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0", "-ar", "96000", "-c:a", "flac", ...tags),
      video: true, seconds: SECONDS,
    })],
    ["WebM · VP8 + Vorbis at 22.05 kHz, odd 177×99 picture", () => ({
      file: make("odd.webm", ...testsrc("177x99"), ...wav(), "-t", `${SECONDS}`, "-map", "0:v", "-map", "1:a",
        "-c:v", "libvpx", "-b:v", "300k", "-deadline", "realtime", "-cpu-used", "8", "-ar", "22050", "-c:a", "libvorbis", ...tags),
      video: true, seconds: SECONDS,
    })],
    ["MP4 · AV1 + Opus", () => ({
      file: make("av1.mp4", ...testsrc(), ...wav(), "-t", `${SECONDS}`, "-map", "0:v", "-map", "1:a",
        "-c:v", "libaom-av1", "-usage", "realtime", "-cpu-used", "8", "-b:v", "300k", "-c:a", "libopus", ...tags),
      video: true, seconds: SECONDS,
    })],
    ["WebM · variable frame rate", () => ({
      file: make("vfr.webm", ...testsrc("320x180", 60), ...wav(), "-t", `${SECONDS}`, "-map", "0:v", "-map", "1:a",
        "-vf", "select='not(mod(n\\,3))+not(mod(n\\,7))',format=yuv420p", "-fps_mode", "vfr", ...vp9, "-c:a", "libopus", ...tags),
      video: true, seconds: SECONDS,
    })],
    ["Ogg · Opus, audio only", () => ({
      file: make("voice.ogg", ...wav(), "-c:a", "libopus", ...tags), video: false, seconds: SECONDS,
    })],
    ["MP3 · 8 kHz mono, audio only", () => ({
      file: make("phone.mp3", ...wav(), "-ar", "8000", "-c:a", "libmp3lame", "-b:a", "32k", ...tags), video: false, seconds: SECONDS,
    })],
    ["FLAC · 192 kHz stereo, audio only (above what AAC can carry)", () => ({
      file: make("hires.flac", ...wav(), "-ac", "2", "-ar", "192000", "-c:a", "flac", ...tags), video: false, seconds: SECONDS,
    })],
    ["WAV · 0.3 s", () => ({
      file: make("blip.wav", ...wav(), "-t", "0.3"), video: false, seconds: 0.3,
    })],
  ];

  for (const [name, build] of accepted) {
    test(name, async () => { await roundTrip(build()); }, 600_000);
  }

  test("WebM · two video tracks: only the first is kept", async () => {
    const file = make("two-pictures.mkv", ...testsrc(), "-f", "lavfi", "-i", "testsrc=size=160x90:rate=25", ...wav(),
      "-t", `${SECONDS}`, "-map", "0:v", "-map", "1:v", "-map", "2:a", ...vp9, "-c:a", "libopus", ...tags);
    await roundTrip({ file, video: true, seconds: SECONDS });
  }, 600_000);

  test("WebM · a silent track stays silent", async () => {
    const file = make("silent.webm", ...testsrc(), "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-t", `${SECONDS}`,
      "-map", "0:v", "-map", "1:a", ...vp9, "-c:a", "libopus", ...tags);
    const { out } = await roundTrip({ file, video: true, seconds: SECONDS });
    expect(audioLevelDB(out)).toBeLessThan(-70);
  }, 600_000);

  test("WebM · audio starting 0.5 s after the picture keeps its place", async () => {
    const file = make("late-audio.webm", ...testsrc(), "-itsoffset", "0.5", ...wav(), "-t", `${SECONDS + 0.5}`,
      "-map", "0:v", "-map", "1:a", ...vp9, "-c:a", "libopus", ...tags);
    const offset = (p: ReturnType<typeof probe>) => {
      const start = (type: string) => Number(p.streams.find((st) => st.codec_type === type)?.start_time ?? Number.NaN);
      return start("audio") - start("video");
    };
    const { info } = await roundTrip({ file, video: true, seconds: SECONDS });
    expect(Math.abs(offset(info) - offset(probe(file)))).toBeLessThan(0.05);
  }, 600_000);

  // ---------- refused ----------

  const refused: [string, () => string, RegExp][] = [
    ["video with no audio track", () => make("PXL_20260101_120000_mute.webm", ...testsrc(), "-t", `${SECONDS}`, ...vp9, ...tags), /no audio/i],
    ["random bytes named .mp4", () => {
      const file = join(dir, "PXL_20260101_120000_junk.mp4");
      writeFileSync(file, Buffer.from(Array.from({ length: 50_000 }, (_, i) => (i * 7919 + 13) & 0xff)));
      return file;
    }, /./],
    ["an empty file", () => { const file = join(dir, "PXL_20260101_120000_empty.mov"); writeFileSync(file, ""); return file; }, /./],
    ["longer than the 5-minute limit", () =>
      make("PXL_20260101_120000_long.ogg", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono", "-t", "305", "-c:a", "libopus", "-b:a", "8k"), /limit/],
  ];

  for (const [name, build, message] of refused) {
    test(`refused: ${name}`, async () => {
      const s = session();
      const error = await s.refuse(build());
      expect(error).toMatch(message);
      expect(error).not.toContain("PXL");               // never echo the file's name
      expect(s.problems.filter((p) => !p.startsWith("console error"))).toEqual([]);
      await s.close();
    }, 300_000);
  }

  test("a truncated file either cloaks what's there or is refused, without hanging", async () => {
    const whole = make("whole.webm", ...testsrc(), ...wav(), "-t", `${SECONDS}`, "-map", "0:v", "-map", "1:a", ...vp9, "-c:a", "libopus");
    const bytes = await Bun.file(whole).arrayBuffer();
    const file = join(dir, "PXL_20260101_120000_cut.webm");
    writeFileSync(file, Buffer.from(bytes.slice(0, Math.floor(bytes.byteLength * 0.4))));
    const s = session();
    await s.start();
    await s.page.setInputFiles("#file", file);
    await s.page.waitForFunction(() => {
      const text = document.querySelector("#status")?.textContent ?? "";
      return /exposed|no trackable/.test(text) || !!document.querySelector("#status .text-red-400");
    }, null, { timeout: 120_000 });
    if (await s.page.$("#status .text-red-400")) {
      expect(await s.status()).not.toContain("PXL");
    } else {
      const out = await s.cloakAndSave();
      expectClean(out, { video: true });
    }
    expect(s.problems.filter((p) => p.startsWith("page error"))).toEqual([]);
    await s.close();
  }, 600_000);

  // ---------- interaction ----------

  test("opening a second file while the first is still loading shows only the second", async () => {
    const first = make("first.webm", ...testsrc("640x360"), ...wav(), "-map", "0:v", "-map", "1:a", "-t", `${SECONDS}`, ...vp9, "-c:a", "libopus");
    const second = make("second.ogg", ...wav(), "-t", "2", "-c:a", "libopus");
    const s = session();
    await s.start();
    await s.page.setInputFiles("#file", first);
    await s.page.setInputFiles("#file", second);
    await s.page.waitForFunction(() => /exposed|no trackable/.test(document.querySelector("#status")?.textContent ?? ""), null, { timeout: 120_000 });
    await Bun.sleep(3_000);                              // give the first file's late replies time to land
    expect(await s.page.textContent("#file-name")).toStartWith("second.ogg");
    expect(await s.page.textContent("#file-name")).toContain("audio only");
    const out = await s.cloakAndSave();
    expectClean(out, { video: false });
    expect(Math.abs(decodedAudioSeconds(out) - 2)).toBeLessThan(0.15);
    expect(s.problems).toEqual([]);
    await s.close();
  }, 600_000);

  test("pressing CLOAK twice runs one cloak", async () => {
    const s = session();
    await s.open(join(dir, "audio.wav"));
    await s.page.evaluate(() => { const b = document.querySelector<HTMLButtonElement>("#cloak")!; b.click(); b.click(); });
    await s.page.waitForFunction(() => /^SAVE/.test(document.querySelector("#cloak")?.textContent ?? ""), null, { timeout: 300_000 });
    const runs = await s.page.$$eval("#log li", (lis) => lis.filter((li) => li.textContent?.startsWith("mono")).length);
    expect(runs).toBe(1);
    expect(s.problems).toEqual([]);
    await s.close();
  }, 600_000);
});
