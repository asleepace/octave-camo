import "./style.css";
import { ALL_FORMATS, BlobSource, Input } from "mediabunny";
import { FLATTEN, type Step, type Trace } from "./engine/camo.ts";
import { PRESETS } from "./presets.ts";
import { type Request, type Stage, WorkerMessage } from "./engine/protocol.ts";
import workerUrl from "./engine/worker.ts?worker&url";
import { load, type Loaded, MediaError, outputName, prepareAudioEncoder, save } from "./media.ts";
import { Player, type Side } from "./player.ts";
import { bandCenters, demo, type Detail, detailPercentile, meanBands, percentile, type Spectrogram } from "./spectrum.ts";
import { bandChart } from "./ui/bands.ts";
import { Heatmap, rampCss, renderHeatmapAxes } from "./ui/heatmap.ts";
import { Terrain } from "./ui/terrain.ts";
import { archiveBytes, archiveFiles, concat, fromUtcField, looksLikeArchive, toUtcField } from "./tracks.ts";
import { measureProfiles, ROWS } from "./video.ts";

type FlickerScan = { detected: boolean; z: number; flickerHz: number; readoutMs: number; gains?: Float32Array<ArrayBuffer>; frames: number };
const toSpectrogram = (s: { db: Float32Array; frames: number; hop: number }): Spectrogram => ({ centers: bandCenters(), ...s });

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const clock = (t: number) => `${Math.floor(t / 60)}:${String(Math.floor(t % 60)).padStart(2, "0")}`;
/** A 52-bit seed from the platform's cryptographic generator (the noise and jitter must not be guessable). */
const randomSeed = () => {
  const [hi, lo] = crypto.getRandomValues(new Uint32Array(2));
  return (hi! & 0xfffff) * 2 ** 32 + lo! + 1;
};

const CUTOFF = 300;
/** Shortest clip the picture's flicker scan can judge. */
const MIN_PICTURE_SECONDS = 5;

/** Presets that cloak everything Full does (so the result isn't "partly" cloaked). */
const COMPLETE: readonly Preset[] = ["full", "experimental"];
type Preset = keyof typeof PRESETS;

const STEP_TEXT: Partial<Record<Step, [string, string]>> = {
  hum: ["Notch the mains hum", "Narrow filters at 50/60 Hz and their harmonics remove the grid's clock."],
  subtract: ["Cancel long tones", "Follows each clear tone below 1 kHz and subtracts a matched copy, pass after pass. Fainter tones, and any from 1 to 8 kHz, are counted and outlined on the spectrogram; Experimental fills them in (step 5)."],
  scurve: ["Hunt for flyby curves", "Tries every physically possible pass (speed, distance, timing), the way an attacker would, and cancels the ones that fit."],
  lowband: ["Regenerate the low end", `Below ${CUTOFF} Hz, where distant engines live, the sound is rebuilt as noise matching each hearing band's loudness. Voices are tracked and kept.`],
  lines: ["Fill in what the check still finds", "Every long tone the attacker model still finds, at any frequency up to 8 kHz (a jet's fan tone, a faint car tone, an electrical whine), is replaced along its path by a narrow strip of noise at the level beside it, then the check looks again. It removes held musical notes too."],
};

const state = {
  loaded: null as Loaded | null,
  input: null as Spectrogram | null,
  output: null as Spectrogram | null,
  /** The heatmap's finer spectrograms of the same audio. */
  inputDetail: null as Detail | null,
  outputDetail: null as Detail | null,
  outputSamples: null as Float32Array<ArrayBuffer> | null,
  before: null as Trace | null,
  after: null as Trace | null,
  /** The check on the last saved file's sound, decoded again (null until it's back). */
  saved: null as Trace | null,
  savedError: "",
  log: [] as string[],
  preset: "full" as Preset,
  /** Preset the current output was made with. */
  outputPreset: null as Preset | null,
  /** Preset of the cloak in progress (becomes outputPreset when its result arrives). */
  pendingPreset: null as Preset | null,
  busy: null as Stage | "decoding" | "saving" | null,
  /** "2/3" while a long clip is processed in parts. */
  busyPart: "",
  ms: 0,
  engine: "wasm" as "wasm" | "stand-in",
  error: "",
  /** Flight-track removal: where and when (from the file or typed in) and the archive dropped in. */
  tracks: {
    latitude: null as number | null,
    longitude: null as number | null,
    altitude: 0,
    /** Unix time of the audio's first sample, s. */
    time: null as number | null,
    /** What the file itself gave. */
    fromFile: { place: false, time: false },
    /** The archive files read, by name, kept to re-send when the place or time changes. */
    archives: [] as { name: string; bytes: Uint8Array }[],
    status: "none" as "none" | "reading" | "ready" | "error",
    summary: null as { nearby: number; passing: number; curves: number } | null,
    message: "",
    /** Use them in the next cloak. */
    on: false,
  },
  /** The tracks setting the current output was made with ("" = none), and the pending cloak's. */
  outputTracks: "",
  pendingTracks: "",
  /** The picture's flicker scan (mains clock in rolling-shutter bands). */
  picture: {
    status: "none" as "none" | "scanning" | "done" | "error" | "short" | "unchecked",
    progress: 0,
    scan: null as FlickerScan | null,
    /** Remove flicker on save (re-encodes the picture). On when flicker is found; the user can untick it. */
    fix: false,
    /** The same scan on the saved picture. */
    verify: null as { detected: boolean; z: number } | null,
    /** Codec of the last re-encoded picture. */
    codec: "",
    message: "",
    /** The check of the saved file failed (the clip's own scan is unaffected). */
    verifyError: "",
  },
};
/** Bumped per opened file, so a slow picture scan can't land on the next clip. */
let fileToken = 0;
/** SHA-256 of the wasm the worker compiled ("" for the dev stand-in, null until loaded). */
let engineHash: string | null = null;
/** Bumped per save, so a slow check of an earlier save can't describe a later one. */
let saveSeq = 0;

