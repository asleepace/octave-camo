/**
 * The 2D spectrogram: frequency (log, bottom to top) over time, loudness as color. Before and
 * after share one color range, so the toggle shows what changed rather than a rescale.
 */
import type { Detail } from "../spectrum.ts";

import type { Side } from "../player.ts";

/** Black → deep amber → the accent → white: one hue, rising lightness (readable with any color vision). */
export const RAMP: readonly [number, readonly [number, number, number]][] = [
  [0, [0, 0, 0]], [0.35, [48, 30, 6]], [0.6, [140, 90, 10]], [0.82, [255, 210, 63]], [1, [255, 250, 225]],
];

/** 256-entry RGB lookup for RAMP. */
export const LUT = (() => {
  const lut = new Uint8ClampedArray(256 * 3);
  for (let i = 0; i < 256; i++) {
    const x = i / 255;
    let k = 1;
    while (k < RAMP.length - 1 && x > RAMP[k]![0]) k++;
    const [a, ca] = RAMP[k - 1]!, [b, cb] = RAMP[k]!, u = Math.min(1, Math.max(0, (x - a) / (b - a)));
    for (let j = 0; j < 3; j++) lut[i * 3 + j] = ca[j]! + (cb[j]! - ca[j]!) * u;
  }
  return lut;
})();

export const rampCss = () => `linear-gradient(90deg, ${RAMP.map(([x, c]) => `rgb(${c.join(" ")}) ${x * 100}%`).join(", ")})`;

/** Paints a heatmap into RGBA pixels (columns × rows, top row = highest frequency). */
export function paint(d: Detail, range: readonly [number, number]): Uint8ClampedArray<ArrayBuffer> {
  const { columns, rows, db } = d, px = new Uint8ClampedArray(columns * rows * 4);
  const [lo, hi] = range, scale = 255 / Math.max(1e-6, hi - lo);
  for (let c = 0; c < columns; c++) {
    for (let r = 0; r < rows; r++) {
      const v = Math.max(0, Math.min(255, Math.round((db[c * rows + r]! - lo) * scale))) * 3;
      const i = ((rows - 1 - r) * columns + c) * 4;
      px[i] = LUT[v]!; px[i + 1] = LUT[v + 1]!; px[i + 2] = LUT[v + 2]!; px[i + 3] = 255;
    }
  }
  return px;
}

export class Heatmap {
  input: Detail | null = null;
  output: Detail | null = null;
  show: Side = "in";
  range: readonly [number, number] = [-100, -20];
  /** Playhead, seconds (null: none). */
  time: number | null = null;
  /** A frequency to mark with a dotted line (the regeneration cutoff), Hz. */
  cutoff = 0;

  private readonly ctx: CanvasRenderingContext2D;
  private cache = new Map<Side, { data: Detail; key: string; image: HTMLCanvasElement }>();
  private drawn = "";

  constructor(private readonly canvas: HTMLCanvasElement) {
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("2D canvas unavailable");
    this.ctx = ctx;
    new ResizeObserver(() => { this.drawn = ""; this.draw(); }).observe(canvas);
  }

  /** What's showing: the chosen side, or the input while there's no output yet. */
  get current(): Detail | null {
    return (this.show === "out" ? this.output : this.input) ?? this.input;
  }

  private image(side: Side, data: Detail): HTMLCanvasElement {
    const key = this.range.join(",");
    const hit = this.cache.get(side);
    if (hit && hit.data === data && hit.key === key) return hit.image;
    const image = hit?.image ?? document.createElement("canvas");
    image.width = data.columns;
    image.height = data.rows;
    image.getContext("2d")!.putImageData(new ImageData(paint(data, this.range), data.columns, data.rows), 0, 0);
    this.cache.set(side, { data, key, image });
    return image;
  }

  /** Redraws when anything visible changed (cheap to call every animation frame). */
  draw() {
    const { canvas, ctx } = this, dpr = window.devicePixelRatio || 1;
    const w = Math.max(1, Math.round(canvas.clientWidth * dpr)), h = Math.max(1, Math.round(canvas.clientHeight * dpr));
    const data = this.current, side = data === this.output ? "out" : "in";
    const playhead = data && this.time !== null ? Math.round((this.time / Math.max(data.seconds, 1e-9)) * w) : -1;
    const signature = `${w}x${h}|${side}|${this.range.join(",")}|${playhead}|${this.cutoff}|${data?.db.length ?? 0}`;
    if (signature === this.drawn && data && this.cache.get(side)?.data === data) return;
    this.drawn = signature;
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    ctx.fillStyle = "#000";
    ctx.fillRect(0, 0, w, h);
    if (!data) return;
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = "high";
    ctx.drawImage(this.image(side, data), 0, 0, w, h);
    if (this.cutoff > data.fLo && this.cutoff < data.fHi) {
      const y = Math.round(h * (1 - Math.log(this.cutoff / data.fLo) / Math.log(data.fHi / data.fLo))) + 0.5;
      ctx.strokeStyle = "rgba(255, 255, 255, 0.45)";
      ctx.lineWidth = 1;
      ctx.setLineDash([2 * dpr, 4 * dpr]);
      ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke();
      ctx.setLineDash([]);
    }
    if (playhead >= 0) {
      ctx.fillStyle = "rgba(255, 255, 255, 0.9)";
      ctx.fillRect(Math.min(w - dpr, playhead), 0, Math.max(1, Math.round(dpr)), h);
    }
  }
}

/** Evenly spaced, round time ticks (seconds) for a span. */
export function timeTicks(seconds: number, max = 6): number[] {
  if (!(seconds > 0)) return [0];
  const steps = [1, 2, 5, 10, 15, 20, 30, 60, 120, 300];
  const step = steps.find((s) => seconds / s <= max - 1) ?? 600;
  const ticks: number[] = [];
  for (let t = 0; t <= seconds + 1e-9; t += step) ticks.push(t);
  return ticks;
}
