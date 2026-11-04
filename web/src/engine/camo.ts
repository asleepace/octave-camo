/**
 * Typed binding to the Swift scrubber compiled to WebAssembly (Sources/OctaveCamoWasm).
 * Runs anywhere WebAssembly does: a browser worker, Bun or Node (tests).
 */
import { ConsoleStdout, File, OpenFile, WASI } from "@bjorn3/browser_wasi_shim";

/** Pipeline steps, in the order of Swift's `ScrubStep.allCases` (bit i of the steps mask). */
export const STEPS = ["mono", "hum", "subtract", "scurve", "lowband", "wobble"] as const;
export type Step = (typeof STEPS)[number];

export type Samples = Float32Array<ArrayBuffer>;
export type Clip = { sampleRate: number; channels: Samples[] };

/** What a blind attacker can still follow (Swift's FlybyAnalyzer). */
export type Trace = {
  /** Long narrow tones the tracker can follow. */
  tones: number;
  /** Tones whose pitch bends like a passing source. */
  doppler: number;
  /** Mains-hum lines (a recording-time clock). */
  hum: number;
  /** Doppler tones with a physically plausible flyby fit. */
  flybys: number;
  /** Every long tone found, as a time × frequency box (for outlining on the spectrogram). */
  found: Found[];
};

export const FOUND_KINDS = ["hum", "steady", "doppler", "noFit"] as const;
/** Most tones reported for outlining (the worker message's limit). */
export const MAX_FOUND = 1_000;
export type Found = { start: number; end: number; lo: number; hi: number; kind: (typeof FOUND_KINDS)[number] };

export type ScrubResult = { output: Samples; log: string[] };

/** Row profiles of a video: log brightness per frame, column strip and row band (row 0 on top). */
export type Profiles = { frames: number; strips: number; rows: number; values: Samples; times: Samples };

/** Mains flicker in the picture (Swift's FlickerScan). */
export type Flicker = {
  /** False when the scan couldn't look (too few frames, or a frame rate too high): not clean. */
  checked: boolean;
  detected: boolean;
  /** Line strength (robust z); detection above 60. */
  z: number;
  flickerHz: number;
  readoutMs: number;
  /** The same scan on the corrected picture (equal to the above when nothing was removed). */
  after: { detected: boolean; z: number };
  passesRemoved: number;
  /** frames × rows multiplicative gains (only when cleaning). */
  gains?: Float32Array<ArrayBuffer>;
};

export type ScrubOptions = {
  /** Steps to run; omitted means the Swift default. */
  steps?: readonly Step[];
  /** Noise seed (0 = random). Same seed, same output. */
  seed?: number;
  /** lowband cutoff, Hz (omitted = the Swift default, 300). */
  cutoff?: number;
  /** Keep tracked voice harmonics below the cutoff (default true). */
  keepVoice?: boolean;
};

type Exports = {
  memory: WebAssembly.Memory;
  _initialize?: () => unknown;
  camo_alloc(count: number): number;
  camo_free(pointer: number): void;
  camo_steps(): number;
  camo_scrub(pointer: number, channels: number, frames: number, sampleRate: number,
             steps: number, seedLo: number, seedHi: number, cutoffHz: number, keepVoice: number): number;
  camo_analyze(pointer: number, channels: number, frames: number, sampleRate: number): number;
  camo_flicker(pointer: number, frames: number, strips: number, rows: number, clean: number): number;
  camo_flicker_gains(): number;
  camo_flicker_gains_length(): number;
  camo_tracks(): number;
  camo_tracks_length(): number;
  camo_output(): number;
  camo_log(): number;
  camo_log_length(): number;
};

const EXPORTS = ["camo_alloc", "camo_free", "camo_steps", "camo_scrub", "camo_analyze", "camo_flicker",
  "camo_flicker_gains", "camo_flicker_gains_length", "camo_tracks", "camo_tracks_length", "camo_output", "camo_log", "camo_log_length"] as const;

export class Camo {
  private constructor(private readonly x: Exports) {}

  static async load(bytes: BufferSource | WebAssembly.Module | Response | Promise<Response>): Promise<Camo> {
    const fds = [
      new OpenFile(new File([])),
      ConsoleStdout.lineBuffered((line) => console.log(`[camo] ${line}`)),
      ConsoleStdout.lineBuffered((line) => console.warn(`[camo] ${line}`)),
    ];
    const wasi = new WASI([], [], fds);
    const imports = { wasi_snapshot_preview1: wasi.wasiImport };
    const source = await bytes;
    const instance = source instanceof Response
      ? (await WebAssembly.instantiateStreaming(source, imports)).instance
      : await WebAssembly.instantiate(source instanceof WebAssembly.Module ? source : await WebAssembly.compile(source), imports);
    const x = instance.exports as unknown as Exports;
    for (const name of EXPORTS) {
      if (typeof x[name] !== "function") throw new Error(`octave-camo.wasm is missing export ${name}`);
    }
    wasi.initialize(instance as unknown as { exports: { memory: WebAssembly.Memory; _initialize?: () => unknown } });
    return new Camo(x);
  }

