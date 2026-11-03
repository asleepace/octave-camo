import "./style.css";
import { STEPS, type Step, type Trace } from "./engine/camo.ts";
import { type Request, type Stage, WorkerMessage } from "./engine/protocol.ts";
import { load, type Loaded, MediaError, outputName, save } from "./media.ts";
import { Player, type Side } from "./player.ts";
import { demo, meanBands, mix, percentile, type Spectrogram, spectrogram } from "./spectrum.ts";
import { bandChart } from "./ui/bands.ts";
import { formatHz, Terrain } from "./ui/terrain.ts";

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const clock = (t: number) => `${Math.floor(t / 60)}:${String(Math.floor(t % 60)).padStart(2, "0")}`;
const randomSeed = () => 1 + Math.floor(Math.random() * 9_999);

/** User-facing steps, in pipeline order (mono always runs). */
const OPTIONAL: Step[] = ["hum", "subtract", "scurve", "lowband", "wobble"];
const DEFAULT_STEPS: Step[] = ["hum", "subtract", "scurve", "lowband"];
const STEP_INFO: Record<Step, string> = {
  mono: "average channels",
  hum: "notch mains hum",
  subtract: "cancel long tones",
  scurve: "find flyby curves",
  lowband: "regenerate < fc",
  wobble: "pitch drift",
};

const state = {
  loaded: null as Loaded | null,
  input: null as Spectrogram | null,
  output: null as Spectrogram | null,
  outputSamples: null as Float32Array | null,
  before: null as Trace | null,
  after: null as Trace | null,
  log: [] as string[],
  steps: new Set<Step>(DEFAULT_STEPS),
  cutoff: 300,
  keepVoice: true,
  seed: randomSeed(),
  busy: null as Stage | "decoding" | "saving" | null,
  stale: false,
  ms: 0,
  engine: "wasm" as "wasm" | "stand-in",
  error: "",
};

const demoData = demo();
const player = new Player();
const terrain = new Terrain($<HTMLCanvasElement>("terrain"));
const worker = new Worker(new URL("./engine/worker.ts", import.meta.url), { type: "module" });

// ---------- worker ----------

function send(request: Request) {
  worker.postMessage(request);
}

worker.onmessage = (event) => {
  const parsed = WorkerMessage.safeParse(event.data);
  if (!parsed.success) return fail("unexpected message from the scrubber");
  const m = parsed.data;
  switch (m.type) {
    case "stage":
      state.busy = m.stage;
      break;
    case "analysis":
      state.before = m.trace;
      state.engine = m.engine;
      state.busy = null;
      break;
    case "result": {
      const loaded = state.loaded;
      if (!loaded) return;
      state.busy = null;
      state.outputSamples = m.output;
      state.after = m.after;
      state.log = m.log;
      state.ms = m.ms;
      state.engine = m.engine;
      state.stale = false;
      state.output = spectrogram(m.output, loaded.clip.sampleRate);
      player.set("out", [m.output], loaded.clip.sampleRate);
      setSide("out");
      break;
    }
    case "error":
      fail(m.message);
      return;
  }
  render();
};

function fail(message: string) {
  state.busy = null;
  state.error = message;
  render();
}

// ---------- actions ----------

async function open(file: File) {
  player.clear();
  Object.assign(state, {
    loaded: null, input: null, output: null, outputSamples: null, before: null, after: null, log: [],
    busy: "decoding", stale: false, error: "",
  });
  render();
  try {
    const loaded = await load(file);
    state.loaded = loaded;
    const mono = mix(loaded.clip.channels);
    state.input = spectrogram(mono, loaded.clip.sampleRate);
    player.set("in", loaded.clip.channels, loaded.clip.sampleRate);
    setSide("in");
    state.busy = "analyzing";
    send({ type: "analyze", sampleRate: loaded.clip.sampleRate, channels: loaded.clip.channels });
  } catch (error) {
    fail(error instanceof MediaError ? error.message : `couldn't read this file (${(error as Error).message})`);
  }
  render();
}

function cloak() {
  const loaded = state.loaded;
  if (!loaded || state.busy) return;
  state.error = "";
  state.busy = "loading";
  send({
    type: "scrub", sampleRate: loaded.clip.sampleRate, channels: loaded.clip.channels,
    steps: ["mono", ...OPTIONAL.filter((s) => state.steps.has(s))], seed: state.seed,
    cutoff: state.cutoff, keepVoice: state.keepVoice,
  });
  render();
}

async function download() {
  const { loaded, outputSamples } = state;
  if (!loaded || !outputSamples || state.busy) return;
  state.busy = "saving";
  render();
  try {
    const blob = await save(loaded, outputSamples, loaded.clip.sampleRate);
    const a = Object.assign(document.createElement("a"), { href: URL.createObjectURL(blob), download: outputName(loaded) });
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 30_000);
    state.busy = null;
  } catch (error) {
    fail(`saving failed: ${(error as Error).message}`);
  }
  render();
}

