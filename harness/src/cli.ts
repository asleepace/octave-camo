import { parseArgs } from "node:util";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Analyzer } from "./analyzer.ts";
import { extractAudio, readClipInfo } from "./clip.ts";
import { compare, printCandidates, printClip, printComparison } from "./report.ts";
import { loadTracks, saveTracks } from "./sources/file.ts";
import { Flightradar24 } from "./sources/fr24.ts";
import { OpenSky } from "./sources/opensky.ts";
import type { TrackSource } from "./sources/types.ts";
import { type GroundTruth, groundTruth } from "./track.ts";

const USAGE = `verify — check the audio attack (and the scrub) against real flight data

usage: bun run verify <clip.mov> [options]

  --source opensky|fr24     where to get aircraft tracks (default: opensky)
  --track FILE              replay a saved track instead (no API calls)
  --save-track FILE         save fetched tracks for replay
  --icao24 HEX              aircraft transponder address, if known
  --callsign CS             callsign, e.g. UAL1234 (from a Flightradar24 screenshot)
  --flight-id ID            Flightradar24 flight id
  --radius-km N             search radius around the phone (default 15)
  --threshold DB            attacker sensitivity, lower is more sensitive (default 10)
  --scrub                   also scrub the audio and attack it again at 10, 6 and 3 dB
  --json FILE               write the full report as JSON

Credentials come from harness/.env (see .env.example).`;

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    source: { type: "string", default: "opensky" },
    track: { type: "string" },
    "save-track": { type: "string" },
    icao24: { type: "string" },
    callsign: { type: "string" },
    "flight-id": { type: "string" },
    "radius-km": { type: "string", default: "15" },
    threshold: { type: "string", default: "10" },
    scrub: { type: "boolean", default: false },
    json: { type: "string" },
    help: { type: "boolean", short: "h", default: false },
  },
});

function sourceFor(name: string): TrackSource {
  if (name === "opensky") return new OpenSky();
  if (name === "fr24") return new Flightradar24();
  throw new Error(`unknown --source ${name} (opensky or fr24)`);
}

function pickTruth(truths: GroundTruth[]): GroundTruth | undefined {
  // Prefer aircraft whose closest approach is actually in the clip.
  return truths.find((t) => t.inClip) ?? truths[0];
}

async function main() {
  const clipPath = positionals[0];
  if (opts.help || !clipPath) {
    console.log(USAGE);
    return;
  }

  const clip = await readClipInfo(clipPath);
  printClip(clip);

  const tracks = opts.track
    ? await loadTracks(opts.track)
    : await sourceFor(opts.source!).findTracks(clip, {
        radiusKm: Number(opts["radius-km"]),
        icao24: opts.icao24,
        callsign: opts.callsign,
        flightId: opts["flight-id"],
      });
  if (opts["save-track"]) await saveTracks(opts["save-track"], tracks);

  const truths = tracks
    .map((t) => groundTruth(t, clip))
    .filter((t): t is GroundTruth => t !== undefined)
    .sort((a, b) => a.distanceM - b.distanceM);
  printCandidates(truths);
  const truth = pickTruth(truths);
  if (!truth) throw new Error("no aircraft tracks overlap the clip's time window");
  if (!truth.inClip) console.log("\n⚠ the nearest closest approach falls outside the clip; the attack needs it inside");

  const analyzer = new Analyzer();
  const work = await mkdtemp(join(tmpdir(), "octave-camo-verify-"));
  try {
    const wav = join(work, "audio.wav");
    await extractAudio(clip.path, wav);

    const threshold = Number(opts.threshold);
    const original = compare(truth, await analyzer.analyze(wav, threshold));
    printComparison(`attack on the original audio (threshold ${threshold} dB):`, truth, original);

    const scrubbed: { thresholdDB: number; recovered: boolean }[] = [];
    if (opts.scrub) {
      const clean = join(work, "scrubbed.wav");
      await analyzer.scrub(wav, clean);
      for (const th of [10, 6, 3]) {
        const c = compare(truth, await analyzer.analyze(clean, th));
        printComparison(`attack on the scrubbed audio (threshold ${th} dB):`, truth, c);
        scrubbed.push({ thresholdDB: th, recovered: c.recovered });
      }
    }

    console.log("\nverdict:");
    console.log(original.recovered
      ? "  ATTACK WORKS: the audio alone recovered the closest approach (distance and time)"
      : "  attack did not recover this flyby (too faint, too far, or closest approach outside the clip)");
    if (opts.scrub) {
      const leaked = scrubbed.filter((s) => s.recovered).map((s) => `${s.thresholdDB} dB`);
      console.log(leaked.length
        ? `  SCRUB LEAKED: flyby still recoverable at ${leaked.join(", ")}`
        : original.recovered
          ? "  SCRUB HELD: no attacker sensitivity recovered the flyby after scrubbing"
          : "  scrub not tested meaningfully: the original attack already failed");
    }

    if (opts.json) {
      await Bun.write(opts.json, JSON.stringify({ clip, candidates: truths, truth, original, scrubbed }, null, 2));
    }
  } finally {
    await rm(work, { recursive: true, force: true });
  }
}

main().catch((e) => {
  console.error(`error: ${e instanceof Error ? e.message : e}`);
  process.exit(1);
});
