/**
 * Read a video's audio, and write the cloaked copy: the original video packets (no re-encode,
 * so no quality loss), a newly encoded AAC track, and none of the source's metadata (GPS,
 * device, timestamps live there).
 */
import {
  ALL_FORMATS, AudioSample, AudioSampleSink, AudioSampleSource, BlobSource, BufferTarget, canEncodeAudio,
  canEncodeVideo, EncodedPacketSink, EncodedVideoPacketSource, Input, type InputAudioTrack, type InputVideoTrack,
  Mp4OutputFormat, Output, VideoSample, VideoSampleSink, VideoSampleSource, type VideoCodec,
} from "mediabunny";
import type { Clip } from "./engine/camo.ts";
import { GainRenderer, ROWS } from "./video.ts";

/** Clips longer than this are refused: the scrubber holds the whole clip in memory. */
export const MAX_SECONDS = 300;
/** Limits checked before decoding anything (a crafted file could otherwise claim anything). */
export const MAX_CHANNELS = 8;
export const MAX_SAMPLE_RATE = 192_000;

export type Loaded = {
  name: string;
  clip: Clip;
  duration: number;
  audioStart: number;
  audio: InputAudioTrack;
  video: InputVideoTrack | null;
};

export class MediaError extends Error {}

export async function load(file: File): Promise<Loaded> {
  const input = new Input({ source: new BlobSource(file), formats: ALL_FORMATS });
  const audio = await input.getPrimaryAudioTrack().catch(() => null);
  if (!audio) throw new MediaError("no audio track found (or the format isn't supported)");
  if (!(await audio.canDecode())) throw new MediaError(`this browser can't decode ${audio.codec ?? "this"} audio`);
  const video = await input.getPrimaryVideoTrack();

  const duration = await audio.computeDuration();
  if (duration > MAX_SECONDS) throw new MediaError(`clip is ${Math.round(duration)} s; the limit is ${MAX_SECONDS} s`);
  const channelCount = audio.numberOfChannels;
  if (!(channelCount >= 1 && channelCount <= MAX_CHANNELS)) throw new MediaError(`unsupported channel count (${channelCount})`);
  if (!(audio.sampleRate >= 8_000 && audio.sampleRate <= MAX_SAMPLE_RATE)) throw new MediaError(`unsupported sample rate (${audio.sampleRate} Hz)`);

  // The decoded rate is what matters (HE-AAC, for one, decodes at twice the rate its track declares).
  let sampleRate = 0;
  const parts: Float32Array[][] = Array.from({ length: channelCount }, () => []);
  let frames = 0;
  for await (const sample of new AudioSampleSink(audio).samples()) {
    if (!sampleRate) {
      sampleRate = sample.sampleRate;
      if (!(sampleRate >= 8_000 && sampleRate <= MAX_SAMPLE_RATE)) throw new MediaError(`unsupported sample rate (${sampleRate} Hz)`);
    } else if (sample.sampleRate !== sampleRate) {
      sample.close();
      throw new MediaError("the audio changes sample rate partway through; that isn't supported");
    }
    if (frames + sample.numberOfFrames > (MAX_SECONDS + 1) * sampleRate) {
      sample.close();
      throw new MediaError(`the audio runs past the ${MAX_SECONDS} s limit (its header said ${Math.round(duration)} s)`);
    }
    for (let ch = 0; ch < channelCount; ch++) {
      const plane = new Float32Array(sample.numberOfFrames);
      sample.copyTo(plane, { planeIndex: Math.min(ch, sample.numberOfChannels - 1), format: "f32-planar" });
      parts[ch]!.push(plane);
    }
    frames += sample.numberOfFrames;
    sample.close();
  }
  if (!frames) throw new MediaError("the audio track is empty");
  const channels = parts.map((list) => {
    const out = new Float32Array(frames);
    let offset = 0;
    for (const p of list) { out.set(p, offset); offset += p.length; }
    return out;
  });
  return {
    name: file.name, clip: { sampleRate, channels }, duration: frames / sampleRate,
    audioStart: await audio.getFirstTimestamp(), audio, video,
  };
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

/**
 * Removes the muxer's name from the finished file: Mediabunny writes "MediabunnyVideoHandler" /
 * "MediabunnySoundHandler" as track handler names, and its versioned name as the compressor name
 * of a re-encoded video track. Those would mark the file as made with this tool. Handler names
 * become ffmpeg's ("VideoHandler", "SoundHandler", the most common in the wild); the compressor
 * name becomes empty. Same lengths, so no box sizes change.
 */
export function neutralize<T extends Uint8Array>(bytes: T): T {
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
  return bytes;
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

export async function save(loaded: Loaded, mono: Float32Array, sampleRate: number,
                           onProgress: (fraction: number) => void = () => {}, picture?: PictureFix): Promise<Saved> {
  if (!(await canEncodeAudio("aac", { numberOfChannels: 1, sampleRate }))) {
    // Firefox (and some others) can't encode AAC natively: fall back to a WASM build of FFmpeg's encoder.
    const { registerAacEncoder } = await import("@mediabunny/aac-encoder");
    registerAacEncoder();
  }

  const target = new BufferTarget();
  const output = new Output({ format: new Mp4OutputFormat({ fastStart: "in-memory" }), target });
  // No tags at all, and no creation time (Mediabunny writes "now" unless told not to).
  output.setMetadataTags({ creationTime: null });
  const { video } = loaded;
  let videoSource: EncodedVideoPacketSource | null = null;
  let rendered: { source: VideoSampleSource; renderer: GainRenderer; codec: VideoCodec } | null = null;
  if (video && picture) {
    // Re-encode the picture with flicker divided out, at about the original bitrate.
    const width = video.codedWidth, height = video.codedHeight;
    const stats = await video.computePacketStats(300).catch(() => null);
    const bitrate = Math.round(Math.min(25e6, Math.max(4e6, stats?.averageBitrate ?? 12e6)));
    const codec = await pictureCodec(width, height, bitrate);
    const source = new VideoSampleSource({ codec, bitrate });
    output.addVideoTrack(source, { rotation: video.rotation });
    rendered = { source, renderer: new GainRenderer(width, height), codec };
  } else if (video) {
    if (!video.codec) throw new MediaError("unsupported video codec");
    videoSource = new EncodedVideoPacketSource(video.codec);
    output.addVideoTrack(videoSource, { rotation: video.rotation });
  }
  const audioSource = new AudioSampleSource({ codec: "aac", bitrate: 160_000 });
  output.addAudioTrack(audioSource);
  await output.start();

  // Interleave by timestamp so neither track has to buffer the whole other one.
  const chunk = Math.round(sampleRate / 2);
  let written = 0;
  const audioTime = () => loaded.audioStart + written / sampleRate;
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

  if (video && rendered && picture) {
    let k = 0;
    for await (const sample of new VideoSampleSink(video).samples()) {
      await writeAudioUntil(sample.timestamp);
      if (k >= picture.frames) {
        sample.close();
        throw new MediaError("the picture has more frames than were scanned; scan again before saving");
      }
      const frame = sample.toVideoFrame();
      try {
        const row = k;
        const canvas = rendered.renderer.render(frame, picture.gains.subarray(row * ROWS, (row + 1) * ROWS));
        const out = new VideoSample(canvas, { timestamp: sample.timestamp, duration: sample.duration });
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
    const decoderConfig = await video.getDecoderConfig();
    if (!decoderConfig) throw new MediaError("could not read the video's codec configuration");
    let first = true;
    for await (const packet of new EncodedPacketSink(video).packets()) {
      await writeAudioUntil(packet.timestamp);
      await videoSource.add(packet, first ? { decoderConfig } : undefined);
      first = false;
    }
  }
  await writeAudioUntil(Infinity);
  await output.finalize();
  if (!target.buffer) throw new MediaError("encoding produced no output");
  const blob = new Blob([neutralize(new Uint8Array(target.buffer))], { type: video ? "video/mp4" : "audio/mp4" });
  return { blob, videoCodec: rendered?.codec };
}
