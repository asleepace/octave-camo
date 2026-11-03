/**
 * The picture side of the cloak: measure row profiles for the flicker scan, and re-render frames
 * with per-row gains that divide the flicker out.
 *
 * Rolling-shutter bands follow the sensor's rows, so everything here works on the coded frame
 * (VideoFrame, before rotation metadata is applied); the output keeps the rotation as metadata.
 */
import { type InputVideoTrack, VideoSampleSink } from "mediabunny";
import type { Profiles } from "./engine/camo.ts";

export const STRIPS = 6;
export const ROWS = 120;
/** Probe canvas: STRIPS × ROWS cells, each averaged from a small block (16 × 2 px). */
const PROBE_W = STRIPS * 16, PROBE_H = ROWS * 2;

/** Accumulates per-frame row profiles (log luma per strip and row band). */
export class ProfileProbe {
  private readonly ctx: OffscreenCanvasRenderingContext2D;
  private values = new Float32Array(STRIPS * ROWS * 64);
  private times: number[] = [];

  constructor() {
    const canvas = new OffscreenCanvas(PROBE_W, PROBE_H);
    // Not willReadFrequently: that keeps the canvas on the CPU, so every full-size frame would be
    // read back before scaling. On the GPU only the small probe image is read back.
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("2D canvas unavailable");
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = "high";
    this.ctx = ctx;
  }

  add(source: CanvasImageSource, time: number) {
    this.ctx.drawImage(source, 0, 0, PROBE_W, PROBE_H);
    const px = this.ctx.getImageData(0, 0, PROBE_W, PROBE_H).data;
    const cells = STRIPS * ROWS, base = this.times.length * cells;
    if (base + cells > this.values.length) {
      const grown = new Float32Array(this.values.length * 2);
      grown.set(this.values);
      this.values = grown;
    }
    for (let s = 0; s < STRIPS; s++) {
      for (let r = 0; r < ROWS; r++) {
        let sum = 0;
        for (let dy = 0; dy < 2; dy++) {
          const row = (r * 2 + dy) * PROBE_W;
          for (let dx = 0; dx < 16; dx++) {
            const i = (row + s * 16 + dx) * 4;
            sum += 0.2126 * px[i]! + 0.7152 * px[i + 1]! + 0.0722 * px[i + 2]!;
          }
        }
        this.values[base + s * ROWS + r] = Math.log(sum / 32 / 255 + 1 / 255);
      }
    }
    this.times.push(time);
  }

  get frames() { return this.times.length; }

  /** Values in [frame][strip][row] order. */
  result(): Profiles {
    const frames = this.times.length, out = this.values.slice(0, frames * STRIPS * ROWS);
    return { frames, strips: STRIPS, rows: ROWS, values: out, times: Float32Array.from(this.times) };
  }
}

/** Decode every frame once and measure its row profile. */
export async function measureProfiles(video: InputVideoTrack, duration: number,
                                      onProgress: (fraction: number) => void = () => {}): Promise<Profiles> {
  const probe = new ProfileProbe();
  // Times relative to the first frame: a stream can start hours in, and float32 times that far
  // out lose the precision the scan's phase search needs.
  let first: number | null = null;
  for await (const sample of new VideoSampleSink(video).samples()) {
    first ??= sample.timestamp;
    const t = sample.timestamp - first;
    const frame = sample.toVideoFrame();
    try {
      probe.add(frame, t);
    } finally {
      frame.close();
      sample.close();
    }
    if (probe.frames % 15 === 0) onProgress(Math.min(1, t / Math.max(duration, 1e-9)));
  }
  onProgress(1);
  return probe.result();
}

const VERTEX = `#version 300 es
in vec2 position;
out vec2 uv;
void main() {
  uv = vec2(position.x * 0.5 + 0.5, 0.5 - position.y * 0.5);
  gl_Position = vec4(position, 0.0, 1.0);
}`;

const FRAGMENT = `#version 300 es
precision highp float;
uniform sampler2D frame;
uniform float gains[${ROWS}];
in vec2 uv;
out vec4 color;
void main() {
  // Row band centers sit at (r + 0.5) / ROWS; interpolate between neighbors.
  float y = clamp(uv.y * ${ROWS}.0 - 0.5, 0.0, ${ROWS - 1}.0);
  int r0 = int(floor(y));
  int r1 = min(r0 + 1, ${ROWS - 1});
  float g = mix(gains[r0], gains[r1], y - float(r0));
  vec4 c = texture(frame, uv);
  color = vec4(clamp(c.rgb * g, 0.0, 1.0), 1.0);
}`;

/** Multiplies each row of a frame by its gain, on the GPU (no 8-bit rounding of the gain). */
export class GainRenderer {
  readonly canvas: OffscreenCanvas;
  private readonly gl: WebGL2RenderingContext;
  private readonly gainsLocation: WebGLUniformLocation;
  private readonly texture: WebGLTexture;
  private scratch: OffscreenCanvasRenderingContext2D | null = null;

  constructor(width: number, height: number) {
    this.canvas = new OffscreenCanvas(width, height);
    const gl = this.canvas.getContext("webgl2", { premultipliedAlpha: false, preserveDrawingBuffer: true });
    if (!gl) throw new Error("WebGL2 is needed to remove flicker");
    this.gl = gl;
    const compile = (type: number, source: string) => {
      const shader = gl.createShader(type)!;
      gl.shaderSource(shader, source);
      gl.compileShader(shader);
      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader) ?? "shader error");
      return shader;
    };
    const program = gl.createProgram()!;
    gl.attachShader(program, compile(gl.VERTEX_SHADER, VERTEX));
    gl.attachShader(program, compile(gl.FRAGMENT_SHADER, FRAGMENT));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program) ?? "link error");
    gl.useProgram(program);

    const buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    const position = gl.getAttribLocation(program, "position");
    gl.enableVertexAttribArray(position);
    gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);

    this.texture = gl.createTexture()!;
    gl.bindTexture(gl.TEXTURE_2D, this.texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.uniform1i(gl.getUniformLocation(program, "frame"), 0);
    this.gainsLocation = gl.getUniformLocation(program, "gains[0]")!;
    gl.viewport(0, 0, width, height);
  }

  /** Releases the GPU context now rather than whenever the garbage collector gets to it. */
  dispose() {
    this.gl.getExtension("WEBGL_lose_context")?.loseContext();
  }

  render(frame: VideoFrame, gains: Float32Array): OffscreenCanvas {
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.texture);
    try {
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, frame);
    } catch {
      // Some browsers can't upload a VideoFrame directly: go through a 2D canvas.
      this.scratch ??= new OffscreenCanvas(this.canvas.width, this.canvas.height).getContext("2d");
      if (!this.scratch) throw new Error("2D canvas unavailable");
      this.scratch.drawImage(frame, 0, 0, this.canvas.width, this.canvas.height);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, this.scratch.canvas);
    }
    gl.uniform1fv(this.gainsLocation, gains);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    return this.canvas;
  }
}
