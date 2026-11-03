/// <reference lib="webworker" />
/**
 * Runs the Swift scrubber (WebAssembly) off the main thread. Audio never leaves the browser.
 */
import { Camo, type Clip, type Flicker, type Profiles, type Samples, type Trace } from "./camo.ts";
import { Request, type ScrubRequest, type WorkerMessage } from "./protocol.ts";

declare const self: DedicatedWorkerGlobalScope;

const post = (message: WorkerMessage, transfer: Transferable[] = []) => self.postMessage(message, transfer);

type Engine = {
  kind: "wasm" | "stand-in";
  analyze(clip: Clip): Trace;
  scrub(clip: Clip, request: ScrubRequest): { output: Samples; log: string[] };
  flicker(profiles: Profiles, clean: boolean): Flicker;
};

let engine: Promise<Engine> | undefined;

async function loadEngine(): Promise<Engine> {
  const url = new URL(`${import.meta.env.BASE_URL}octave-camo.wasm`, self.location.origin);
  const response = await fetch(url);
  const isWasm = response.ok && (response.headers.get("content-type") ?? "").includes("application/wasm");
  if (!isWasm) {
    // Local development without the Swift toolchain: a crude JS stand-in keeps the UI usable.
    if (import.meta.env.DEV) return (await import("./stand-in.ts")).standIn;
    const type = response.headers.get("content-type") ?? "no content type";
    throw new Error(`could not load the scrubber: octave-camo.wasm is missing or not WebAssembly (HTTP ${response.status}, ${type})`);
  }
  const camo = await Camo.load(response);
  return {
    kind: "wasm",
    analyze: (clip) => camo.analyze(clip),
    scrub: (clip, r) => camo.scrub(clip, { steps: r.steps, seed: r.seed, cutoff: r.cutoff, keepVoice: r.keepVoice }),
    flicker: (profiles, clean) => camo.flicker(profiles, clean),
  };
}

self.onmessage = async (event: MessageEvent<unknown>) => {
  const picture = (event.data as { type?: unknown } | null)?.type === "flicker";
  try {
    const request = Request.parse(event.data);
    // Stages describe the audio work; picture scans run alongside without touching them.
    if (!picture) post({ type: "stage", stage: "loading" });
    engine ??= loadEngine();
    const e = await engine;
    if (request.type === "flicker") {
      const { values, times, frames, strips, rows } = request;
      const f = e.flicker({ values, times, frames, strips, rows }, request.clean);
      post({ type: "flicker", purpose: request.purpose, ...f }, f.gains ? [f.gains.buffer] : []);
      return;
    }
    const clip: Clip = { sampleRate: request.sampleRate, channels: request.channels };

    if (request.type === "analyze") {
      post({ type: "stage", stage: "analyzing" });
      post({ type: "analysis", trace: e.analyze(clip), engine: e.kind });
      return;
    }
    post({ type: "stage", stage: "scrubbing" });
    const start = performance.now();
    const { output, log } = e.scrub(clip, request);
    const ms = performance.now() - start;
    post({ type: "stage", stage: "verifying" });
    const after = e.analyze({ sampleRate: request.sampleRate, channels: [output] });

    post({ type: "result", output, log, after, ms, engine: e.kind }, [output.buffer]);
  } catch (error) {
    engine = undefined;
    post({ type: "error", scope: picture ? "picture" : "audio", message: error instanceof Error ? error.message : String(error) });
  }
};
