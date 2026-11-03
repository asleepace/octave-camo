/**
 * Read a video's audio, and write the cloaked copy: the original video packets (no re-encode,
 * so no quality loss) minus any data embedded in them, a newly encoded AAC track, and none of
 * the source's metadata (GPS, device, timestamps live there).
 */
import {
  ALL_FORMATS, AudioSample, AudioSampleSink, AudioSampleSource, BlobSource, BufferTarget, canEncodeAudio,
  canEncodeVideo, EncodedPacketSink, EncodedVideoPacketSource, Input, type InputAudioTrack, type InputVideoTrack,
  Mp4OutputFormat, Output, VideoSample, VideoSampleSink, VideoSampleSource, type VideoCodec,
} from "mediabunny";
import type { Clip } from "./engine/camo.ts";
import { lengthSize, type NalCodec, stripSei, stripSeiFromConfig } from "./sei.ts";
import { GainRenderer, ROWS } from "./video.ts";

/** Clips longer than this are refused: the scrubber holds the whole clip in memory. */
export const MAX_SECONDS = 300;
/** Limits checked before decoding anything (a crafted file could otherwise claim anything). */
export const MAX_CHANNELS = 8;
export const MAX_SAMPLE_RATE = 192_000;
/** Audio is cloaked at this rate at most: higher rates only cost memory (AAC can't carry them anyway). */
export const MAX_WORKING_RATE = 48_000;
/** Inputs larger than this are refused (the output is built in memory). */
export const MAX_BYTES = 2 * 1024 ** 3;

export type Loaded = {
  name: string;
  /** Mono (the cloak's first step averages the channels anyway), at most MAX_WORKING_RATE. */
  clip: Clip;
  /** Channels in the original audio. */
  sourceChannels: number;
  duration: number;
  audioStart: number;
  audio: InputAudioTrack;
  video: InputVideoTrack | null;
  /** The picture's own length (it can differ from the audio's), s. */
  videoDuration: number;
  videoStart: number;
};

export class MediaError extends Error {}

export async function load(file: File): Promise<Loaded> {
  if (file.size === 0) throw new MediaError("the file is empty");
  if (file.size > MAX_BYTES) throw new MediaError(`the file is over ${MAX_BYTES / 1024 ** 3} GB`);
  const input = new Input({ source: new BlobSource(file), formats: ALL_FORMATS });
  let tracks: InputAudioTrack[];
  try {
    tracks = await input.getAudioTracks();
  } catch {
    throw new MediaError("this isn't a video or audio file this browser can read");
  }
  if (!tracks.length) throw new MediaError("no audio track: octave-camo cloaks a video's sound, and this file has none");
  // The primary track among those this browser can decode (an undecodable spatial or surround
  // track may outrank a plain one).
  const audio = await input.getPrimaryAudioTrack({ filter: (t) => t.canDecode() });
  if (!audio) throw new MediaError(`this browser can't decode ${tracks[0]!.codec ?? "this"} audio`);
  const video = await input.getPrimaryVideoTrack();

  const duration = await audio.computeDuration();
  if (duration > MAX_SECONDS) throw new MediaError(`clip is ${Math.round(duration)} s; the limit is ${MAX_SECONDS} s`);
  const videoDuration = video ? await video.computeDuration() : 0;
  if (videoDuration > MAX_SECONDS + 1) throw new MediaError(`the picture runs ${Math.round(videoDuration)} s; the limit is ${MAX_SECONDS} s`);
  const channelCount = audio.numberOfChannels;
  if (!(channelCount >= 1 && channelCount <= MAX_CHANNELS)) throw new MediaError(`unsupported channel count (${channelCount})`);
  if (!(audio.sampleRate >= 8_000 && audio.sampleRate <= MAX_SAMPLE_RATE)) throw new MediaError(`unsupported sample rate (${audio.sampleRate} Hz)`);

  // Decode straight to mono. The decoded rate is what matters (HE-AAC, for one, decodes at twice
  // the rate its track declares).
  let sampleRate = 0;
  let mono = new Float32Array(0);
  let frames = 0;
  let plane = new Float32Array(0);
  for await (const sample of new AudioSampleSink(audio).samples()) {
    try {
      if (!sampleRate) {
        sampleRate = sample.sampleRate;
        if (!(sampleRate >= 8_000 && sampleRate <= MAX_SAMPLE_RATE)) throw new MediaError(`unsupported sample rate (${sampleRate} Hz)`);
        mono = new Float32Array(Math.ceil((Math.min(duration, MAX_SECONDS) + 1) * sampleRate));
      } else if (sample.sampleRate !== sampleRate) {
        throw new MediaError("the audio changes sample rate partway through; that isn't supported");
      }
      const n = sample.numberOfFrames, decoded = sample.numberOfChannels;
      if (frames + n > (MAX_SECONDS + 1) * sampleRate) {
        throw new MediaError(`the audio runs past the ${MAX_SECONDS} s limit (its header said ${Math.round(duration)} s)`);
      }
      if (frames + n > mono.length) {
        const grown = new Float32Array(Math.max(frames + n, Math.ceil(mono.length * 1.5)));
        grown.set(mono.subarray(0, frames));
        mono = grown;
      }
      if (plane.length < n) plane = new Float32Array(n);
      const target = mono.subarray(frames, frames + n), scale = 1 / decoded;
      for (let ch = 0; ch < decoded; ch++) {
        sample.copyTo(plane, { planeIndex: ch, format: "f32-planar" });
        for (let i = 0; i < n; i++) target[i]! += plane[i]! * scale;
      }
      frames += n;
    } finally {
      sample.close();
    }
  }
  if (!frames) throw new MediaError("the audio track is empty");
  let samples = mono.slice(0, frames);
  if (sampleRate > MAX_WORKING_RATE) {
    samples = await resample(samples, sampleRate, MAX_WORKING_RATE);
    sampleRate = MAX_WORKING_RATE;
  }
  return {
    name: file.name, clip: { sampleRate, channels: [samples] }, sourceChannels: channelCount,
    duration: samples.length / sampleRate, audioStart: await audio.getFirstTimestamp(), audio, video,
    videoDuration, videoStart: video ? await video.getFirstTimestamp() : 0,
  };
}

