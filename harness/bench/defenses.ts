/**
 * Defense comparison: every chain × every clip, after an AAC re-encode (like posting to X),
 * scored by both attackers and by what it costs a listener.
 *
 *   bun bench/defenses.ts                      # default chains and clips
 *   bun bench/defenses.ts --chains "hum+lowband;hum+scurve" --clips distant,speech --no-aac
 *
 * Clips (synthetic, known truth):
 *   distant  quiet 90 s ambience, jet at 5.8 km slant, tone -25 dB below the noise
 *   speech   the same with speech-like syllables for the first 45 s
 *   close    60 s, close flyby at 1.5 km (the original blind-attack case)
 *   train-close, train-distant, ship   other sources with public tracks (see THREAT_MODEL.md)
 */
import { parseArgs } from "node:util";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Analyzer } from "../src/analyzer.ts";
import { run } from "../src/clip.ts";
import { DEFAULT_CHAIN, parseChains, runChain } from "../src/defense/index.ts";
import { decimate } from "../src/defense/signal.ts";
import { readMono, writeMonoWav } from "../src/dsp.ts";
import { defaultMatchedConfig, matchedAttack, whitenedSpectrogram } from "../src/matched.ts";
import { loudnessChange, voiceRetention } from "../src/quality.ts";
import type { FlightTrack } from "../src/track.ts";
import { clipInfo, straightTrack } from "../test/helpers.ts";

const DEFAULT_CHAINS = [
  "none", "legacy", "hum+lowband(mode=highpass)", "hum+lowband", "hum+scurve", "hum+scurve+lowband",
  "hum+lowband+decoy", "hum+scurve+lowband+decoy", "informed+legacy", "decoy(mode=spoof)+informed+lowband",
].join(";");

const { values: opts } = parseArgs({
  options: {
    chains: { type: "string", default: DEFAULT_CHAINS },
    clips: { type: "string", default: "distant,speech,close" },
    "no-aac": { type: "boolean", default: false },
    /** CI gate: exit 1 if the default chain leaks on any clip (both the harness modules and the
     *  shipped Swift pipeline), or if "none" stops leaking (the attackers broke, which would make
     *  every defense look safe). */
    gate: { type: "boolean", default: false },
    json: { type: "string" },
  },
});
if (opts.gate) opts.chains = `none;${DEFAULT_CHAIN};swift`;
type Row = { clip: string; chain: string; blind: string; matched: string; leak: boolean; nullZ: number; lowDb: number; highDb: number; voice?: number };
const rows: Row[] = [];

const repo = join(import.meta.dir, "..", "..");
const ref = (f: string) => join(repo, "reference", f);
const SR = 48_000;
const analyzer = new Analyzer(process.env.OCTAVE_CAMO_CMD ?? `python3 ${ref("analyze_json.py")}`);
const dir = await mkdtemp(join(tmpdir(), "octave-camo-defenses-"));

const decoys = [
  { ...straightTrack({ offsetNorthM: -8_000, heightM: 4_000, speed: 200, t0: 20 }), id: "decoy1", callsign: "DECOY1" },
  { ...straightTrack({ offsetNorthM: 3_000, heightM: 6_000, speed: 220, t0: 75 }), id: "decoy2", callsign: "DECOY2" },
];

type Clip = {
  name: string; wav: string; voice?: string; durationS: number; plane: FlightTrack; truthD: number;
  /** Renders the same scene without the source (for the attacker's noise floor). */
  renderNull?: (out: string, seed: number) => Promise<void>;
};

/** Moving sources on straight tracks, rendered by reference/synth_source.py (ground level unless noted). */
const SOURCES: Record<string, { f0: number; speed: number; northM: number; heightM: number; t0: number; duration: number; toneDb: number; harmonics: number }> = {
  // Traction-inverter whine of a passing train: close, slow, well above lowband's 300 Hz cutoff.
  "train-close":   { f0: 600, speed: 25, northM: 120, heightM: 0, t0: 30, duration: 60, toneDb: -10, harmonics: 2 },
  // The same train across the neighborhood: faint, still above the cutoff.
  "train-distant": { f0: 600, speed: 30, northM: 900, heightM: 0, t0: 30, duration: 60, toneDb: -22, harmonics: 2 },
  // A ship's engine on the Bay: low, very slow (small Doppler), far.
  "ship":          { f0: 70, speed: 6, northM: 400, heightM: 0, t0: 45, duration: 90, toneDb: -15, harmonics: 3 },
};