function setSide(side: Side) {
  if (side === "out" && !player.has("out") && state.loaded) return;
  player.switchTo(side);
  player.side = side;
  terrain.show = side;
  render();
}

function changed() {
  if (state.outputSamples) state.stale = true;
  render();
}

function togglePlay() {
  if (!state.loaded) return;
  if (player.playing) player.pause();
  else void player.play();
  render();
}

// ---------- rendering ----------

function renderConfig() {
  const ln = (n: number, body: string) => `<span class="inline-block w-7 text-neutral-600">${n}</span>${body}`;
  const steps = OPTIONAL.map((s) => {
    const on = state.steps.has(s);
    return `<span class="tok ${on ? "" : "text-neutral-600 line-through decoration-neutral-700"}" data-step="${s}" title="${STEP_INFO[s]}">"${s}"</span>`;
  }).join(", ");
  const name = state.loaded ? esc(state.loaded.name) : "drop a video";
  $("config").innerHTML = [
    ln(1, `<span class="text-neutral-500">// every band is a hiding place</span>`),
    ln(2, `<span class="text-white">const</span> camo = {`),
    ln(3, `  file: <span class="tok border-b border-dotted border-neutral-600" data-act="file">"${name}"</span>,`),
    ln(4, `  steps: [${steps}],`),
    ln(5, `  cutoff: <span class="num" data-act="cutoff" title="drag">${state.cutoff}</span>, <span class="text-neutral-500">// Hz</span>`),
    ln(6, `  keepVoice: <span class="tok border-b border-dotted border-neutral-600" data-act="voice">${state.keepVoice}</span>,`),
    ln(7, `  seed: <span class="tok border-b border-dotted border-neutral-600" data-act="seed" title="click for a new one">${state.seed}</span>,`),
    ln(8, `};`),
  ].join("\n");
}

function renderFlow() {
  const box = (label: string, sub: string, on: boolean, step?: Step) =>
    `<button ${step ? `data-step="${step}"` : "disabled"} class="flex min-w-0 flex-1 flex-col items-center justify-center border px-0.5 py-2 text-[9.5px] leading-tight ${
      on ? "border-accent text-accent" : step ? "border-neutral-700 text-neutral-500 hover:border-neutral-400" : "border-neutral-700 text-white"}">
      <span>${label}</span><span class="mt-0.5 text-[8px] ${on ? "text-accent/70" : "text-neutral-600"}">${sub}</span></button>`;
  const wire = `<span class="h-px w-2 shrink-0 bg-neutral-700"></span>`;
  const stages = OPTIONAL.filter((s) => s !== "wobble" || state.steps.has("wobble"));
  $("flow").innerHTML = `<div class="flex items-stretch">${[
    box("x(t)", "mic", false),
    ...stages.map((s) => box(s, s === "lowband" ? `fc ${formatHz(state.cutoff)}` : STEP_INFO[s].split(" ")[0]!, state.steps.has(s), s)),
    box("y(t)", "out", false),
  ].join(wire)}</div>
  <div class="mt-2 flex justify-between text-[9px] text-neutral-600"><span>· · · tap a stage to switch it</span>
  <span class="border border-dashed border-neutral-700 px-2 py-0.5 ${state.steps.has("lowband") ? "text-accent/80" : ""}">ñ · ERB noise</span></div>`;
}

function renderTrace() {
  const b = state.before, a = state.stale ? null : state.after;
  const rows: [string, keyof Trace, string][] = [
    ["long tones", "tones", "narrow tones it can follow"],
    ["doppler curves", "doppler", "pitch bends like a passing source"],
    ["mains hum", "hum", "a clock for the recording time"],
    ["flyby fits", "flybys", "solved speed + distance"],
  ];
  const max = Math.max(1, ...rows.map(([, k]) => b?.[k] ?? 0));
  $("trace").innerHTML = rows.map(([name, key, hint]) => {
    const vin = b?.[key], vout = a?.[key];
    const bar = (v: number | undefined, color: string) =>
      v === undefined ? "" : `<span class="absolute inset-y-0 left-0 ${color}" style="width:${(100 * v) / max}%"></span>`;
    return `<tr class="border-t border-neutral-900" title="${hint}">
      <td class="py-2.5 text-white">${name}</td>
      <td class="w-[38%] py-2.5"><span class="relative block h-[3px] bg-neutral-800">${bar(vin, "bg-neutral-500")}${bar(vout, "bg-accent")}</span></td>
      <td class="py-2.5 text-right tabular-nums text-white">${vin ?? "–"}${vout !== undefined ? ` → <span class="text-accent">${vout}</span>` : ""}</td></tr>`;
  }).join("");
  $("log").innerHTML = state.log.map((l) => `<li>${esc(l)}</li>`).join("") || "<li>no run yet</li>";

  const big = $("big"), sub = $("big-sub");
  if (a) { big.textContent = String(a.tones); big.className = big.className.replace("text-white", "text-accent"); }
  else { big.textContent = b ? String(b.tones) : "–"; big.className = big.className.replace("text-accent", "text-white"); }
  sub.textContent = a && b ? `was ${b.tones} · ${a.doppler} doppler curves · ${a.hum} hum lines` :
    b ? `${b.doppler} doppler curves · ${b.hum} hum lines` : "drop a clip to measure";
}