  /** Bytes of WebAssembly memory reserved. It only grows, so after a run it is at least that run's peak. */
  get memoryBytes(): number {
    return this.x.memory.buffer.byteLength;
  }

  /** Steps the Swift pipeline runs by default. */
  get defaultSteps(): Step[] {
    const mask = this.x.camo_steps();
    return STEPS.filter((_, i) => mask & (1 << i));
  }

  scrub(clip: Clip, options: ScrubOptions = {}): ScrubResult {
    const mask = options.steps ? options.steps.reduce((m, s) => m | (1 << STEPS.indexOf(s)), 0) : 0;
    const seed = options.seed ?? 0;
    return this.withInput(clip, (pointer, frames) => {
      const n = this.x.camo_scrub(pointer, clip.channels.length, frames, clip.sampleRate, mask,
        seed >>> 0, Math.floor(seed / 2 ** 32) >>> 0, options.cutoff ?? 0, options.keepVoice === false ? 0 : 1);
      if (n !== frames) throw new Error("the scrubber rejected this audio");
      const output = new Float32Array(this.x.memory.buffer, this.x.camo_output(), n).slice();
      const bytes = new Uint8Array(this.x.memory.buffer, this.x.camo_log(), this.x.camo_log_length());
      return { output, log: new TextDecoder().decode(bytes).split("\n").filter(Boolean) };
    });
  }

  analyze(clip: Clip): Trace {
    return this.withInput(clip, (pointer, frames) => {
      const at = this.x.camo_analyze(pointer, clip.channels.length, frames, clip.sampleRate);
      const [tones, doppler, hum, flybys] = new Int32Array(this.x.memory.buffer, at, 4);
      if (tones! < 0) throw new Error("the analyzer rejected this audio");
      const raw = new Float32Array(this.x.memory.buffer, this.x.camo_tracks(), this.x.camo_tracks_length());
      const found: Found[] = [];
      // Longest first (the analyzer sorts them); the page outlines at most MAX_FOUND, while the
      // counts above stay complete.
      for (let i = 0; i + 4 < raw.length && found.length < MAX_FOUND; i += 5) {
        found.push({ start: raw[i]!, end: raw[i + 1]!, lo: raw[i + 2]!, hi: raw[i + 3]!, kind: FOUND_KINDS[raw[i + 4]!] ?? "noFit" });
      }
      return { tones: tones!, doppler: doppler!, hum: hum!, flybys: flybys!, found };
    });
  }

  /** Scan row profiles for mains flicker; with `clean`, also compute per-row gains that remove it. */
  flicker(p: Profiles, clean = false): Flicker {
    const n = p.frames * p.strips * p.rows;
    if (p.values.length !== n || p.times.length !== p.frames) throw new Error("profile size mismatch");
    const pointer = this.x.camo_alloc(n + p.frames);
    try {
      const heap = new Float32Array(this.x.memory.buffer, pointer, n + p.frames);
      heap.set(p.values, 0);
      heap.set(p.times, n);
      const at = this.x.camo_flicker(pointer, p.frames, p.strips, p.rows, clean ? 1 : 0);
      const v = new Float64Array(this.x.memory.buffer, at, 9);
      const result: Flicker = {
        checked: v[8] === 1, detected: v[0] === 1, z: v[1]!, flickerHz: v[2]!, readoutMs: v[4]! * 1000,
        after: { detected: v[5] === 1, z: v[6]! }, passesRemoved: v[7]!,
      };
      if (clean) {
        const length = this.x.camo_flicker_gains_length();
        if (length === p.frames * p.rows) result.gains = new Float32Array(this.x.memory.buffer, this.x.camo_flicker_gains(), length).slice();
        else if (length !== 0 || result.checked) throw new Error("the flicker scan returned gains of the wrong size");
      }
      return result;
    } finally {
      this.x.camo_free(pointer);
    }
  }

  /** Copies the clip into wasm memory (planar) for one call. */
  private withInput<T>(clip: Clip, body: (pointer: number, frames: number) => T): T {
    const frames = clip.channels[0]?.length ?? 0;
    if (!frames) throw new Error("empty clip");
    if (clip.channels.some((ch) => ch.length !== frames)) throw new Error("channels differ in length");
    const pointer = this.x.camo_alloc(frames * clip.channels.length);
    try {
      // Re-read memory.buffer after every call: allocation can grow (and detach) it.
      const heap = new Float32Array(this.x.memory.buffer, pointer, frames * clip.channels.length);
      clip.channels.forEach((ch, i) => heap.set(ch, i * frames));
      return body(pointer, frames);
    } finally {
      this.x.camo_free(pointer);
    }
  }
}