/** Band-limited resampling by the browser's audio engine. */
async function resample(x: Float32Array<ArrayBuffer>, from: number, to: number): Promise<Float32Array<ArrayBuffer>> {
  const frames = Math.max(1, Math.round((x.length * to) / from));
  const context = new OfflineAudioContext(1, frames, to);
  const buffer = context.createBuffer(1, x.length, from);
  buffer.copyToChannel(x, 0);
  const source = context.createBufferSource();
  source.buffer = buffer;
  source.connect(context.destination);
  source.start();
  const rendered = await context.startRendering();
  return Float32Array.from(rendered.getChannelData(0));
}

/**
 * The cloaked file's name: neutral and random, never derived from the original. Phone and
 * screen-recording names carry the capture date and time (PXL_20261103_142233.mp4), and
 * messengers keep file names.
 */
export function outputName(loaded: Pick<Loaded, "video">, random: () => number = secureRandom): string {
  const id = Array.from({ length: 6 }, () => "abcdefghjkmnpqrstuvwxyz23456789"[Math.floor(random() * 31)]).join("");
  return `camo-${id}.${loaded.video ? "mp4" : "m4a"}`;
}

/** Uniform in [0, 1) from the platform's cryptographic generator. */
export function secureRandom(): number {
  return crypto.getRandomValues(new Uint32Array(1))[0]! / 2 ** 32;
}

/** Byte ranges of an MP4's top-level boxes other than `mdat`; null if it doesn't parse as boxes. */
function boxesOutsideMediaData(bytes: Uint8Array): [number, number][] | null {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength), ranges: [number, number][] = [];
  let i = 0;
  while (i < bytes.length) {
    if (i + 8 > bytes.length) return null;
    let size = view.getUint32(i);
    const type = String.fromCharCode(bytes[i + 4]!, bytes[i + 5]!, bytes[i + 6]!, bytes[i + 7]!);
    if (!/^[a-z0-9 ]{4}$/i.test(type)) return null;
    if (size === 1) {
      if (i + 16 > bytes.length) return null;
      size = Number(view.getBigUint64(i + 8));
    } else if (size === 0) size = bytes.length - i;
    if (size < 8 || i + size > bytes.length) return null;
    if (type !== "mdat") ranges.push([i, i + size]);
    i += size;
  }
  return ranges;
}

