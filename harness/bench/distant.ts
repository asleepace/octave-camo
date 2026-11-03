/**
 * Distant-background benchmark: blind tracker vs. matched attacker, before and after scrubbing.
 *   bun bench/distant.ts [toneDb ...]     (default: -30 -35 -40 -45)
 * Each level synthesizes reference/synth_background.py's clip, attacks it with both attackers,
 * scrubs it with the analyzer command, and attacks again. Two decoy aircraft that are NOT in the
 * audio are included to check the matched attacker doesn't hallucinate detections.
 */
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Analyzer } from "../src/analyzer.ts";
import { run } from "../src/clip.ts";
import { readMono, writeMonoWav } from "../src/dsp.ts";
import { informedCancel } from "../src/cancel.ts";
import { defaultMatchedConfig, matchedAttack, whitenedSpectrogram } from "../src/matched.ts";
import { clipInfo, straightTrack } from "../test/helpers.ts";

const repo = join(import.meta.dir, "..", "..");
const analyzer = new Analyzer(process.env.OCTAVE_CAMO_CMD ?? `python3 ${join(repo, "reference", "analyze_json.py")}`);
const levels = process.argv.slice(2).map(Number);
const toneDbs = levels.length ? levels : [-30, -35, -40, -45];

const clip = clipInfo(90);
const plane = { ...straightTrack({ offsetNorthM: 5_000, heightM: 3_000, speed: 150, t0: 45 }), id: "plane", callsign: "REAL" };
const decoys = [
  { ...straightTrack({ offsetNorthM: -8_000, heightM: 4_000, speed: 200, t0: 20 }), id: "decoy1", callsign: "DECOY1" },
  { ...straightTrack({ offsetNorthM: 3_000, heightM: 6_000, speed: 220, t0: 75 }), id: "decoy2", callsign: "DECOY2" },
];

async function attack(label: string, wav: string) {
  const blind = await analyzer.analyze(wav, 6);
  const t0 = performance.now();
  const m = matchedAttack(whitenedSpectrogram(await readMono(wav, defaultMatchedConfig.sampleRate), defaultMatchedConfig),
                          [plane, ...decoys], clip);
  const secs = ((performance.now() - t0) / 1000).toFixed(1);
  const a = (id: string) => m.aircraft.find((x) => x.id === id)!;
  const real = a("plane");
  console.log(`  ${label.padEnd(9)} blind(6 dB): ${blind.consensus ? `flyby d=${blind.consensus.distance.toFixed(0)} m` : "nothing"}` +
    ` | matched: plane z=${real.peakZ.toFixed(1)}${real.detected ? " DETECTED" : ""} truth-rank ${real.truthPercentile.toFixed(1)}%` +
    ` f0=${real.f0.toFixed(1)}; decoys z=${a("decoy1").peakZ.toFixed(1)}/${a("decoy2").peakZ.toFixed(1)}` +
    (m.errorM !== undefined ? ` | location error ${m.errorM.toFixed(0)} m (nearest of top-3 ${m.ambiguityAwareErrorM!.toFixed(0)} m)` : " | not located") +
    ` [${secs}s]`);
}

const dir = await mkdtemp(join(tmpdir(), "octave-camo-bench-"));
for (const db of toneDbs) {
  const wav = join(dir, `bg${db}.wav`), clean = join(dir, `bg${db}-scrubbed.wav`);
  await run(["python3", join(repo, "reference", "synth_background.py"), wav, "--tone-db", String(db)]);
  console.log(`tone at ${db} dB re noise:`);
  await attack("original", wav);
  await analyzer.scrub(wav, clean);
  await attack("scrubbed", clean);
  if (process.env.INFORMED !== "0") {
    // Defender knows its own location/time: cancel along every nearby aircraft's true curve, then scrub.
    const cfg = defaultMatchedConfig;
    const full = await readMono(wav, 48_000);
    const reports = informedCancel(full, 48_000, whitenedSpectrogram(await readMono(wav, cfg.sampleRate), cfg),
                                   [plane, ...decoys], clip);
    const cancelled = join(dir, `bg${db}-cancelled.wav`), both = join(dir, `bg${db}-informed.wav`);
    await writeMonoWav(cancelled, full, 48_000);
    await analyzer.scrub(cancelled, both);
    console.log(`  (cancelled: ${reports.map((r) => `${r.callsign} ${r.cancelled ? `f0=${r.f0.toFixed(2)}` : "skipped"} z=${r.z.toFixed(1)}`).join(", ")})`);
    await attack("informed", both);
  }
}
