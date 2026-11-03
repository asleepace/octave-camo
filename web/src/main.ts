import "./style.css";
import type { Step, Trace } from "./engine/camo.ts";
import { type Request, type Stage, WorkerMessage } from "./engine/protocol.ts";
import { load, type Loaded, MediaError, outputName, save } from "./media.ts";
import { Player, type Side } from "./player.ts";
import { demo, meanBands, mix, percentile, type Spectrogram, spectrogram } from "./spectrum.ts";
import { bandChart } from "./ui/bands.ts";
import { Terrain } from "./ui/terrain.ts";

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const clock = (t: number) => `${Math.floor(t / 60)}:${String(Math.floor(t % 60)).padStart(2, "0")}`;
const randomSeed = () => 1 + Math.floor(Math.random() * 2 ** 31);

const CUTOFF = 300;

const PRESETS = {
  full: { label: "Full", steps: ["hum", "subtract", "scurve", "lowband"], note: "planes, trains and ships" },
  light: { label: "Light", steps: ["hum", "lowband"], note: "faster; distant background only" },
  hum: { label: "Hum only", steps: ["hum"], note: "removes the recording-time clock only" },
} as const satisfies Record<string, { label: string; steps: readonly Step[]; note: string }>;
type Preset = keyof typeof PRESETS;

const STEP_TEXT: Partial<Record<Step, [string, string]>> = {
  hum: ["Notch the mains hum", "Narrow filters at 50/60 Hz and their harmonics remove the grid's clock."],
  subtract: ["Cancel long tones", "Follows each steady tone and subtracts a matched copy, pass after pass."],
  scurve: ["Hunt for flyby curves", "Tries every physically possible pass (speed, distance, timing), the way an attacker would, and cancels the ones that fit."],
  lowband: ["Regenerate the low end", `Below ${CUTOFF} Hz, where distant engines live, the sound is rebuilt as noise matching each hearing band's loudness. Voices are tracked and kept.`],
};

const state = {
  loaded: null as Loaded | null,
  input: null as Spectrogram | null,
  output: null as Spectrogram | null,
  outputSamples: null as Float32Array<ArrayBuffer> | null,
  before: null as Trace | null,
  after: null as Trace | null,
  log: [] as string[],
  preset: "full" as Preset,
  /** Preset the current output was made with. */
  outputPreset: null as Preset | null,
  busy: null as Stage | "decoding" | "saving" | null,
  ms: 0,
  engine: "wasm" as "wasm" | "stand-in",
  error: "",
};

const demoData = demo();
const player = new Player();
const terrain = new Terrain($<HTMLCanvasElement>("terrain"));
terrain.cutoff = CUTOFF;
const worker = new Worker(new URL("./engine/worker.ts", import.meta.url), { type: "module" });

const fresh = () => !!state.outputSamples && state.outputPreset === state.preset;

// ---------- worker ----------