const demoData = demo();
/** The terrain for a silent video: flat. */
const quiet: Spectrogram = { centers: bandCenters(), hop: 0.05, frames: 1, db: new Float32Array(bandCenters().length).fill(-120) };
const player = new Player();
const terrain = new Terrain($<HTMLCanvasElement>("terrain"));
terrain.cutoff = CUTOFF;
const heatmap = new Heatmap($<HTMLCanvasElement>("spec"));
/** Whether the spectrogram outlines found tones (a per-viewer preference, remembered when possible). */
let showMarks = (() => { try { return localStorage.getItem("octave-camo:outlines") !== "hidden"; } catch { return true; } })();
/** The landing heatmap (an illustration), sent by the worker once at startup. */
let demoDetail: { input: Detail; output: Detail } | null = null;
// The worker holds the decoded audio, so it must be under the page's Content-Security-Policy. A
// worker loaded from its own URL takes its policy from its own HTTP response, and GitHub Pages
// sends none; one started from a blob: URL inherits the page's. So a one-line blob: module
// imports the real worker script.
const worker = new Worker(URL.createObjectURL(new Blob([`import ${JSON.stringify(new URL(workerUrl, location.href).href)};`],
  { type: "text/javascript" })), { type: "module", name: "octave-camo" });

/** A silent video: no sound to cloak, only the picture and metadata to handle. */
const silent = () => !!state.loaded && !state.loaded.clip;
/** What the button would save is ready: the cloaked audio for this preset, or (silent) the picture as is. */
const fresh = () => silent() || (!!state.outputSamples && state.outputPreset === state.preset && state.outputTracks === tracksKey());
/** What flight-track removal the next cloak would use ("" = none): changing it makes the output stale. */
const tracksKey = () => {
  const t = state.tracks;
  return t.on && t.status === "ready" ? `${t.archives.map((a) => a.name).join(",")}|${t.latitude}|${t.longitude}|${t.altitude}|${t.time}` : "";
};

// ---------- worker ----------

const send = (request: Request, transfer: Transferable[] = []) => worker.postMessage(request, transfer);

/** The worker can't answer any more (it failed to start or crashed): nothing may wait on it. */
let workerDead = "";
const killWorker = (message: string) => {
  workerDead = message;
  state.picture.status = state.picture.status === "scanning" ? "error" : state.picture.status;
  fail(message);
};
worker.onerror = (event) => { event.preventDefault(); killWorker("the scrubber stopped working; reload the page"); };
worker.onmessageerror = () => fail("the scrubber sent a message that couldn't be read");

worker.onmessage = (event) => {
  const parsed = WorkerMessage.safeParse(event.data);
  if (!parsed.success) return fail("unexpected message from the scrubber");
  const m = parsed.data;
  if (m.type === "demo") {
    demoDetail = { input: m.input, output: m.output };
    return render();
  }
  if (m.type === "engine") {
    engineHash = m.sha256;
    if (m.failed) return killWorker(m.failed);
    return render();
  }
  if (m.token !== fileToken) return;          // a reply about a file that's no longer open
  switch (m.type) {
    case "stage":
      state.busy = m.stage;
      state.busyPart = m.part && m.parts ? `${m.part}/${m.parts}` : "";
      break;
    case "analysis":
      state.before = m.trace;
      state.input = toSpectrogram(m.spectrum);
      state.inputDetail = m.detail;
      state.engine = m.engine;
      state.busy = null;
      break;
    case "result": {
      const clip = state.loaded?.clip;
      if (!clip) return;
      Object.assign(state, {
        busy: null, outputSamples: m.output, outputPreset: state.pendingPreset, outputTracks: state.pendingTracks, after: m.after, log: m.log, ms: m.ms,
        engine: m.engine, output: toSpectrogram(m.spectrum), outputDetail: m.detail,
      });
      player.set("out", [m.output], clip.sampleRate);
      setSide("out");
      break;
    }
    case "flicker":
      if (m.purpose === "clip") {
        if (!m.checked) {
          state.picture.status = "unchecked";
          state.picture.message = "the frame rate is too high, or there are too few frames, to check the picture for light flicker";
          break;
        }
        const frames = m.gains ? m.gains.length / ROWS : 0;
        if (m.detected && (!m.gains || !Number.isInteger(frames) || frames !== pendingScanFrames)) {
          state.picture.status = "error";
          state.picture.message = "the flicker scan returned the wrong number of frames";
          break;
        }
        state.picture.scan = { detected: m.detected, z: m.z, flickerHz: m.flickerHz, readoutMs: m.readoutMs, gains: m.gains, frames };
        state.picture.status = "done";
        state.picture.fix = m.detected;
      } else if (m.seq === saveSeq) {
        state.picture.verify = { detected: m.detected || !m.checked, z: m.z };
      }
      break;
    case "checked":
      if (m.seq === saveSeq) state.saved = m.trace;
      break;
    case "archive":
      Object.assign(state.tracks, { status: "ready", summary: { nearby: m.nearby, passing: m.passing, curves: m.curves }, message: "", on: m.passing > 0 });
      break;
    case "error":
      if (m.scope === "saved") {
        if (m.seq === saveSeq) state.savedError = m.message;
        break;
      }
      if (m.scope === "tracks") {
        Object.assign(state.tracks, { status: "error", message: m.message, summary: null, on: false });
        break;
      }
      if (m.scope === "picture" && m.purpose === "verify") {
        if (m.seq === saveSeq) state.picture.verifyError = m.message;
        break;
      }
      if (m.scope === "picture") {
        state.picture.status = "error";
        state.picture.message = m.message;
        break;
      }
      return fail(m.message);
  }
  render();
};

function fail(message: string) {
  state.busy = null;
  state.error = workerDead || message;
  render();
}

// ---------- actions ----------

