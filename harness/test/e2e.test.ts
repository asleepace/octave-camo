import { expect, test } from "bun:test";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readClipInfo, run } from "../src/clip.ts";
import { saveTracks } from "../src/sources/file.ts";
import { PHONE, START, straightTrack } from "./helpers.ts";

/**
 * Full verify flow with no network: a synthetic flyby (1500 m slant, 75 m/s, heard at t=30 s)
 * inside a video carrying iPhone-style GPS/time metadata, and a matching track with 5 s waypoints
 * (like OpenSky). Slow (~2–3 min with the NumPy analyzer), so opt in: E2E=1 bun test
 */
const repo = join(import.meta.dir, "..", "..");
const analyzerCmd = process.env.OCTAVE_CAMO_CMD ?? `python3 ${join(repo, "reference", "analyze_json.py")}`;

test.skipIf(!process.env.E2E)("attack recovers the flyby; scrub defeats it", async () => {
  const dir = await mkdtemp(join(tmpdir(), "octave-camo-e2e-"));
  const wav = join(dir, "fly.wav"), clip = join(dir, "clip.mov"), track = join(dir, "track.json");
  const report = join(dir, "report.json");

  await run(["python3", join(repo, "reference", "proto.py"), "synth", wav]);
  const iso6709 = `${PHONE.lat >= 0 ? "+" : ""}${PHONE.lat}${PHONE.lon >= 0 ? "+" : ""}${PHONE.lon}+${PHONE.altM}/`;
  await run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=black:s=320x240:r=24",
             "-i", wav, "-t", "60", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
             "-metadata", `location=${iso6709}`, "-metadata", `creation_time=${new Date(START * 1000).toISOString()}`,
             clip]);
  const info = await readClipInfo(clip);
  expect(info.location.lat).toBeCloseTo(PHONE.lat, 4);
  expect(info.startTime).toBe(START);

  await saveTracks(track, [straightTrack({ offsetNorthM: 900, heightM: 1200, speed: 75, t0: 30 })]);
  const out = await run(["bun", join(import.meta.dir, "..", "src", "cli.ts"), clip, "--track", track,
                         "--scrub", "--json", report], { OCTAVE_CAMO_CMD: analyzerCmd });
  console.log(out);

  const r = await Bun.file(report).json();
  expect(r.truth.distanceM).toBeCloseTo(1500, -1);
  expect(r.original.recovered).toBe(true);
  for (const s of r.scrubbed) expect(s.recovered).toBe(false);
}, { timeout: 600_000 });
