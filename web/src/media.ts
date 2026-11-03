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
import type { Clip, Profiles } from "./engine/camo.ts";
import { GainRenderer, ProfileProbe, ROWS } from "./video.ts";

/** Clips longer than this are refused: the scrubber holds the whole clip in memory. */
export const MAX_SECONDS = 300;

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

  const channelCount = audio.numberOfChannels, sampleRate = audio.sampleRate;
  const parts: Float32Array[][] = Array.from({ length: channelCount }, () => []);
  let frames = 0;
  for await (const sample of new AudioSampleSink(audio).samples()) {
    for (let ch = 0; ch < channelCount; ch++) {
      const plane = new Float32Array(sample.numberOfFrames);
      sample.copyTo(plane, { planeIndex: Math.min(ch, sample.numberOfChannels - 1), format: "f32-planar" });
      parts[ch]!.push(plane);
    }
    frames += sample.numberOfFrames;
    sample.close();
  }
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

/** The cloaked file's name: IMG_1234.mov → IMG_1234.camo.mp4 (or .m4a without video). */
export function outputName(loaded: Loaded): string {
  const stem = loaded.name.replace(/\.[^.]+$/, "") || "clip";
  return `${stem}.camo.${loaded.video ? "mp4" : "m4a"}`;
}

/** Per-row gains that remove flicker: frames × ROWS, in decode order. */
export type PictureFix = { gains: Float32Array; frames: number };

export type Saved = {
  blob: Blob;
  /** Row profiles of the re-rendered picture (when a PictureFix was applied), to verify it. */
  profiles?: Profiles;
  /** Codec the picture was re-encoded with. */
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

  let probe: ProfileProbe | undefined;
  if (video && rendered && picture) {
    probe = new ProfileProbe();
    let k = 0;
    for await (const sample of new VideoSampleSink(video).samples()) {
      await writeAudioUntil(sample.timestamp);
      const frame = sample.toVideoFrame();
      try {
        const row = Math.min(k, picture.frames - 1);
        const canvas = rendered.renderer.render(frame, picture.gains.subarray(row * ROWS, (row + 1) * ROWS));
        probe.add(canvas, sample.timestamp);
        const out = new VideoSample(canvas, { timestamp: sample.timestamp, duration: sample.duration });
        await rendered.source.add(out);
        out.close();
      } finally {
        frame.close();
        sample.close();
      }
      k++;
    }
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
  const blob = new Blob([target.buffer], { type: video ? "video/mp4" : "audio/mp4" });
  return { blob, profiles: probe?.result(), videoCodec: rendered?.codec };
}
