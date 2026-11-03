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
};

export type ScrubResult = { output: Samples; log: string[] };

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
  camo_output(): number;
  camo_log(): number;
  camo_log_length(): number;
};

const EXPORTS = ["camo_alloc", "camo_free", "camo_steps", "camo_scrub", "camo_analyze", "camo_output",
  "camo_log", "camo_log_length"] as const;

export class Camo {
  private constructor(private readonly x: Exports) {}

  static async load(bytes: BufferSource | Response | Promise<Response>): Promise<Camo> {
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
      : await WebAssembly.instantiate(await WebAssembly.compile(source), imports);
    const x = instance.exports as unknown as Exports;
    for (const name of EXPORTS) {
      if (typeof x[name] !== "function") throw new Error(`octave-camo.wasm is missing export ${name}`);
    }
    wasi.initialize(instance as unknown as { exports: { memory: WebAssembly.Memory; _initialize?: () => unknown } });
    return new Camo(x);
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
      const output = new Float32Array(this.x.memory.buffer, this.x.camo_output(), n).slice();
      const bytes = new Uint8Array(this.x.memory.buffer, this.x.camo_log(), this.x.camo_log_length());
      return { output, log: new TextDecoder().decode(bytes).split("\n").filter(Boolean) };
    });
  }

  analyze(clip: Clip): Trace {
    return this.withInput(clip, (pointer, frames) => {
      const at = this.x.camo_analyze(pointer, clip.channels.length, frames, clip.sampleRate);
      const [tones, doppler, hum, flybys] = new Int32Array(this.x.memory.buffer, at, 4);
      return { tones: tones!, doppler: doppler!, hum: hum!, flybys: flybys! };
    });
  }

  /** Copies the clip into wasm memory (planar) for one call. */
  private withInput<T>(clip: Clip, body: (pointer: number, frames: number) => T): T {
    const frames = clip.channels[0]?.length ?? 0;
    if (!frames) throw new Error("empty clip");
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