async function open(file: File) {
  if (workerDead) return fail(workerDead);
  player.clear();
  Object.assign(state, {
    loaded: null, input: null, output: null, inputDetail: null, outputDetail: null, outputSamples: null, outputPreset: null, pendingPreset: null, before: null,
    after: null, saved: null, savedError: "", log: [], busy: "decoding", busyPart: "", error: "",
  });
  state.picture = { status: "none", progress: 0, scan: null, fix: false, verify: null, codec: "", message: "", verifyError: "" };
  state.tracks = { latitude: null, longitude: null, altitude: 0, time: null, fromFile: { place: false, time: false }, archives: [],
                   status: "none", summary: null, message: "", on: false };
  Object.assign(state, { outputTracks: "", pendingTracks: "" });
  const token = ++fileToken;
  render();
  try {
    const loaded = await load(file);
    if (token !== fileToken) return;           // another file was opened while this one decoded
    state.loaded = loaded;
    const r = loaded.recorded;
    if (r.latitude !== undefined && r.longitude !== undefined) {
      Object.assign(state.tracks, { latitude: r.latitude, longitude: r.longitude, altitude: r.altitude ?? 0 });
      state.tracks.fromFile.place = true;
    }
    if (r.time !== undefined) {
      state.tracks.time = r.time + loaded.audioStart;
      state.tracks.fromFile.time = true;
    }
    if (loaded.clip) {
      player.set("in", loaded.clip.channels, loaded.clip.sampleRate);
      setSide("in");
      state.busy = "analyzing";
      state.busyPart = "";
      send({ type: "analyze", token, sampleRate: loaded.clip.sampleRate, channels: loaded.clip.channels });
    } else {
      state.busy = null;
      state.input = quiet;
    }
    // The scan sums whole 4 s segments; a shorter picture can't be checked (and must not read as clean).
    if (loaded.video && loaded.videoDuration < MIN_PICTURE_SECONDS) state.picture.status = "short";
    else if (loaded.video) void scanPicture(loaded, token);
  } catch (error) {
    if (token !== fileToken) return;
    fail(error instanceof MediaError ? error.message : `couldn't read this file (${(error as Error).message})`);
  }
  render();
}

/** Frames in the profiles last sent for the clip scan (its gains must match). */
let pendingScanFrames = 0;

/** Measure row profiles (one decode pass) and ask the worker for flicker and removal gains. */
async function scanPicture(loaded: Loaded, token: number) {
  if (!loaded.video) return;
  state.picture.status = "scanning";
  render();
  try {
    let last = 0;
    const profiles = await measureProfiles(loaded.video, loaded.videoDuration, (f) => {
      if (token !== fileToken || f - last < 0.02) return;
      last = f;
      state.picture.progress = f;
      renderTrace();
      renderPrimary();
    });
    if (token !== fileToken) return;
    pendingScanFrames = profiles.frames;
    send({ type: "flicker", token, ...profiles, clean: true, purpose: "clip", seq: 0 }, [profiles.values.buffer, profiles.times.buffer]);
  } catch (error) {
    if (token !== fileToken) return;
    state.picture.status = "error";
    state.picture.message = (error as Error).message;
    render();
  }
}

/** Decode the saved file and scan its picture again: the check the "gone" in the table reports. */
/** The check again, on the saved file's sound decoded back: what gets posted, not what was encoded. */
async function checkSaved(blob: Blob, name: string, token: number, seq: number) {
  try {
    const decoded = await load(new File([blob], name, { type: blob.type }));
    if (token !== fileToken || seq !== saveSeq) return;
    if (!decoded.clip) throw new Error("the saved file has no sound");
    send({ type: "check", token, seq, sampleRate: decoded.clip.sampleRate, channels: decoded.clip.channels },
      decoded.clip.channels.map((c) => c.buffer));
  } catch (error) {
    if (token !== fileToken || seq !== saveSeq) return;
    state.savedError = (error as Error).message;
    render();
  }
}

async function verifyPicture(blob: Blob, token: number, seq: number) {
  try {
    const input = new Input({ source: new BlobSource(blob), formats: ALL_FORMATS });
    const video = await input.getPrimaryVideoTrack();
    if (!video) throw new Error("the saved file has no picture");
    const profiles = await measureProfiles(video, (await video.computeDuration()) - (await video.getFirstTimestamp()));
    if (token !== fileToken || seq !== saveSeq) return;
    send({ type: "flicker", token, ...profiles, clean: false, purpose: "verify", seq }, [profiles.values.buffer, profiles.times.buffer]);
  } catch (error) {
    if (token !== fileToken || seq !== saveSeq) return;
    state.picture.verifyError = (error as Error).message;
    render();
  }
}

/** Copying this picture also strips data embedded in its packets (SEI: H.264/HEVC only). */
const stripsEmbedded = () => state.loaded?.video?.codec === "avc" || state.loaded?.video?.codec === "hevc";

const fixingPicture = () => !!state.loaded?.video && state.picture.fix && !!state.picture.scan?.detected && !!state.picture.scan.gains;

function cloak() {
  const loaded = state.loaded;
  if (!loaded?.clip || state.busy || workerDead) return;
  // The old result no longer matches what will be saved: don't let it be played or drawn as "out".
  player.drop("out");
  setSide("in");
  // The previous output is no longer what the button would save: if this run fails, there must be
  // nothing left over to save under the new preset's name.
  Object.assign(state, { error: "", busy: "loading", busyPart: "", outputSamples: null, outputPreset: null, output: null, outputDetail: null, after: null,
    saved: null, savedError: "", pendingPreset: state.preset, pendingTracks: tracksKey() });
  try {
    send({
      type: "scrub", token: fileToken, sampleRate: loaded.clip.sampleRate, channels: loaded.clip.channels,
      steps: ["mono", ...PRESETS[state.preset].steps], seed: randomSeed(), cutoff: CUTOFF, keepVoice: true,
      flattenSeconds: FLATTEN[PRESETS[state.preset].flatten], tracks: tracksKey() !== "",
    });
  } catch (error) {
    return fail(`couldn't start the cloak (${(error as Error).message})`);
  }
  render();
}

// ---------- flight tracks ----------

/** An archive file by its name (adsb.lol's are "NN.bin.ttf"; saved copies may lose the ".ttf"). */
const isArchiveName = (name: string) => /\.bin(\.ttf)?$/i.test(name);

/** Read archive files the user downloaded and hand them to the engine with the place and time. */
async function addArchive(files: File[]) {
  const t = state.tracks;
  if (!state.loaded?.clip || state.busy || workerDead) return;
  Object.assign(t, { status: "reading", message: "", summary: null, on: false });
  render();
  const token = fileToken;
  try {
    const read: { name: string; bytes: Uint8Array }[] = [];
    for (const f of files) {
      const bytes = await archiveBytes(f);
      if (!looksLikeArchive(bytes)) throw new Error(`${f.name} isn't an adsb.lol half-hour archive (its globe_history/…/heatmap/NN.bin.ttf file)`);
      read.push({ name: f.name, bytes });
    }
    if (token !== fileToken) return;
    // Keep an earlier file for the other half hour of a clip that spans two; a file added again replaces itself.
    const names = new Set(read.map((r) => r.name));
    t.archives = [...t.archives.filter((a) => !names.has(a.name)), ...read].sort((a, b) => a.name.localeCompare(b.name));
    sendArchive();
  } catch (error) {
    if (token !== fileToken) return;
    Object.assign(t, { status: "error", message: (error as Error).message });
    render();
  }
}

