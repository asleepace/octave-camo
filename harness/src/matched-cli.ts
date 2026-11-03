import { parseArgs } from "node:util";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readClipInfo, run } from "./clip.ts";
import { readMono, writeMonoWav } from "./dsp.ts";
import { type MatchedResult, defaultMatchedConfig, matchedAttack, whitenedSpectrogram } from "./matched.ts";
import { parseChains, runChain } from "./defense/index.ts";
import { decimate } from "./defense/signal.ts";
import { printCandidates, printClip } from "./report.ts";
import { loadTracks } from "./sources/file.ts";
import { type GroundTruth, groundTruth } from "./track.ts";

const USAGE = `matched — background-aircraft attack (ADS-B informed), before and after scrubbing

usage: bun run matched <clip.mov> --track tracks.json [--chains "a+b;c"] [--radius-km 10] [--out out.mp4]

Attacks the original audio, then the output of each defense chain (see \`bun run scrub --list\`).
Default chains: hum+subtract+scurve+lowband; hum+lowband; informed+lowband.
--out writes the last chain's audio into a copy of the video (metadata stripped).
Get tracks with: bun run verify <clip.mov> --save-track tracks.json --radius-km 30`;

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    track: { type: "string" },
    "radius-km": { type: "string", default: "10" },
    out: { type: "string" },
    chains: { type: "string", default: "hum+subtract+scurve+lowband;hum+lowband;informed+lowband" },
    help: { type: "boolean", short: "h", default: false },
  },
});

function printAttack(label: string, r: MatchedResult) {
  console.log(`\n${label}`);
  const detected = r.aircraft.filter((a) => a.detected);
  if (!detected.length) {
    const top = [...r.aircraft].sort((a, b) => b.peakZ - a.peakZ)[0];
    console.log(`  nothing detected${top ? ` (strongest: ${top.callsign ?? top.id} z=${top.peakZ.toFixed(1)})` : ""}`);
    return;
  }
  for (const a of detected) {
    console.log(`  ${(a.callsign ?? a.id).padEnd(10)} z=${a.peakZ.toFixed(1).padStart(5)}  tone ${a.f0.toFixed(1)} Hz` +
      `  true location ranks top ${(100 - a.truthPercentile).toFixed(1)}%`);
  }
  console.log(`  → estimated location ${r.errorM!.toFixed(0)} m from the truth` +
    (r.ambiguityAwareErrorM !== r.errorM ? ` (${r.ambiguityAwareErrorM!.toFixed(0)} m if the mirror ambiguity is resolved)` : ""));
}

async function main() {
  const clipPath = positionals[0];
  if (opts.help || !clipPath || !opts.track) return console.log(USAGE);

  const clip = await readClipInfo(clipPath);
  printClip(clip);
  const tracks = await loadTracks(opts.track);
  const truths = tracks.map((t) => groundTruth(t, clip)).filter((t): t is GroundTruth => !!t)
    .sort((a, b) => a.distanceM - b.distanceM);
  printCandidates(truths);

  const radiusM = Number(opts["radius-km"]) * 1000;
  const attack = (x: Float32Array) => {
    const { x: low, rate } = decimate(x, 48_000, 4_000);
    const cfg = { ...defaultMatchedConfig, sampleRate: rate, radiusM };
    return matchedAttack(whitenedSpectrogram(low, cfg), tracks, clip, cfg);
  };

  const original = await readMono(clip.path, 48_000);
  printAttack("attack on the original audio:", attack(original));

  let lastOutput: Float32Array | undefined;
  for (const chain of parseChains(opts.chains!)) {
    const lines: string[] = [];
    const y = await runChain(chain, original.slice(), { sampleRate: 48_000, seed: 7, clip, tracks, log: (l) => lines.push(l) });
    lines.forEach((l) => console.log(`  · ${l}`));
    printAttack(`attack after ${chain.label}:`, attack(y));
    lastOutput = y;
  }

  if (opts.out && lastOutput) {
    const work = await mkdtemp(join(tmpdir(), "octave-camo-matched-"));
    try {
      const wav = join(work, "out.wav");
      await writeMonoWav(wav, lastOutput, 48_000);
      await run(["ffmpeg", "-loglevel", "error", "-y", "-i", clip.path, "-i", wav, "-map", "0:v:0", "-map", "1:a:0",
                 "-c:v", "copy", "-tag:v", "hvc1", "-c:a", "aac", "-b:a", "192k", "-map_metadata", "-1",
                 "-movflags", "+faststart", opts.out]);
      console.log(`\nwrote ${opts.out} (last chain)`);
    } finally {
      await rm(work, { recursive: true, force: true });
    }
  }
}

main().catch((e) => { console.error(`error: ${e instanceof Error ? e.message : e}`); process.exit(1); });
