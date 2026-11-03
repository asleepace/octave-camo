import { join } from "node:path";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { run } from "./clip.ts";

/** In-place iterative radix-2 complex FFT. */
export function fft(re: Float64Array, im: Float64Array): void {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      [re[i], re[j]] = [re[j]!, re[i]!];
      [im[i], im[j]] = [im[j]!, im[i]!];
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (-2 * Math.PI) / len;
    const wr = Math.cos(ang), wi = Math.sin(ang);
    for (let start = 0; start < n; start += len) {
      let cr = 1, ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const a = start + k, b = a + len / 2;
        const tr = cr * re[b]! - ci * im[b]!, ti = cr * im[b]! + ci * re[b]!;
        re[b] = re[a]! - tr; im[b] = im[a]! - ti;
        re[a] = re[a]! + tr; im[a] = im[a]! + ti;
        const ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
}

export function hann(n: number): Float64Array {
  const w = new Float64Array(n);
  for (let i = 0; i < n; i++) w[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (n - 1));
  return w;
}

export function median(values: ArrayLike<number>): number {
  const s = Float64Array.from(values).sort();
  const m = s.length >> 1;
  return s.length % 2 ? s[m]! : 0.5 * (s[m - 1]! + s[m]!);
}

/**
 * Decodes any audio/video file's first audio track to mono float samples at `sampleRate`.
 * Channels are averaged here: ffmpeg's own `-ac 1` downmix sums at 0.707 per channel, which
 * makes identical channels 3 dB louder (and can push the peak past full scale).
 */
export async function readMono(path: string, sampleRate: number): Promise<Float32Array> {
  const dir = await mkdtemp(join(tmpdir(), "octave-camo-pcm-"));
  try {
    const channels = Number((await run(["ffprobe", "-v", "error", "-select_streams", "a:0",
      "-show_entries", "stream=channels", "-of", "csv=p=0", path])).trim().split(/[\s,]+/)[0]) || 1;
    const raw = join(dir, "audio.f32");
    await run(["ffmpeg", "-loglevel", "error", "-y", "-i", path, "-map", "0:a:0", "-vn",
               "-ar", String(sampleRate), "-f", "f32le", raw]);
    const interleaved = new Float32Array(await Bun.file(raw).arrayBuffer());
    if (channels === 1) return interleaved;
    const out = new Float32Array(Math.floor(interleaved.length / channels));
    for (let i = 0; i < out.length; i++) {
      let s = 0;
      for (let c = 0; c < channels; c++) s += interleaved[i * channels + c]!;
      out[i] = s / channels;
    }
    return out;
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

/** Writes mono float samples to a 32-bit float WAV via ffmpeg. */
export async function writeMonoWav(path: string, x: Float32Array, sampleRate: number): Promise<void> {
  const dir = await mkdtemp(join(tmpdir(), "octave-camo-pcm-"));
  try {
    const raw = join(dir, "audio.f32");
    await Bun.write(raw, x);
    await run(["ffmpeg", "-loglevel", "error", "-y", "-f", "f32le", "-ar", String(sampleRate), "-ac", "1",
               "-i", raw, "-c:a", "pcm_f32le", path]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