async function makeClip(name: string): Promise<Clip> {
  const wav = join(dir, `${name}.wav`);
  const source = SOURCES[name];
  if (source) {
    const d = Math.hypot(source.northM, source.heightM);
    const render = (out: string, toneDb: number, seed: number) =>
      run(["python3", ref("synth_source.py"), out, "--f0", String(source.f0), "--speed", String(source.speed),
           "--distance", String(d), "--t0", String(source.t0), "--duration", String(source.duration),
           "--tone-db", String(toneDb), "--harmonics", String(source.harmonics), "--seed", String(seed)]);
    await render(wav, source.toneDb, 1);
    return { name, wav, durationS: source.duration, truthD: d, renderNull: (out, seed) => render(out, -200, seed).then(() => {}),
             plane: { ...straightTrack({ offsetNorthM: source.northM, heightM: source.heightM, speed: source.speed, t0: source.t0 }),
                      id: "plane", callsign: "REAL" } };
  }
  if (name === "close") {
    await run(["python3", ref("proto.py"), "synth", wav]);
    return { name, wav, durationS: 60, truthD: 1500,
             plane: { ...straightTrack({ offsetNorthM: 900, heightM: 1200, speed: 75, t0: 30 }), id: "plane", callsign: "REAL" } };
  }
  if (name !== "distant" && name !== "speech") throw new Error(`unknown clip ${name}`);
  const speech = name === "speech" ? ["--speech", "45"] : [];
  await run(["python3", ref("synth_background.py"), wav, "--tone-db", "-25", ...speech]);
  return { name, wav, voice: name === "speech" ? wav.replace(".wav", ".speech.wav") : undefined, durationS: 90,
           renderNull: (out, seed) => run(["python3", ref("synth_background.py"), out, "--tone-db", "-200", "--seed", String(seed), ...speech]).then(() => {}),
           truthD: 5831, plane: { ...straightTrack({ offsetNorthM: 5_000, heightM: 3_000, speed: 150, t0: 45 }), id: "plane", callsign: "REAL" } };
}

async function aacRoundTrip(x: Float32Array, tag: string): Promise<Float32Array> {
  if (opts["no-aac"]) return x;
  const a = join(dir, `${tag}.wav`), m = join(dir, `${tag}.m4a`);
  await writeMonoWav(a, x, SR);
  await run(["ffmpeg", "-loglevel", "error", "-y", "-i", a, "-c:a", "aac", "-b:a", "128k", m]);
  return readMono(m, SR);
}

const pad = (s: string, n: number) => (s.length >= n ? s : s + " ".repeat(n - s.length));
console.log(`AAC re-encode: ${opts["no-aac"] ? "off" : "128 kbps"}; attackers: blind tracker (6 dB) and matched (ADS-B, true + 2 decoy tracks)\n`);