const send = (request: Request) => worker.postMessage(request);

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
      Object.assign(state, {
        busy: null, outputSamples: m.output, after: m.after, log: m.log, ms: m.ms, engine: m.engine,
        output: spectrogram(m.output, loaded.clip.sampleRate),
      });
      player.set("out", [m.output], loaded.clip.sampleRate);
      setSide("out");
      break;
    }
    case "error":
      return fail(m.message);
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
    loaded: null, input: null, output: null, outputSamples: null, outputPreset: null, before: null, after: null,
    log: [], busy: "decoding", error: "",
  });
  render();
  try {
    const loaded = await load(file);
    state.loaded = loaded;
    state.input = spectrogram(mix(loaded.clip.channels), loaded.clip.sampleRate);
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
  state.outputPreset = state.preset;
  send({
    type: "scrub", sampleRate: loaded.clip.sampleRate, channels: loaded.clip.channels,
    steps: ["mono", ...PRESETS[state.preset].steps], seed: randomSeed(), cutoff: CUTOFF, keepVoice: true,
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

function primary() {
  if (fresh()) void download();
  else cloak();
}

function setSide(side: Side) {
  if (side === "out" && state.loaded && !player.has("out")) return;
  player.switchTo(side);
  player.side = side;
  terrain.show = side;
  render();
}

function togglePlay() {
  if (!state.loaded) return;
  if (player.playing) player.pause();
  else void player.play();
  render();
}

// ---------- rendering ----------

function renderPrimary() {
  const s = state, button = $<HTMLButtonElement>("cloak"), status = $("status");
  const stageText: Record<string, string> = {
    decoding: "DECODING…", loading: "LOADING…", analyzing: "LISTENING…", scrubbing: "CLOAKING…",
    verifying: "CHECKING…", saving: "ENCODING…",
  };
  button.disabled = !s.loaded || !!s.busy;
  button.textContent = s.busy ? stageText[s.busy]! : fresh() ? `SAVE ${s.loaded!.name.replace(/\.[^.]+$/, "")}.camo` : "CLOAK";
  const ready = fresh() && !s.busy;
  for (const c of ["border-white", "text-white", "hover:bg-white"]) button.classList.toggle(c, !ready);
  for (const c of ["border-accent", "text-accent", "hover:bg-accent"]) button.classList.toggle(c, ready);

  let text: string;
  if (s.error) text = `<span class="text-red-400">${esc(s.error)}</span>`;
  else if (!s.loaded) text = s.busy ? "reading the file…" : "drop a video above · nothing leaves your browser";
  else if (fresh() && s.after) {
    text = `<span class="text-accent">cloaked</span> · ${s.after.tones} trackable tone${s.after.tones === 1 ? "" : "s"} left (was ${s.before?.tones ?? "?"}) · ${(s.ms / 1000).toFixed(1)} s · press x to compare`;
  } else if (s.outputSamples) text = `preset changed · cloak again to apply ${PRESETS[s.preset].label.toLowerCase()}`;
  else if (s.before) {
    const t = s.before;
    text = t.tones
      ? `exposed · ${t.tones} tone${t.tones === 1 ? "" : "s"} a tracker can follow${t.doppler ? `, ${t.doppler} bending like a passing source` : ""}`
      : "no trackable tones found · cloaking still hides fainter ones";
  } else text = s.busy ? "listening like an attacker…" : "";
  status.innerHTML = `${text}${s.loaded && !s.error ? ` <span class="text-neutral-700">· ${PRESETS[s.preset].note}</span>` : ""}`;
}

function renderTrace() {
  const b = state.before, a = fresh() ? state.after : null;
  const rows: [string, keyof Trace, string][] = [
    ["long tones", "tones", "narrow tones it can follow for seconds"],
    ["doppler curves", "doppler", "pitch bends like a passing source"],
    ["mains hum", "hum", "a clock for the recording time"],
    ["flyby fits", "flybys", "solved speed and distance"],
  ];
  const max = Math.max(1, ...rows.map(([, k]) => b?.[k] ?? 0));
  $("trace").innerHTML = rows.map(([name, key, hint]) => {
    const vin = b?.[key], vout = a?.[key];
    const bar = (v: number | undefined, color: string) =>
      v === undefined ? "" : `<span class="absolute inset-y-0 left-0 ${color}" style="width:${(100 * v) / max}%"></span>`;
    return `<tr class="border-t border-neutral-900">
      <td class="py-2.5"><span class="text-white">${name}</span><span class="block text-[9px] text-neutral-600">${hint}</span></td>
      <td class="w-[34%] py-2.5"><span class="relative block h-[3px] bg-neutral-800">${bar(vin, "bg-neutral-500")}${bar(vout, "bg-accent")}</span></td>
      <td class="whitespace-nowrap py-2.5 pl-3 text-right tabular-nums text-white">${vin ?? "–"}${vout !== undefined ? ` → <span class="text-accent">${vout}</span>` : ""}</td></tr>`;
  }).join("");
  $("log").innerHTML = state.log.map((l) => `<li>${esc(l)}</li>`).join("") || "<li>no run yet</li>";
}

function renderTransport() {
  const has = !!state.loaded;
  $("transport").classList.toggle("opacity-40", !has);
  $<HTMLButtonElement>("play").disabled = !has;
  $<HTMLInputElement>("seek").disabled = !has;
  $("play").textContent = player.playing ? "❚❚" : "▶";
  $("play").setAttribute("aria-label", player.playing ? "Pause" : "Play");
  const out = $<HTMLButtonElement>("side-out"), inn = $<HTMLButtonElement>("side-in");
  out.disabled = has && !player.has("out");
  for (const [b, side] of [[inn, "in"], [out, "out"]] as const) {
    const on = terrain.show === side;
    b.className = `px-3 py-1.5 ${on ? "bg-white text-black" : "text-neutral-400 disabled:text-neutral-700"}`;
    b.setAttribute("aria-pressed", String(on));
  }
  $("drop").classList.toggle("hidden", has || state.busy === "decoding");
  $("file-name").textContent = state.loaded
    ? `${state.loaded.name} · ${clock(state.loaded.duration)} · ${state.loaded.clip.sampleRate / 1000} kHz · ${state.loaded.video ? "picture kept as is · audio replaced · metadata dropped" : "audio only"} · drop another file to replace`
    : "";
  $("legend-main").textContent = terrain.show;
  $("legend-ghost").textContent = terrain.show === "in" ? "out" : "in";
}

function renderBands() {
  const input = state.input ?? demoData.input;
  const output = state.loaded ? (fresh() ? state.output : null) : demoData.output;
  $("bands").innerHTML = bandChart(input.centers, meanBands(input), output ? meanBands(output) : null, CUTOFF);
}

function renderSteps() {
  const on = new Set<Step>(PRESETS[state.preset].steps);
  $("steps-explained").innerHTML = (Object.entries(STEP_TEXT) as [Step, [string, string]][]).map(([step, [title, body]], i) =>
    `<li class="${on.has(step) ? "" : "opacity-40"}"><span class="text-neutral-200">${i + 1}. ${title}.</span> ${body}${on.has(step) ? "" : ` <span class="text-neutral-600">(off in ${PRESETS[state.preset].label})</span>`}</li>`,
  ).join("");
}

function render() {
  renderPrimary();
  renderTrace();
  renderTransport();
  renderBands();
  renderSteps();
  $("engine").textContent = state.engine === "stand-in" ? "engine: dev stand-in (not a defense)" : "engine: swift → wasm";
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
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
player.onEnd = render;

// ---------- input ----------

const presetSelect = $<HTMLSelectElement>("preset");
presetSelect.innerHTML = (Object.entries(PRESETS) as [Preset, (typeof PRESETS)[Preset]][])
  .map(([key, p]) => `<option value="${key}">${p.label}</option>`).join("");
presetSelect.addEventListener("change", () => {
  state.preset = presetSelect.value as Preset;
  render();
});

$("cloak").addEventListener("click", primary);
$("play").addEventListener("click", togglePlay);
$("side-in").addEventListener("click", () => setSide("in"));
$("side-out").addEventListener("click", () => setSide("out"));
$<HTMLInputElement>("seek").addEventListener("input", (e) => {
  player.seek((Number((e.target as HTMLInputElement).value) / 1000) * player.duration);
});
$<HTMLInputElement>("file").addEventListener("change", (e) => {
  const input = e.target as HTMLInputElement, file = input.files?.[0];
  if (file) void open(file);
  input.value = "";
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
  if (e.metaKey || e.ctrlKey || e.altKey || /INPUT|TEXTAREA|SELECT/.test((e.target as HTMLElement).tagName)) return;
  if (e.code === "Space") { e.preventDefault(); togglePlay(); }
  else if (e.key === "x") setSide(terrain.show === "in" ? "out" : "in");
  else if (e.key === "c") primary();
});

render();