/** (Re)send the archive with the current place and time; the worker answers with what it found. */
function sendArchive() {
  const t = state.tracks, loaded = state.loaded;
  if (!loaded?.clip || !t.archives.length) return;
  if (t.latitude === null || t.longitude === null || t.time === null) {
    Object.assign(t, { status: "error", message: "enter where and when the clip was recorded first", summary: null, on: false });
    return render();
  }
  Object.assign(t, { status: "reading", message: "", summary: null, on: false });
  const bytes = concat(t.archives.map((a) => a.bytes));
  send({ type: "archive", token: fileToken, bytes, latitude: t.latitude, longitude: t.longitude, altitude: t.altitude,
         start: t.time, duration: loaded.duration }, [bytes.buffer]);
  render();
}

function renderTracks() {
  const el = $("tracks"), t = state.tracks, loaded = state.loaded;
  const show = !!loaded?.clip;
  el.classList.toggle("hidden", !show);
  if (!show || !loaded) return;
  // Leave the fields alone while someone is typing in them.
  if (el.contains(document.activeElement) && document.activeElement?.tagName === "INPUT" && (document.activeElement as HTMLInputElement).type !== "file"
      && el.dataset.token === String(fileToken)) {
    const status = el.querySelector("[data-status]");
    if (status) status.innerHTML = tracksStatus();
    return;
  }
  if (el.dataset.token !== String(fileToken)) delete el.dataset.open;   // a new file starts collapsed
  el.dataset.token = String(fileToken);
  const known = t.latitude !== null && t.longitude !== null && t.time !== null;
  const links = known ? archiveFiles(t.time!, loaded.duration) : [];
  const from = t.fromFile.place && t.fromFile.time ? "from the video" : t.fromFile.place || t.fromFile.time ? "partly from the video" : "not in the video: enter them";
  const field = "h-8 border border-neutral-800 bg-black px-2 text-[11px] text-white focus:border-neutral-500 disabled:text-neutral-600";
  const disabled = state.busy ? "disabled" : "";
  // A button and a hidden body, not <details>: controls inside a closed <details> still count as
  // laid out, but can't take focus.
  const open = el.dataset.open ? el.dataset.open === "1" : t.status !== "none";
  el.innerHTML = `<div class="border border-neutral-800 px-4 py-3 text-[11px] leading-relaxed">
    <button id="tracks-toggle" type="button" aria-expanded="${open}" aria-controls="tracks-body" class="text-left text-white">
      <span aria-hidden="true" class="mr-1 text-neutral-500">${open ? "▾" : "▸"}</span>Remove what flight tracks predict
      <span class="text-neutral-500">· optional · ${t.on && t.status === "ready" ? `<span class="text-accent">on: ${t.summary?.passing} aircraft</span>` : "off"}</span></button>
    <div id="tracks-body" ${open ? "" : "hidden"}>
    <p class="mt-2 text-neutral-500">An attacker with the flight logs knows exactly which tones to look for. Given the same logs, the cloak runs that
      test first and fills in whatever it finds. The logs come from adsb.lol's public archive: one worldwide file per half hour, so downloading it
      tells adsb.lol the time, never the place. The place and time below stay in this browser.</p>
    <div class="mt-3 flex flex-wrap items-end gap-3">
      <label class="flex flex-col gap-1 text-neutral-500">recorded (UTC)<input id="tracks-time" type="datetime-local" step="1" class="${field}" value="${t.time !== null ? toUtcField(t.time) : ""}" ${disabled} /></label>
      <label class="flex flex-col gap-1 text-neutral-500">latitude<input id="tracks-lat" inputmode="decimal" class="${field} w-28" value="${t.latitude ?? ""}" placeholder="37.7749" ${disabled} /></label>
      <label class="flex flex-col gap-1 text-neutral-500">longitude<input id="tracks-lon" inputmode="decimal" class="${field} w-28" value="${t.longitude ?? ""}" placeholder="-122.4194" ${disabled} /></label>
      <span class="pb-2 text-neutral-500">${from}</span>
    </div>
    ${known ? `<ol class="mt-3 list-decimal space-y-1 pl-4 text-neutral-400">
      <li>Download the archive for ${links.length > 1 ? "these half hours" : "that half hour"} (about 25 MB each, the whole world):
        ${links.map((l) => `<a class="text-neutral-200 underline decoration-neutral-700 underline-offset-4 hover:text-white" href="${l.url}" download="${l.name}" rel="noreferrer">${esc(l.label)}</a>`).join(" and ")}</li>
      <li>Add ${links.length > 1 ? "them" : "it"} here:
        <label class="cursor-pointer text-neutral-200 underline decoration-neutral-700 underline-offset-4 hover:text-white">choose file${links.length > 1 ? "s" : ""}<input id="tracks-file" type="file" multiple class="sr-only" ${disabled} /></label>
        or drop ${links.length > 1 ? "them" : "it"} on the page.</li>
    </ol>` : ""}
    <p data-status class="mt-2">${tracksStatus()}</p>
    </div>
  </div>`;
  $("tracks-toggle").addEventListener("click", () => {
    el.dataset.open = open ? "0" : "1";
    render();
    $("tracks-toggle").focus();
  });
  const changed = () => {
    const time = fromUtcField($<HTMLInputElement>("tracks-time").value);
    const lat = Number($<HTMLInputElement>("tracks-lat").value.trim()), lon = Number($<HTMLInputElement>("tracks-lon").value.trim());
    const okLat = $<HTMLInputElement>("tracks-lat").value.trim() !== "" && Math.abs(lat) <= 90;
    const okLon = $<HTMLInputElement>("tracks-lon").value.trim() !== "" && Math.abs(lon) <= 180;
    Object.assign(t, { time, latitude: okLat ? lat : null, longitude: okLon ? lon : null });
    if (t.archives.length) sendArchive();
    else render();
  };
  for (const id of ["tracks-time", "tracks-lat", "tracks-lon"]) $(id).addEventListener("change", changed);
  el.querySelector<HTMLInputElement>("#tracks-file")?.addEventListener("change", (e) => {
    const input = e.target as HTMLInputElement, files = [...(input.files ?? [])];
    input.value = "";
    if (files.length) void addArchive(files);
  });
}