for (const name of opts.clips!.split(",")) {
  const clip = await makeClip(name);
  const info = clipInfo(clip.durationS);
  const tracks = [clip.plane, ...decoys];
  const original = await readMono(clip.wav, SR);
  const voice = clip.voice ? await readMono(clip.voice, SR) : undefined;
  // The attacker's noise floor on this scene: its peak z for the real track on renders with no
  // source at all (after the same AAC round trip). Slow sources have nearly flat curves that
  // match any steady residue, so a fixed z threshold alone gives false "leaks" there.
  let nullZ = 0;
  if (clip.renderNull) {
    for (const seed of [11, 12, 13]) {
      const nw = join(dir, `${name}-null-${seed}.wav`);
      await clip.renderNull(nw, seed);
      const posted = await aacRoundTrip(await readMono(nw, SR), `${name}-null-${seed}`);
      const { x: low, rate } = decimate(posted, SR, 4_000);
      const cfg = { ...defaultMatchedConfig, sampleRate: rate };
      const m = matchedAttack(whitenedSpectrogram(low, cfg), tracks, info, cfg);
      nullZ = Math.max(nullZ, m.aircraft.find((a) => a.id === "plane")!.peakZ);
    }
  }
  const leakZ = Math.max(defaultMatchedConfig.detectionZ, nullZ + 3);
  console.log(`=== ${name} (${clip.durationS} s, true closest approach ${clip.truthD} m; attacker noise floor z ${nullZ.toFixed(1)}, leak above z ${leakZ.toFixed(1)})`);
  console.log(`  ${pad("chain", 38)} ${pad("blind attack", 16)} ${pad("matched attack (ADS-B)", 34)} low Δ   high Δ${voice ? "  voice<300Hz" : ""}`);

  for (const chain of parseChains(opts.chains!.replace(/(^|;)none(;|$)/, "$1hum(mains=0)$2"))) {
    const label = chain.label === "hum(mains=0)" ? "none" : chain.label;
    const t = performance.now();
    const processed = await runChain(chain, original.slice(),
      { sampleRate: SR, seed: 7, clip: info, tracks, log: () => {} });
    const posted = await aacRoundTrip(processed, `${name}-${Math.random().toString(36).slice(2)}`);

    const pw = join(dir, `${name}-posted.wav`);
    await writeMonoWav(pw, posted, SR);
    const blind = await analyzer.analyze(pw, 6);
    const blindText = blind.consensus
      ? `${Math.abs(blind.consensus.distance - clip.truthD) < 0.1 * clip.truthD ? "LEAK" : "wrong"} ${(blind.consensus.distance / 1000).toFixed(1)} km`
      : "nothing";

    const { x: low, rate } = decimate(posted, SR, 4_000);
    const cfg = { ...defaultMatchedConfig, sampleRate: rate };
    const m = matchedAttack(whitenedSpectrogram(low, cfg), tracks, info, cfg);
    const real = m.aircraft.find((a) => a.id === "plane")!;
    const located = real.detected && real.peakZ > leakZ && (m.ambiguityAwareErrorM ?? Infinity) <= 1_000;
    const nearTruth = real.detected && (m.ambiguityAwareErrorM ?? Infinity) <= 1_000;
    const matchedText = located
      ? `LEAK ${m.ambiguityAwareErrorM!.toFixed(0)} m (z ${real.peakZ.toFixed(0)})`
      : nearTruth
        ? `at noise floor (z ${real.peakZ.toFixed(0)})`
        : m.errorM !== undefined
          ? `wrong place ${(m.errorM / 1000).toFixed(1)} km off`
          : `no detection (truth top ${(100 - real.truthPercentile).toFixed(0)}%)`;

    const low300 = loudnessChange(original, processed, SR, 30, 300);
    const high = loudnessChange(original, processed, SR, 300, 4000);
    const v = voice ? voiceRetention(voice, processed, SR) : NaN;
    rows.push({ clip: name, chain: label, blind: blindText, matched: matchedText, leak: located || blindText.startsWith("LEAK"), nullZ,
      lowDb: low300, highDb: high, voice: voice ? v : undefined });
    console.log(`  ${pad(label, 38)} ${pad(blindText, 16)} ${pad(matchedText, 34)} ${low300.toFixed(1).padStart(4)} dB ${high.toFixed(1).padStart(4)} dB` +
      `${voice ? `  ${(v * 100).toFixed(0).padStart(5)}%` : ""}  [${((performance.now() - t) / 1000).toFixed(0)}s]`);
  }
  console.log("");
}

if (opts.json) await Bun.write(opts.json, JSON.stringify(rows, null, 1));
if (opts.gate) {
  const failures = [
    ...rows.filter((r) => (r.chain === DEFAULT_CHAIN || r.chain === "swift") && r.leak)
      .map((r) => `${r.clip}: ${r.chain === "swift" ? "the Swift pipeline" : "the default chain"} leaks (${r.blind}; ${r.matched})`),
    ...rows.filter((r) => r.chain === "none" && !r.leak).map((r) => `${r.clip}: attackers no longer find the uncloaked clip`),
  ];
  console.log(failures.length ? `GATE FAILED\n  ${failures.join("\n  ")}`
    : "GATE PASSED: the default chain (harness and Swift) is safe on every clip, and the attackers still find every uncloaked one");
  process.exitCode = failures.length ? 1 : 0;
}
