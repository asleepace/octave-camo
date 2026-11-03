/// <reference lib="webworker" />
/**
 * Runs the Swift scrubber (WebAssembly) off the main thread. Audio never leaves the browser.
 */
import { Camo, type Clip, type Flicker, type Profiles, type Samples, type Trace } from "./camo.ts";
import { z } from "zod";
import { Request, type ScrubRequest, type WorkerMessage } from "./protocol.ts";
import { mix, spectrogram } from "../spectrum.ts";

const spectrum = (x: Float32Array, sampleRate: number) => {
  const s = spectrogram(x, sampleRate);
  return { db: s.db as Samples, frames: s.frames, hop: s.hop };
};

declare const self: DedicatedWorkerGlobalScope;

const post = (message: WorkerMessage, transfer: Transferable[] = []) => self.postMessage(message, transfer);

type Engine = {
  kind: "wasm" | "stand-in";
  analyze(clip: Clip): Trace;
  scrub(clip: Clip, request: ScrubRequest): { output: Samples; log: string[] };
  flicker(profiles: Profiles, clean: boolean): Flicker;
};

let engine: Promise<Engine> | undefined;
/** Compiled once: after a trap the instance is replaced from this, with no network (offline use). */
let compiled: Promise<{ module: WebAssembly.Module; sha256: string } | null> | undefined;

const hex = (buffer: ArrayBuffer) => Array.from(new Uint8Array(buffer), (b) => b.toString(16).padStart(2, "0")).join("");

async function compile(): Promise<{ module: WebAssembly.Module; sha256: string } | null> {
  const url = new URL(`${import.meta.env.BASE_URL}octave-camo.wasm`, self.location.origin);
  const response = await fetch(url);
  const isWasm = response.ok && (response.headers.get("content-type") ?? "").includes("application/wasm");
  if (!isWasm) {
    // Local development without the Swift toolchain: a crude JS stand-in keeps the UI usable.
    if (import.meta.env.DEV) return null;
    const type = response.headers.get("content-type") ?? "no content type";
    throw new Error(`could not load the scrubber: octave-camo.wasm is missing or not WebAssembly (HTTP ${response.status}, ${type})`);
  }
  // Hash the bytes that get compiled (not a number baked into the page): what the page shows is
  // what is actually running, to compare against the release's checksums.
  const bytes = await response.arrayBuffer();
  return { module: await WebAssembly.compile(bytes), sha256: hex(await crypto.subtle.digest("SHA-256", bytes)) };
}

async function loadEngine(): Promise<Engine> {
  compiled ??= compile().catch((error) => { compiled = undefined; throw error; });
  const built = await compiled;
  if (!built) {
    post({ type: "engine", token: 0, kind: "stand-in", sha256: "" });
    return (await import("./stand-in.ts")).standIn;
  }
  const camo = await Camo.load(built.module);
  // Reported only once it's instantiated and its exports check out: the hash is of a working engine.
  post({ type: "engine", token: 0, kind: "wasm", sha256: built.sha256 });
  return {
    kind: "wasm",
    analyze: (clip) => camo.analyze(clip),
    scrub: (clip, r) => camo.scrub(clip, { steps: r.steps, seed: r.seed, cutoff: r.cutoff, keepVoice: r.keepVoice }),
    flicker: (profiles, clean) => camo.flicker(profiles, clean),
  };
}

self.onmessage = async (event: MessageEvent<unknown>) => {
  const data = event.data as { type?: unknown; token?: unknown } | null;
  const picture = data?.type === "flicker";
  const purpose = (data as { purpose?: unknown } | null)?.purpose === "verify" ? "verify" as const : "clip" as const;
  const seq = typeof (data as { seq?: unknown } | null)?.seq === "number" ? (data as { seq: number }).seq : 0;
  const token = typeof data?.token === "number" ? data.token : 0;
  try {
    const request = Request.parse(event.data);
    // Stages describe the audio work; picture scans run alongside without touching them.
    if (!picture) post({ type: "stage", token, stage: "loading" });
    engine ??= loadEngine();
    const e = await engine;
    if (request.type === "flicker") {
      const { values, times, frames, strips, rows } = request;
      const f = e.flicker({ values, times, frames, strips, rows }, request.clean);
      post({ type: "flicker", token, purpose: request.purpose, seq: request.seq, ...f }, f.gains ? [f.gains.buffer] : []);
      return;
    }
    const clip: Clip = { sampleRate: request.sampleRate, channels: request.channels };

    if (request.type === "analyze") {
      post({ type: "stage", token, stage: "analyzing" });
      const s = spectrum(mix(clip.channels), clip.sampleRate);
      post({ type: "analysis", token, trace: e.analyze(clip), spectrum: s, engine: e.kind }, [s.db.buffer]);
      return;
    }
    post({ type: "stage", token, stage: "scrubbing" });
    const start = performance.now();
    const { output, log } = e.scrub(clip, request);
    const ms = performance.now() - start;
    post({ type: "stage", token, stage: "verifying" });
    const after = e.analyze({ sampleRate: request.sampleRate, channels: [output] });

    const s = spectrum(output, request.sampleRate);
    post({ type: "result", token, output, spectrum: s, log, after, ms, engine: e.kind }, [output.buffer, s.db.buffer]);
  } catch (error) {
    // A trap leaves the instance's memory in an unknown state: start a fresh one (from the
    // compiled module, no download). Bad requests and load failures leave it alone.
    if (error instanceof WebAssembly.RuntimeError) engine = undefined;
    const message = error instanceof z.ZodError ? "the page sent the scrubber a malformed request"
      : error instanceof WebAssembly.RuntimeError ? `the scrubber failed on this clip (${error.message})`
      : error instanceof Error ? error.message : String(error);
    post({ type: "error", token, scope: picture ? "picture" : "audio", message, ...(picture ? { purpose, seq } : {}) });
  }
};

// Load the scrubber as soon as the page starts, so after the first load the page works offline
// (a quick way to check that nothing needs the network). Errors surface on the first request.
engine = loadEngine().catch((error) => {
  engine = undefined;
  post({ type: "engine", token: 0, kind: "wasm", sha256: "", failed: error instanceof Error ? error.message : String(error) });
  throw error;
});
engine.catch(() => {});