/**
 * Removes the muxer's name from the finished file: Mediabunny writes "MediabunnyVideoHandler" /
 * "MediabunnySoundHandler" as track handler names, and its versioned name as the compressor name
 * of a re-encoded video track. Those would mark the file as made with this tool. Handler names
 * become ffmpeg's ("VideoHandler", "SoundHandler", the most common in the wild); the compressor
 * name becomes empty. Same lengths, so no box sizes change. Only boxes outside the media data are
 * searched (faster, and never touches compressed media).
 */
export function neutralize<T extends Uint8Array>(bytes: T): T {
  for (const [from, to] of boxesOutsideMediaData(bytes) ?? [[0, bytes.length]]) neutralizeRange(bytes.subarray(from, to));
  return bytes;
}

function neutralizeRange(bytes: Uint8Array) {
  const enc = new TextEncoder();
  const replaceAll = (from: string, to: Uint8Array) => {
    const pattern = enc.encode(from);
    outer: for (let i = 0; i + pattern.length <= bytes.length; i++) {
      for (let j = 0; j < pattern.length; j++) if (bytes[i + j] !== pattern[j]) continue outer;
      bytes.set(to, i);
      i += pattern.length - 1;
    }
  };
  const padded = (s: string, length: number) => { const out = new Uint8Array(length); out.set(enc.encode(s)); return out; };
  replaceAll("MediabunnyVideoHandler", padded("VideoHandler", 22));
  replaceAll("MediabunnySoundHandler", padded("SoundHandler", 22));
  replaceAll("MediabunnyTextHandler", padded("TextHandler", 21));
  // Compressor name: a length byte, then the name ("Mediabunny v1.65.0"); clear both.
  const marker = enc.encode("Mediabunny v");
  outer2: for (let i = 1; i + marker.length <= bytes.length; i++) {
    for (let j = 0; j < marker.length; j++) if (bytes[i + j] !== marker[j]) continue outer2;
    const length = bytes[i - 1]!;
    if (length >= marker.length && length <= 31) bytes.fill(0, i - 1, i + length);
  }
}

/** Per-row gains that remove flicker: frames × ROWS, in presentation order (as VideoSampleSink yields). */
export type PictureFix = { gains: Float32Array; frames: number };

export type Saved = {
  blob: Blob;
  /** Codec the picture was re-encoded with (when a PictureFix was applied). */
  videoCodec?: VideoCodec;
};

/** First codec this browser can encode at the clip's size: HEVC, then H.264, VP9, AV1. */
async function pictureCodec(width: number, height: number, bitrate: number): Promise<VideoCodec> {
  for (const codec of ["hevc", "avc", "vp9", "av1"] as const) {
    if (await canEncodeVideo(codec, { width, height, bitrate })) return codec;
  }
  throw new MediaError("this browser can't encode video, so it can't remove flicker");
}

const AUDIO_BITRATE = 160_000;