function tracksStatus(): string {
  const t = state.tracks;
  if (t.status === "reading") return "reading the archive…";
  if (t.status === "error") return `<span class="text-red-400">${esc(t.message)}</span>`;
  if (t.status === "ready" && t.summary) {
    const s = t.summary;
    const used = fresh() && state.outputTracks ? " · used in this cloak" : t.on ? " · used when you cloak" : "";
    return s.passing
      ? `<span class="text-accent">${s.passing} aircraft</span> passed within 15 km while this clip ran (${s.curves} predicted curves)${used}.
         <label class="ml-1 cursor-pointer"><input id="tracks-on" type="checkbox" class="mr-1 align-middle accent-[#ffd23f]" ${t.on ? "checked" : ""} ${state.busy ? "disabled" : ""} />use them</label>`
      : `no aircraft passed within 15 km while this clip ran (${s.nearby} within 40 km around it): nothing to remove.`;
  }
  if (state.tracks.latitude === null || state.tracks.longitude === null || state.tracks.time === null) return "the video doesn't say where or when it was recorded; enter both to use flight tracks.";
  return "";
}

/** The picture scan is still running: saving now would skip removing flicker it may yet find. */
const waitingForPicture = () => !!state.loaded?.video && state.picture.status === "scanning";

async function download() {
  const { loaded, outputSamples } = state;
  if (!loaded || (!outputSamples && loaded.clip) || state.busy || waitingForPicture()) return;
  state.busy = "saving";
  render();
  const token = fileToken, seq = ++saveSeq;
  try {
    const scan = state.picture.scan;
    const picture = fixingPicture() && scan?.gains ? { gains: scan.gains, frames: scan.frames } : undefined;
    state.picture.verify = null;
    state.picture.verifyError = "";
    state.saved = null;
    state.savedError = "";
    const saved = await save(loaded, loaded.clip ? outputSamples : null, loaded.clip?.sampleRate ?? 0, (f) => {
      saveProgress = f;
      renderPrimary();
    }, picture);
    saveProgress = 0;
    if (token !== fileToken) return;            // another file was opened meanwhile
    // Verify on the saved file itself (decoded again), not on what was fed to the encoder.
    if (picture && loaded.video) void verifyPicture(saved.blob, token, seq);
    const name = outputName(loaded);
    if (loaded.clip) void checkSaved(saved.blob, name, token, seq);
    state.picture.codec = saved.videoCodec ?? "";
    const blob = saved.blob;
    const a = Object.assign(document.createElement("a"), { href: URL.createObjectURL(blob), download: name });
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 30_000);
    state.busy = null;
  } catch (error) {
    saveProgress = 0;
    if (token !== fileToken) return;
    fail(`saving failed: ${(error as Error).message}`);
  }
  render();
}

let saveProgress = 0;

function primary() {
  if ($("cloak").getAttribute("aria-disabled") === "true") return;
  if (fresh()) void download();
  else cloak();
}

function setSide(side: Side) {
  if (side === "out" && state.loaded && !player.has("out")) return;
  player.switchTo(side);
  player.side = side;
  terrain.show = side;
  heatmap.show = side;
  render();
}

function togglePlay() {
  if (!state.loaded?.clip) return;
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
  const scanning = fresh() && !s.busy && waitingForPicture();
  // aria-disabled, not disabled: a disabled button drops keyboard focus to the page, so after
  // CLOAK a keyboard or screen-reader user would lose their place before SAVE. primary() ignores
  // presses while it's unavailable.
  button.setAttribute("aria-disabled", String(!s.loaded || !!s.busy || scanning || !!workerDead));
  button.textContent = s.busy === "saving" && saveProgress > 0 ? `ENCODING… ${Math.round(saveProgress * 100)}%`
    : s.busy ? stageText[s.busy]!.replace("…", s.busyPart && s.busy !== "saving" && s.busy !== "decoding" ? ` ${s.busyPart}…` : "…")
    : scanning ? `SCANNING PICTURE… ${Math.round(s.picture.progress * 100)}%`
    : fresh() ? "SAVE CLOAKED FILE" : "CLOAK";
  const ready = fresh() && !s.busy;
  for (const c of ["border-white", "text-white", "hover:bg-white"]) button.classList.toggle(c, !ready);
  for (const c of ["border-accent", "text-accent", "hover:bg-accent"]) button.classList.toggle(c, ready);

  let text: string;
  if (s.error) text = `<span class="text-red-400">${esc(s.error)}</span>`;
  else if (!s.loaded) text = s.busy ? "reading the file…" : "drop a video above · nothing leaves your browser";
  else if (silent()) text = `no sound to cloak · saving removes the metadata${stripsEmbedded() ? " and embedded data" : ""}`;
  else if (fresh() && s.after) {
    const word = s.preset === "full" ? "cloaked" : COMPLETE.includes(s.preset) ? `cloaked (${PRESETS[s.preset].label.toLowerCase()})`
      : `partly cloaked (${PRESETS[s.preset].label})`;
    text = `<span class="text-accent">${word}</span>${s.outputTracks ? " with flight tracks" : ""} · ${s.after.tones} trackable tone${s.after.tones === 1 ? "" : "s"} left (was ${s.before?.tones ?? "?"}) · ${(s.ms / 1000).toFixed(1)} s · press x to compare`;
  } else if (s.outputSamples) text = s.outputPreset !== s.preset ? `preset changed · cloak again to apply ${PRESETS[s.preset].label.toLowerCase()}`
    : "flight tracks changed · cloak again to apply them";
  else if (s.before) {
    const t = s.before;
    text = t.tones
      ? `exposed · ${t.tones} tone${t.tones === 1 ? "" : "s"} a tracker can follow${t.doppler ? `, ${t.doppler} bending like a passing source` : ""}`
      : "no trackable tones found · cloaking still hides fainter ones";
  } else text = s.busy ? "listening like an attacker…" : "";
  let html = `${text}${s.loaded && !s.error && !silent() ? ` <span class="text-neutral-500">· ${PRESETS[s.preset].note}</span>` : ""}`;
  const pic = s.picture;
  const warning = !s.loaded?.video ? ""
    : pic.status === "unchecked" ? pic.message
    : pic.status === "error" || pic.message ? `the picture wasn't checked for light flicker (${pic.message || "the scan failed"})`
    : pic.verifyError ? `the saved picture couldn't be checked again (${pic.verifyError}); the flicker scan of the clip still applies`
    : pic.status === "short" ? `the clip is too short (under ${MIN_PICTURE_SECONDS} s) to check the picture for light flicker`
    : pic.scan?.detected && !pic.fix && !pic.verify ? "light flicker found and kept: it can help date the recording (tick \"Remove light flicker\" above)"
    : "";
  for (const w of [warning, savedWarning()].filter(Boolean)) html += `<br><span class="text-amber-300/80"><span aria-hidden="true">⚠ </span>${esc(w)}</span>`;
  // A live region re-announces whenever it's rewritten: only touch it when the text changes.
  if (status.innerHTML !== html) status.innerHTML = html;
}

