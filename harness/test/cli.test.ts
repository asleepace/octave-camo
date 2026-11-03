/** The scrub CLI end to end, on real files: WAV in/out, video in/out, and failure modes. */
import { describe, expect, test } from "bun:test";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { run } from "../src/clip.ts";
import { readMono, writeMonoWav } from "../src/dsp.ts";

const cli = join(import.meta.dir, "..", "src", "scrub-cli.ts");
const dir = await mkdtemp(join(tmpdir(), "octave-camo-cli-"));
const sr = 48_000;

async function scrub(args: string[]): Promise<{ code: number; stdout: string; stderr: string }> {
  const proc = Bun.spawn(["bun", cli, ...args], { stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  return { code, stdout, stderr };
}

const input = join(dir, "in.wav");
await writeMonoWav(input, Float32Array.from({ length: sr * 3 }, (_, i) => 0.1 * Math.sin((2 * Math.PI * 440 * i) / sr)), sr);

describe("scrub CLI", () => {
  test("WAV in, WAV out, same length, logs each stage", async () => {
    const out = join(dir, "out.wav");
    const r = await scrub([input, out, "--chain", "hum+lowband", "--seed", "1"]);
    expect(r.code).toBe(0);
    expect(r.stderr).toContain("hum:");
    expect(r.stderr).toContain("lowband:");
    expect((await readMono(out, sr)).length).toBe(sr * 3);
  });

  test("the same seed gives the same output", async () => {
    const a = join(dir, "a.wav"), b = join(dir, "b.wav");
    await scrub([input, a, "--chain", "lowband", "--seed", "9"]);
    await scrub([input, b, "--chain", "lowband", "--seed", "9"]);
    expect(await readMono(b, sr)).toEqual(await readMono(a, sr));
  });

  test("video out: picture copied bit for bit, metadata stripped, audio replaced", async () => {
    const mov = join(dir, "in.mov"), mp4 = join(dir, "out.mp4");
    await run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=10", "-i", input,
               "-t", "3", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
               "-metadata", "location=+37.7465-122.4334+106.217/", "-metadata", "creation_time=2026-11-03T02:33:13Z", mov]);
    const r = await scrub([mov, mp4, "--chain", "hum"]);
    expect(r.code).toBe(0);
    const tags = await run(["ffprobe", "-v", "error", "-show_entries", "format_tags", "-of", "json", mp4]);
    expect(tags).not.toContain("37.7465");
    expect(tags).not.toContain("creation_time");
    const md5 = (f: string) => run(["ffmpeg", "-v", "error", "-i", f, "-map", "0:v:0", "-c", "copy", "-f", "md5", "-"]);
    expect(await md5(mp4)).toBe(await md5(mov));
    const channels = await run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=channels", "-of", "csv=p=0", mp4]);
    expect(channels.trim()).toBe("1");
  });

  test("unknown modules fail with a helpful message and exit 1", async () => {
    const r = await scrub([input, join(dir, "x.wav"), "--chain", "lowbnad"]);
    expect(r.code).toBe(1);
    expect(r.stderr).toContain('unknown defense "lowbnad"');
  });

  test("online chains without tracks fail before doing any work", async () => {
    const r = await scrub([input, join(dir, "x.wav"), "--chain", "informed"]);
    expect(r.code).toBe(1);
  });

  test("--list prints every module", async () => {
    const r = await scrub(["--list"]);
    for (const name of ["hum", "subtract", "lowband", "scurve", "decoy", "informed", "legacy"]) expect(r.stdout).toContain(name);
  });
});