export async function save(loaded: Loaded, mono: Float32Array, sampleRate: number,
                           onProgress: (fraction: number) => void = () => {}, picture?: PictureFix): Promise<Saved> {
  if (!(await canEncodeAudio("aac", { numberOfChannels: 1, sampleRate, bitrate: AUDIO_BITRATE }))) {
    // Firefox (and some others) can't encode AAC natively: fall back to a WASM build of FFmpeg's encoder.
    const { registerAacEncoder } = await import("@mediabunny/aac-encoder");
    registerAacEncoder();
  }

  const target = new BufferTarget();
  const output = new Output({ format: new Mp4OutputFormat({ fastStart: "in-memory" }), target });
  let renderer: GainRenderer | null = null;
  try {
    // No tags at all, and no creation time (Mediabunny writes "now" unless told not to).
    output.setMetadataTags({ creationTime: null });
    const { video } = loaded;
    // Timestamps start at 0: a source's absolute start (a recorder's clock, hours into a TS
    // stream) would otherwise carry over as an edit list.
    const origin = video ? Math.min(loaded.audioStart, loaded.videoStart) : loaded.audioStart;
    let videoSource: EncodedVideoPacketSource | null = null;
    let rendered: { source: VideoSampleSource; codec: VideoCodec } | null = null;
    if (video && picture) {
      // Re-encode the picture with flicker divided out, at about the original bitrate.
      const width = video.codedWidth, height = video.codedHeight;
      const stats = await video.computePacketStats(300).catch(() => null);
      const bitrate = Math.round(Math.min(25e6, Math.max(4e6, stats?.averageBitrate ?? 12e6)));
      const codec = await pictureCodec(width, height, bitrate);
      const source = new VideoSampleSource({ codec, bitrate });
      output.addVideoTrack(source, { rotation: video.rotation });
      rendered = { source, codec };
      renderer = new GainRenderer(width, height);
    } else if (video) {
      if (!video.codec) throw new MediaError("unsupported video codec");
      videoSource = new EncodedVideoPacketSource(video.codec);
      output.addVideoTrack(videoSource, { rotation: video.rotation });
    }
    const audioSource = new AudioSampleSource({ codec: "aac", bitrate: AUDIO_BITRATE });
    output.addAudioTrack(audioSource);
    await output.start();

    // Interleave by timestamp so neither track has to buffer the whole other one.
    const chunk = Math.round(sampleRate / 2);
    let written = 0;
    const audioTime = () => loaded.audioStart - origin + written / sampleRate;
    const writeAudioUntil = async (t: number) => {
      while (written < mono.length && audioTime() <= t) {
        const data = mono.slice(written, Math.min(written + chunk, mono.length));
        const sample = new AudioSample({ data, format: "f32-planar", numberOfChannels: 1, sampleRate, timestamp: audioTime() });
        await audioSource.add(sample);
        sample.close();
        written += data.length;
        onProgress(written / mono.length);
      }
    };

    if (video && rendered && renderer && picture) {
      let k = 0;
      for await (const sample of new VideoSampleSink(video).samples()) {
        await writeAudioUntil(sample.timestamp - origin);
        if (k >= picture.frames) {
          sample.close();
          throw new MediaError("the picture has more frames than were scanned; scan again before saving");
        }
        const frame = sample.toVideoFrame();
        try {
          const canvas = renderer.render(frame, picture.gains.subarray(k * ROWS, (k + 1) * ROWS));
          const out = new VideoSample(canvas, { timestamp: sample.timestamp - origin, duration: sample.duration });
          await rendered.source.add(out);
          out.close();
        } finally {
          frame.close();
          sample.close();
        }
        k++;
      }
      if (k !== picture.frames) throw new MediaError("the picture has fewer frames than were scanned; scan again before saving");
    } else if (video && videoSource) {
      const config = await video.getDecoderConfig();
      if (!config) throw new MediaError("could not read the video's codec configuration");
      const nal: NalCodec | null = video.codec === "avc" || video.codec === "hevc" ? video.codec : null;
      const description = config.description ? toBytes(config.description) : null;
      const prefix = nal && description ? lengthSize(nal, description) : null;
      const decoderConfig = nal && description ? { ...config, description: stripSeiFromConfig(nal, description) } : config;
      let first = true;
      for await (const packet of new EncodedPacketSink(video).packets()) {
        // A stream cut mid-GOP starts with frames that can't be decoded without what came before.
        if (first && packet.type !== "key") continue;
        await writeAudioUntil(packet.timestamp - origin);
        const data = nal ? stripSei(nal, packet.data, prefix) : packet.data;
        await videoSource.add(packet.clone({ data, timestamp: packet.timestamp - origin }), first ? { decoderConfig } : undefined);
        first = false;
      }
      if (first) throw new MediaError("the video has no keyframe to start from");
    }
    await writeAudioUntil(Infinity);
    await output.finalize();
    if (!target.buffer) throw new MediaError("encoding produced no output");
    const blob = new Blob([neutralize(new Uint8Array(target.buffer))], { type: video ? "video/mp4" : "audio/mp4" });
    return { blob, videoCodec: rendered?.codec };
  } catch (error) {
    await output.cancel().catch(() => {});
    throw error;
  } finally {
    renderer?.dispose();
  }
}

const toBytes = (source: AllowSharedBufferSource): Uint8Array =>
  source instanceof ArrayBuffer || source instanceof SharedArrayBuffer
    ? new Uint8Array(source)
    : new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