/** The saved file's sound, checked again: only worth a line when it differs, or couldn't be checked. */
function savedWarning(): string {
  const a = fresh() ? state.after : null, c = fresh() ? state.saved : null;
  if (state.savedError && fresh()) return `the saved file's sound couldn't be checked again (${state.savedError}); the check of the cloaked sound still applies`;
  if (!a || !c) return "";
  const more = c.tones - a.tones;
  return more > 0 ? `the saved file shows ${more} more long tone${more === 1 ? "" : "s"} than the cloaked sound (the encoder made ${more === 1 ? "it" : "them"}); see "saved" in the table` : "";
}

function renderTrace() {
  const b = state.before, a = fresh() ? state.after : null, c = fresh() ? state.saved : null;
  const rows: [string, Exclude<keyof Trace, "found">, string][] = [
    ["long tones", "tones", "narrow tones it can follow for seconds, 40 Hz–8 kHz"],
    ["doppler curves", "doppler", "pitch bends like a passing source"],
    ["mains hum", "hum", "a clock for the recording time"],
    ["flyby fits", "flybys", "solved speed and distance"],
  ];
  const max = Math.max(1, ...rows.flatMap(([, k]) => [b?.[k] ?? 0, a?.[k] ?? 0]));
  $("trace").innerHTML = rows.map(([name, key, hint]) => {
    const vin = b?.[key], vout = a?.[key];
    const bar = (v: number | undefined, color: string) =>
      v === undefined ? "" : `<span class="absolute inset-y-0 left-0 ${color}" style="width:${(100 * v) / max}%"></span>`;
    return `<tr class="border-t border-neutral-900">
      <td class="py-2.5"><span class="text-white">${name}</span><span class="block text-[10px] text-neutral-600">${hint}</span></td>
      <td class="w-[34%] py-2.5"><span class="relative block h-[3px] bg-neutral-800">${bar(vin, "bg-neutral-500")}${bar(vout, "bg-accent")}</span></td>
      <td class="whitespace-nowrap py-2.5 pl-3 text-right tabular-nums text-white">${vin ?? (silent() ? `<span class="text-neutral-500">no sound</span>` : "–")}${vout !== undefined ? ` → <span class="text-accent">${vout}</span>` : ""}${c ? savedCell(c[key], vout) : ""}</td></tr>`;
  }).join("");
  $("trace").insertAdjacentHTML("beforeend", pictureRow());
  $("log").innerHTML = state.log.map((l) => `<li>${esc(l)}</li>`).join("") || "<li>no run yet</li>";
}

/** The saved file's count next to the cloaked one: grey when the same, amber when the encoder added any. */
function savedCell(v: number, cloaked: number | undefined): string {
  const worse = cloaked !== undefined && v > cloaked;
  return ` <span class="${worse ? "text-amber-300" : "text-neutral-400"}" title="the saved file, decoded and checked again">· saved ${v}</span>`;
}

function pictureRow(): string {
  const p = state.picture, video = !!state.loaded?.video;
  let vin = "–", vout = "";
  if (state.loaded && !video) vin = "no picture";
  else if (p.status === "scanning") vin = `scanning ${Math.round(p.progress * 100)}%`;
  else if (p.status === "error") vin = `<span class="text-red-400">not checked</span>`;
  else if (p.status === "short") vin = `<span class="text-neutral-500">too short</span>`;
  else if (p.status === "unchecked") vin = `<span class="text-amber-300/80">not checkable</span>`;
  else if (p.scan) vin = p.scan.detected ? `${Math.round(p.scan.flickerHz)} Hz` : "none";
  if (p.verify) vout = p.verify.detected ? `<span class="text-red-400">left</span>` : `<span class="text-accent">gone</span>`;
  else if (p.scan?.detected && fresh()) vout = p.fix ? `<span class="text-neutral-500">on save</span>` : `<span class="text-amber-300/80">kept</span>`;
  return `<tr class="border-t border-neutral-900">
    <td class="py-2.5"><span class="text-white">light flicker</span><span class="block text-[10px] text-neutral-600">grid clock in the picture's row bands</span></td>
    <td class="w-[34%] py-2.5 text-[11px] text-neutral-500">${p.scan ? `z ${Math.round(p.scan.z)}${p.verify ? ` → ${Math.round(p.verify.z)}` : ""}` : ""}</td>
    <td class="whitespace-nowrap py-2.5 pl-3 text-right text-white">${vin}${vout ? ` → ${vout}` : ""}</td></tr>`;
}

function renderPicture() {
  const el = $("picture"), p = state.picture;
  const show = !!state.loaded?.video && !!p.scan?.detected;
  el.classList.toggle("hidden", !show);
  if (!show || !p.scan) return;
  el.innerHTML = `<label class="flex cursor-pointer items-start gap-3 border border-neutral-800 px-4 py-3 text-[11px] leading-relaxed hover:border-neutral-600">
    <input id="fix-picture" type="checkbox" class="mt-0.5 h-3.5 w-3.5 shrink-0 accent-[#ffd23f]" ${p.fix ? "checked" : ""} ${state.busy ? "disabled" : ""} />
    <span><span class="text-white">Remove light flicker</span>
    <span class="text-neutral-500">Lights in the shot flicker with the power grid, and the camera picked up faint bands that can help
    date the recording. Removing them re-encodes the video${p.codec ? ` (${p.codec.toUpperCase()})` : ""}, which is slower and can shift colors slightly.</span></span>
  </label>`;
  $<HTMLInputElement>("fix-picture").addEventListener("change", (e) => {
    state.picture.fix = (e.target as HTMLInputElement).checked;
    state.picture.verify = null;
    render();
  });
}