function renderStatus() {
  const s = state, status = $("status"), cloakButton = $<HTMLButtonElement>("cloak"), saveButton = $("save");
  const stageText: Record<string, string> = {
    decoding: "decoding audio…", loading: "loading the scrubber…", analyzing: "listening like an attacker…",
    scrubbing: "cloaking…", verifying: "checking what's left…", saving: "encoding the video…",
  };
  let text: string;
  if (s.error) text = `<span class="text-red-400">${esc(s.error)}</span>`;
  else if (s.busy) text = `<span class="text-accent">${stageText[s.busy]}</span>`;
  else if (!s.loaded) text = "drop a video · nothing leaves your browser";
  else if (s.after && !s.stale) {
    text = `<span class="text-accent">cloaked</span> · ${s.after.tones} trackable tone${s.after.tones === 1 ? "" : "s"} left (was ${s.before?.tones ?? "?"}) · ${(s.ms / 1000).toFixed(1)} s`;
  } else if (s.stale) text = "settings changed · cloak again to apply";
  else if (s.before) {
    const t = s.before;
    text = t.tones ? `exposed · ${t.tones} tone${t.tones === 1 ? "" : "s"} a tracker can follow${t.doppler ? `, ${t.doppler} bending like a passing source` : ""}`
      : "no trackable tones found · cloaking still hides fainter ones";
  } else text = "ready";
  status.innerHTML = text;
  cloakButton.disabled = !s.loaded || !!s.busy;
  cloakButton.textContent = s.after && s.stale ? "RE-CLOAK" : "CLOAK";
  saveButton.classList.toggle("hidden", !s.outputSamples || s.stale);
  (saveButton as HTMLButtonElement).disabled = !!s.busy;
  $("badge").textContent = !s.loaded ? "○ no clip" : s.after && !s.stale ? "● cloaked" : "○ exposed";
  $("engine").textContent = s.engine === "stand-in" ? "engine: dev stand-in (not a defense)" : "engine: swift → wasm";
}

function renderTransport() {
  const has = !!state.loaded;
  $("transport").classList.toggle("opacity-40", !has);
  $<HTMLButtonElement>("play").disabled = !has;
  $<HTMLInputElement>("seek").disabled = !has;
  $("play").textContent = player.playing ? "❚❚" : "▶";
  $("play").setAttribute("aria-label", player.playing ? "Pause" : "Play");
  const out = $<HTMLButtonElement>("side-out"), inn = $<HTMLButtonElement>("side-in");
  out.disabled = !player.has("out");
  for (const [b, side] of [[inn, "in"], [out, "out"]] as const) {
    const on = terrain.show === side;
    b.className = `px-3 py-1.5 ${on ? "bg-white text-black" : "text-neutral-400 disabled:text-neutral-700"}`;
    b.setAttribute("aria-pressed", String(on));
  }
  $("drop").classList.toggle("hidden", has || state.busy === "decoding");
  $("file-name").textContent = state.loaded
    ? `${state.loaded.name} · ${clock(state.loaded.duration)} · ${state.loaded.clip.sampleRate / 1000} kHz · ${state.loaded.video ? "video kept as is, audio replaced, metadata dropped" : "audio only"} · drop another to replace`
    : "";
  $("legend-main").textContent = terrain.show;
  $("legend-ghost").textContent = terrain.show === "in" ? "out" : "in";
}

function renderBands() {
  const input = state.input ?? demoData.input;
  const output = state.loaded ? (state.stale ? null : state.output) : demoData.output;
  $("bands").innerHTML = bandChart(input.centers, meanBands(input), output ? meanBands(output) : null, state.cutoff);
}

function renderFormula() {
  const on = OPTIONAL.filter((s) => state.steps.has(s));
  const chain = on.length ? [...on].reverse().map((s) => (s === "lowband" ? `lowband<sub>${formatHz(state.cutoff)}</sub>` : s)).join(" ∘ ") : "id";
  $("formula").innerHTML = `y = ${chain} (x)${state.steps.has("lowband") ? ` <span class="text-neutral-500">· below fc: noise matched to each ERB band${state.keepVoice ? " · voice harmonics kept" : ""}</span>` : ""}`;
}

