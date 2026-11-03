import { parseArgs } from "node:util";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { extname, join } from "node:path";
import { readClipInfo, run, type ClipInfo } from "./clip.ts";
import { describeModules, needs, parseChain, runChain } from "./defense/index.ts";
import { readMono, writeMonoWav } from "./dsp.ts";
import { loadTracks } from "./sources/file.ts";

const USAGE = `scrub — apply a defense chain to a clip

usage: bun run scrub <in.mov|in.wav> <out.mp4|out.wav> [--chain CHAIN] [--track tracks.json] [--seed N]
       bun run scrub --list

CHAIN joins modules with "+", options in parentheses, e.g.
  hum+subtract+lowband                recommended default: offline, handles close and distant aircraft
  hum+lowband                         lightest: distant/background aircraft only
  hum+subtract+scurve+lowband         adds the blind flyby-curve search (faint tones above the cutoff)
  hum+lowband(mode=highpass,cutoff=250)
  informed+lowband                    online: needs --track (and the clip's metadata)

A video output keeps the picture bit-for-bit, replaces the audio (mono AAC) and strips metadata.

modules:
${describeModules()}`;

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    chain: { type: "string", default: "hum+subtract+lowband" },
    track: { type: "string" },
    seed: { type: "string" },
    list: { type: "boolean", default: false },
    help: { type: "boolean", short: "h", default: false },
  },
});

async function main() {
  const [input, output] = positionals;
  if (opts.help || opts.list || !input || !output) return console.log(USAGE);

  const chain = parseChain(opts.chain!);
  const required = needs(chain);
  const clip: ClipInfo | undefined = required.has("clip") || required.has("tracks") ? await readClipInfo(input) : undefined;
  const tracks = opts.track ? await loadTracks(opts.track) : undefined;
  if (required.has("tracks") && !tracks) throw new Error(`chain "${chain.label}" needs --track`);

  const sampleRate = 48_000;
  const x = await readMono(input, sampleRate);
  const t = performance.now();
  const y = await runChain(chain, x, {
    sampleRate, clip, tracks,
    seed: opts.seed ? Number(opts.seed) : (Math.random() * 2 ** 31) | 0,
    log: (line) => console.error(`  ${line}`),
  });
  console.error(`  (${((performance.now() - t) / 1000).toFixed(1)} s)`);

  if ([".wav"].includes(extname(output).toLowerCase())) {
    await writeMonoWav(output, y, sampleRate);
  } else {
    const dir = await mkdtemp(join(tmpdir(), "octave-camo-scrub-"));
    try {
      const wav = join(dir, "audio.wav");
      await writeMonoWav(wav, y, sampleRate);
      const codec = (await run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                "stream=codec_name", "-of", "csv=p=0", input])).trim();
      await run(["ffmpeg", "-loglevel", "error", "-y", "-i", input, "-i", wav, "-map", "0:v:0?", "-map", "1:a:0",
                 "-c:v", "copy", ...(codec === "hevc" ? ["-tag:v", "hvc1"] : []), "-c:a", "aac", "-b:a", "192k",
                 "-map_metadata", "-1", "-movflags", "+faststart", output]);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  }
  console.log(`wrote ${output}`);
}

main().catch((e) => { console.error(`error: ${e instanceof Error ? e.message : e}`); process.exit(1); });