function renderTransport() {
  const has = !!state.loaded?.clip;
  $<HTMLButtonElement>("play").disabled = !has;
  $<HTMLInputElement>("seek").disabled = !has;
  $("play").textContent = player.playing ? "❚❚" : "▶";
  $("play").setAttribute("aria-label", player.playing ? "Pause" : "Play");
  const out = $<HTMLButtonElement>("side-out"), inn = $<HTMLButtonElement>("side-in");
  out.disabled = !!state.loaded && !player.has("out");
  for (const [b, side] of [[inn, "in"], [out, "out"]] as const) {
    const on = terrain.show === side;
    b.className = `px-3 py-1.5 ${on ? "bg-white text-black" : "text-neutral-400 disabled:text-neutral-600"}`;
    b.setAttribute("aria-pressed", String(on));
  }
  $("drop").classList.toggle("hidden", !!state.loaded || state.busy === "decoding");
  $("open-another").classList.toggle("hidden", !state.loaded || !!state.busy);
  $("file-name").textContent = state.loaded
    ? `${state.loaded.name} · ${clock(state.loaded.duration)} · ${state.loaded.clip ? `${state.loaded.clip.sampleRate / 1000} kHz` : "no sound"} · ${!state.loaded.video ? "audio only" : fixingPicture() ? "picture re-encoded without flicker" : `picture kept as is${stripsEmbedded() ? ", embedded data removed" : ""}`}${state.loaded.clip ? " · audio replaced" : ""} · metadata dropped`
    : "";
  $("legend-main").textContent = terrain.show;
  $("legend-ghost").textContent = terrain.show === "in" ? "out" : "in";
}

function renderBands() {
  const input = state.input ?? (state.loaded ? quiet : demoData.input);
  const output = state.loaded ? (fresh() ? state.output : null) : demoData.output;
  $("bands").innerHTML = bandChart(input.centers, meanBands(input), output ? meanBands(output) : null, CUTOFF);
}

function renderSteps() {
  const on = new Set<Step>(PRESETS[state.preset].steps);
  const flatten = FLATTEN[PRESETS[state.preset].flatten];
  const extra: Partial<Record<Step, string>> = flatten > 0
    ? { lowband: ` ${PRESETS[state.preset].label}: its loudness also loses every swell slower than ${flatten} s, so a plane's rise and fall can't be lined up with flight tracks; ${flatten >= 10 ? "speech, music and anything quicker keep their movement" : "thumps and doors stay"}.` } : {};
  $("steps-explained").innerHTML = (Object.entries(STEP_TEXT) as [Step, [string, string]][]).map(([step, [title, body0]], i) => [step, [title, body0 + (extra[step] ?? "")], i] as const).map(([step, [title, body], i]) =>
    `<li class="${on.has(step) ? "" : "text-neutral-500"}"><span class="${on.has(step) ? "text-neutral-200" : "text-neutral-400"}">${i + 1}. ${title}.</span> ${body}${on.has(step) ? "" : ` <span class="text-neutral-500">(off in ${PRESETS[state.preset].label})</span>`}</li>`,
  ).join("") + `<li class="${tracksKey() ? "" : "text-neutral-500"}"><span class="${tracksKey() ? "text-neutral-200" : "text-neutral-400"}">${Object.keys(STEP_TEXT).length + 1}. Remove what flight tracks predict (optional).</span> With adsb.lol's archive for the half hour and where the clip was recorded, each aircraft that passed within 15 km gets four predicted Doppler curves (its logged positions are a few seconds stale, so their shapes differ). Along each, the cloak runs the test an attacker holding the logs would: every rest frequency and a few seconds of timing slack, against the same curve at wrong times. Whatever stands out is filled with noise and tested again, until nothing does.</li>` + `<li class="${state.loaded && !state.loaded.video ? "text-neutral-500" : ""}"><span class="${state.loaded && !state.loaded.video ? "text-neutral-400" : "text-neutral-200"}">${Object.keys(STEP_TEXT).length + 2}. Remove light flicker (picture).</span> When the scan finds bands from flickering lights, each row is divided by its estimated band, which takes the grid clock out of the picture. On when bands are found (untick it to keep the picture untouched), since it re-encodes the video.</li>`;
}

const REPO = "https://github.com/asleepace/octave-camo";

/** Footer: version, commit, and the hash of the wasm actually running (compare with the release). */
function renderEngine() {
  const commit = __COMMIT__, short = commit.slice(0, 7);
  const commitLink = /^[0-9a-f]{40}$/.test(commit) ? `<a class="underline decoration-neutral-700 hover:text-neutral-300" href="${REPO}/commit/${commit}">${short}</a>` : esc(short);
  const engine = workerDead ? `<span class="text-red-400">engine: failed to load</span>`
    : state.engine === "stand-in" || engineHash === "" ? "engine: dev stand-in (not a defense)"
    : engineHash ? `engine sha256 <span id="engine-hash" class="inline-block max-w-[14ch] truncate select-all align-bottom" title="${engineHash}">${engineHash}</span>`
    : "engine: loading";
  $("engine").innerHTML = `v${esc(__VERSION__)} · ${commitLink} · ${engine} · <a class="underline decoration-neutral-700 hover:text-neutral-300" href="checksums.txt">checksums</a>`;
}

function render() {
  renderPrimary();
  renderPicture();
  renderTracks();
  renderTrace();
  renderTransport();
  renderBands();
  renderSteps();
  renderEngine();
  terrain.input = state.input ?? (state.loaded ? quiet : demoData.input);
  terrain.output = state.loaded ? state.output : demoData.output;
  const scale = state.input ?? (state.loaded ? quiet : demoData.input);
  terrain.range = [percentile(scale, 0.5), percentile(scale, 0.999) + 2];
  renderHeatmap();
}