function render() {
  renderConfig();
  renderFlow();
  renderTrace();
  renderStatus();
  renderTransport();
  renderBands();
  renderFormula();
  terrain.cutoff = state.cutoff;
  terrain.input = state.input ?? demoData.input;
  terrain.output = state.loaded ? state.output : demoData.output;
  const scale = state.input ?? demoData.input;
  terrain.range = [percentile(scale, 0.5), percentile(scale, 0.999) + 2];
}

// ---------- frame loop ----------

let lastClock = "";
function frame(now: number) {
  if (state.loaded) {
    terrain.time = player.time;
    const label = `${clock(player.time)} / ${clock(player.duration)}`;
    if (label !== lastClock) {
      lastClock = label;
      $("clock").textContent = label;
      const seek = $<HTMLInputElement>("seek");
      if (document.activeElement !== seek) seek.value = String(Math.round((1000 * player.time) / Math.max(player.duration, 1e-9)));
    }
  } else {
    terrain.time = (now / 1000) % (demoData.input.frames * demoData.input.hop);
  }
  terrain.draw(now);
  $("yaw").textContent = `yaw ${terrain.yawDegrees}°`;
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
player.onEnd = render;

// ---------- input ----------

$("config").addEventListener("click", (e) => {
  const el = (e.target as HTMLElement).closest<HTMLElement>("[data-step],[data-act]");
  if (!el) return;
  if (el.dataset.step) toggleStep(el.dataset.step as Step);
  else if (el.dataset.act === "voice") { state.keepVoice = !state.keepVoice; changed(); }
  else if (el.dataset.act === "seed") { state.seed = randomSeed(); changed(); }
  else if (el.dataset.act === "file") $("file").click();
});

$("flow").addEventListener("click", (e) => {
  const el = (e.target as HTMLElement).closest<HTMLElement>("[data-step]");
  if (el?.dataset.step) toggleStep(el.dataset.step as Step);
});

function toggleStep(step: Step) {
  if (!STEPS.includes(step)) return;
  if (state.steps.has(step)) state.steps.delete(step);
  else state.steps.add(step);
  changed();
}

// Drag the cutoff number horizontally (or use arrow keys while it's focused).
$("config").addEventListener("pointerdown", (e) => {
  const el = (e.target as HTMLElement).closest<HTMLElement>("[data-act=cutoff]");
  if (!el) return;
  e.preventDefault();
  const x0 = e.clientX, start = state.cutoff;
  const move = (ev: PointerEvent) => {
    const next = Math.round(Math.min(1_000, Math.max(100, start * 2 ** ((ev.clientX - x0) / 120))) / 10) * 10;
    if (next !== state.cutoff) { state.cutoff = next; changed(); }
  };
  const up = () => { window.removeEventListener("pointermove", move); window.removeEventListener("pointerup", up); };
  window.addEventListener("pointermove", move);
  window.addEventListener("pointerup", up);
});

$("cloak").addEventListener("click", cloak);
$("save").addEventListener("click", () => void download());
$("play").addEventListener("click", togglePlay);
$("side-in").addEventListener("click", () => setSide("in"));
$("side-out").addEventListener("click", () => setSide("out"));
$<HTMLInputElement>("seek").addEventListener("input", (e) => {
  player.seek((Number((e.target as HTMLInputElement).value) / 1000) * player.duration);
});
$<HTMLInputElement>("file").addEventListener("change", (e) => {
  const file = (e.target as HTMLInputElement).files?.[0];
  if (file) void open(file);
  (e.target as HTMLInputElement).value = "";
});

const veil = $("drag-veil");
let depth = 0;
window.addEventListener("dragenter", (e) => { e.preventDefault(); depth++; veil.classList.replace("hidden", "flex"); });
window.addEventListener("dragleave", () => { if (--depth <= 0) { depth = 0; veil.classList.replace("flex", "hidden"); } });
window.addEventListener("dragover", (e) => e.preventDefault());
window.addEventListener("drop", (e) => {
  e.preventDefault();
  depth = 0;
  veil.classList.replace("flex", "hidden");
  const file = e.dataTransfer?.files[0];
  if (file) void open(file);
});

window.addEventListener("keydown", (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey || /INPUT|TEXTAREA/.test((e.target as HTMLElement).tagName)) return;
  if (e.code === "Space") { e.preventDefault(); togglePlay(); }
  else if (e.key === "x") setSide(terrain.show === "in" ? "out" : "in");
  else if (e.key === "c") cloak();
});

render();