/** The 2D spectrogram, its axes and its before/after control (which follows "listen to"). */
function renderHeatmap() {
  const example = !state.loaded;
  const input = example ? demoDetail?.input ?? null : state.inputDetail;
  const output = example ? demoDetail?.output ?? null : state.outputDetail;
  if (heatmap.input !== input) {
    // One color range for both sides, from the original: the toggle shows what changed.
    heatmap.range = input ? [detailPercentile(input, 0.05), detailPercentile(input, 0.999)] : heatmap.range;
  }
  heatmap.input = input;
  heatmap.output = output;
  const lowband = example || PRESETS[state.outputPreset ?? state.preset].steps.some((s) => s === "lowband");
  heatmap.cutoff = lowband ? CUTOFF : 0;
  $("spec-cutoff").textContent = lowband ? `┄ regenerated below ${CUTOFF} Hz` : "";
  $("spec-example").classList.toggle("hidden", !example);

  const hasOut = !!output;
  const out = $<HTMLButtonElement>("spec-out"), inn = $<HTMLButtonElement>("spec-in");
  out.disabled = !hasOut;
  const showing = hasOut ? heatmap.show : "in";
  for (const [b, side] of [[inn, "in"], [out, "out"]] as const) {
    const on = side === showing;
    b.className = `px-3 py-1.5 ${on ? "bg-white text-black" : "text-neutral-400 disabled:text-neutral-600"}`;
    b.setAttribute("aria-pressed", String(on));
  }

  const shown = heatmap.current;
  // Outline what the attacker model found: everything in the original, what's left after.
  const marks = example ? [] : shown === output ? state.after?.found ?? [] : state.before?.found ?? [];
  heatmap.marks = showMarks ? marks : [];
  const toggle = $("spec-marks");
  toggle.classList.toggle("hidden", !marks.length);
  toggle.setAttribute("aria-label", showMarks ? "Hide outlines" : "Show outlines");
  toggle.title = showMarks ? "Hide outlines" : "Show outlines";
  toggle.querySelector("[data-icon=hide]")!.classList.toggle("hidden", !showMarks);
  toggle.querySelector("[data-icon=show]")!.classList.toggle("hidden", showMarks);
  const outlined = showMarks ? " (outlined)" : "";
  heatmap.markStyle = shown === output ? "left" : "found";
  const silentClip = !!state.loaded && !state.loaded.clip;
  const tones = (n: number) => `${n} long tone${n === 1 ? "" : "s"}`;
  $("spec-note").textContent = silentClip ? "no sound in this video"
    : !shown ? (state.loaded ? "listening…" : "")
    : example ? (shown === output ? "plane and hum removed · voices kept" : "a passing plane · mains hum · voices")
    : shown === output ? (marks.length ? `cloaked · ${tones(marks.length)} a tracker can still follow${outlined}` : "cloaked · nothing left a tracker can follow")
    : marks.length ? `original · ${tones(marks.length)} found${outlined}` : "original";
  const what = shown === output ? "cloaked" : example ? "before cloaking" : "original";
  $("spec").setAttribute("aria-label", shown
    ? `Spectrogram${example ? " (example)" : ""}, ${what}: frequency from ${Math.round(shown.fLo)} Hz to ${(shown.fHi / 1000).toFixed(1)} kHz over ${clock(shown.seconds)}; brighter is louder.`
    : "Spectrogram: nothing to show yet");

  renderHeatmapAxes($("spec-y"), $("spec-x"), shown, clock);
  heatmap.draw();
}

// ---------- frame loop ----------

let lastClock = "";
/** With reduced motion, the demo terrain holds still (playback still moves it: the user asked). */
const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)");
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
  } else if (!reduceMotion.matches) {
    terrain.time = (now / 1000) % (demoData.input.frames * demoData.input.hop);
  }
  terrain.draw(now);
  heatmap.time = state.loaded?.clip ? player.time : null;
  heatmap.draw();
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
player.onEnd = render;
// Where the browser can't encode AAC itself, fetch the fallback encoder now rather than mid-save:
// the page should need no network once loaded.
void prepareAudioEncoder().catch(() => {});

// ---------- input ----------

const presetSelect = $<HTMLSelectElement>("preset");
presetSelect.innerHTML = (Object.entries(PRESETS) as [Preset, (typeof PRESETS)[Preset]][])
  .map(([key, p]) => `<option value="${key}">${p.label}</option>`).join("");
presetSelect.addEventListener("change", () => {
  state.preset = presetSelect.value as Preset;
  render();
});

$("cloak").addEventListener("click", primary);
$("tracks").addEventListener("change", (e) => {
  const target = e.target as HTMLInputElement;
  if (target.id !== "tracks-on") return;
  state.tracks.on = target.checked;
  render();
});
$("play").addEventListener("click", togglePlay);
$("side-in").addEventListener("click", () => setSide("in"));
$("side-out").addEventListener("click", () => setSide("out"));
$("spec-in").addEventListener("click", () => setSide("in"));
$("spec-out").addEventListener("click", () => setSide("out"));
$("spec-marks").addEventListener("click", () => {
  showMarks = !showMarks;
  try { localStorage.setItem("octave-camo:outlines", showMarks ? "shown" : "hidden"); } catch { /* private mode: not remembered */ }
  render();
});
$("spec-ramp").style.background = rampCss();
// Clicking the spectrogram seeks there (the slider above is the keyboard way to do the same).
$("spec").addEventListener("click", (e) => {
  if (!state.loaded?.clip) return;
  const box = (e.currentTarget as HTMLElement).getBoundingClientRect();
  player.seek(((e.clientX - box.left) / Math.max(1, box.width)) * player.duration);
});
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
  const files = [...(e.dataTransfer?.files ?? [])];
  if (files.length && state.loaded?.clip && files.every((f) => isArchiveName(f.name))) return void addArchive(files);
  if (files[0]) void open(files[0]);
});

window.addEventListener("keydown", (e) => {
  // Leave keys alone on controls (Space activates a focused button or summary, scrolls the page).
  if (e.metaKey || e.ctrlKey || e.altKey || /INPUT|TEXTAREA|SELECT|BUTTON|SUMMARY|^A$/.test((e.target as HTMLElement).tagName)) return;
  if (e.code === "Space" && state.loaded?.clip) { e.preventDefault(); togglePlay(); }
  else if (e.key === "x") setSide(terrain.show === "in" ? "out" : "in");
  else if (e.key === "c") primary();
});

render();
