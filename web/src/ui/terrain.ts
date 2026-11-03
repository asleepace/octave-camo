/**
 * Spectral terrain: the last couple of seconds of spectrum as stacked ridgelines in a
 * perspective view (newest in front), drawn on a 2D canvas. Drag to orbit.
 */
import type { Side } from "../player.ts";
import { logX, type Spectrogram } from "../spectrum.ts";

const ROWS = 40;
const OCTAVES = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
const ACCENT = "#ffd23f";
const clamp = (v: number, a: number, b: number) => Math.max(a, Math.min(b, v));
export const formatHz = (f: number) =>
  f >= 1000 ? `${(Math.round(f / 100) / 10).toString().replace(/\.0$/, "")}k` : String(Math.round(f));

export class Terrain {
  input: Spectrogram | null = null;
  output: Spectrogram | null = null;
  show: Side = "in";
  time = 0;
  cutoff = 300;
  /** dB mapped to the floor and the top of the view. */
  range: [number, number] = [-80, -20];

  private yaw = -0.35;
  private pitch = 0.5;
  private dragging = false;
  private readonly compact: boolean;

  constructor(private readonly canvas: HTMLCanvasElement, options: { compact?: boolean } = {}) {
    this.compact = !!options.compact;
    canvas.addEventListener("pointerdown", this.orbit);
    canvas.style.touchAction = "none";
  }

  private orbit = (e: PointerEvent) => {
    e.preventDefault();
    const x0 = e.clientX, y0 = e.clientY, yaw0 = this.yaw, pitch0 = this.pitch;
    this.dragging = true;
    const move = (ev: PointerEvent) => {
      this.yaw = clamp(yaw0 + (ev.clientX - x0) * 0.006, -1.4, 1.4);
      this.pitch = clamp(pitch0 + (ev.clientY - y0) * 0.004, 0.15, 1.2);
    };
    const up = () => {
      this.dragging = false;
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  };

  get yawDegrees() { return Math.round((this.yaw * 180) / Math.PI); }

  draw(now: number) {
    const cv = this.canvas, dpr = window.devicePixelRatio || 1, W = cv.clientWidth, H = cv.clientHeight;
    if (!W || !H) return;
    if (cv.width !== Math.round(W * dpr) || cv.height !== Math.round(H * dpr)) {
      cv.width = Math.round(W * dpr);
      cv.height = Math.round(H * dpr);
    }
    const g = cv.getContext("2d")!;
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, W, H);
    if (!this.dragging) this.yaw += (-0.35 - this.yaw) * 0.004 + 0.0012 * Math.sin(now / 4000);

    const surface = this.show === "out" && this.output ? this.output : this.input;
    if (!surface) return;
    const ghost = surface === this.output ? this.input : this.output;

    // Projection: yaw about the vertical axis, then pitch, then perspective.
    const cy = Math.cos(this.yaw), sy = Math.sin(this.yaw), cp = Math.cos(this.pitch), sp = Math.sin(this.pitch);
    const FOC = 2.6, DEPTH = 1.5, YM = 0.5;
    const p0 = (x: number, y: number, z: number): [number, number] => {
      const X = x * cy - z * sy, Z = x * sy + z * cy;
      const Y2 = y * cp + Z * sp, Z2 = Z * cp - y * sp, s = FOC / (FOC + Z2 + 0.4);
      return [X * s, -Y2 * s];
    };
    let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
    for (const x of [-1, 1]) for (const y of [0, YM * 1.4]) for (const z of [-DEPTH / 2 - 0.1, DEPTH / 2]) {
      const [px, py] = p0(x, y, z);
      x0 = Math.min(x0, px); x1 = Math.max(x1, px); y0 = Math.min(y0, py); y1 = Math.max(y1, py);
    }
    const pad = this.compact ? 8 : 28, S = Math.min((W - 2 * pad) / (x1 - x0), (H - 2 * pad) / (y1 - y0));
    const ox = W / 2 - (S * (x0 + x1)) / 2, oy = H / 2 - (S * (y0 + y1)) / 2;
    const pr = (x: number, y: number, z: number): [number, number] => {
      const [px, py] = p0(x, y, z);
      return [ox + px * S, oy + py * S];
    };
    const [floor, top] = this.range;
    const hy = (d: number) => clamp((d - floor) / (top - floor), 0, 1) * YM;
    const line = (pts: [number, number][]) => {
      g.beginPath();
      pts.forEach(([x, y], i) => (i ? g.lineTo(x, y) : g.moveTo(x, y)));
    };

    // Ground grid.
    g.lineWidth = 1;
    g.strokeStyle = "#262626";
    g.setLineDash([2, 5]);
    for (let j = 0; j <= 4; j++) {
      const z = -DEPTH / 2 + (DEPTH * j) / 4, x = -1 + j / 2;
      line([pr(-1, 0, z), pr(1, 0, z)]); g.stroke();
      line([pr(x, 0, -DEPTH / 2), pr(x, 0, DEPTH / 2)]); g.stroke();
    }
    g.setLineDash([]);

    const B = surface.centers.length;
    const xs = Array.from(surface.centers, (f) => logX(f) * 2 - 1);
    const newest = Math.floor(this.time / surface.hop);
    const row = (s: Spectrogram, frame: number) => {
      const f = clamp(frame, 0, s.frames - 1);
      return s.db.subarray(f * B, (f + 1) * B);
    };

    for (let r = ROWS - 1; r >= 0; r--) {
      const frame = newest - r;
      if (frame < 0) continue;
      const z = -DEPTH / 2 + (DEPTH * r) / (ROWS - 1), age = r / (ROWS - 1);
      const vals = row(surface, frame);
      const pts = xs.map((x, b) => pr(x, hy(vals[b]!), z));
      // Fill under the line so rows behind are hidden.
      line([pr(-1, 0, z), ...pts, pr(1, 0, z)]);
      g.closePath();
      g.fillStyle = "#000";
      g.fill();
      line(pts);
      const cr = Math.round(255 - 165 * age), cg = Math.round(210 - 130 * age), cb = Math.round(63 - 3 * age);
      g.strokeStyle = r === 0 ? ACCENT : `rgba(${cr},${cg},${cb},${(0.85 - 0.45 * age).toFixed(3)})`;
      g.lineWidth = r === 0 ? 2 : 1.1;
      g.stroke();

      if (r === 0) {
        if (ghost) {
          const other = row(ghost, frame);
          line(xs.map((x, b) => pr(x, hy(other[b]!), z)));
          g.strokeStyle = "rgba(255,255,255,0.45)";
          g.lineWidth = 1;
          g.setLineDash([3, 3]);
          g.stroke();
          g.setLineDash([]);
        }
        this.labelPeaks(g, vals, xs, pts, z, pr, hy, surface.centers, YM);
      }
    }

    // Cutoff marker.
    const xc = logX(this.cutoff) * 2 - 1;
    g.strokeStyle = "rgba(255,210,63,0.45)";
    g.setLineDash([2, 4]);
    line([pr(xc, 0, -DEPTH / 2), pr(xc, 0, DEPTH / 2)]);
    g.stroke();
    g.setLineDash([]);

    if (!this.compact) {
      g.fillStyle = "#666";
      g.font = "10px 'JetBrains Mono', monospace";
      g.textAlign = "center";
      for (const f of OCTAVES) {
        const [px, py] = pr(logX(f) * 2 - 1, 0, -DEPTH / 2 - 0.08);
        g.fillText(formatHz(f), px, py + 12);
      }
      const [cx, cyy] = pr(xc, 0, DEPTH / 2 + 0.02);
      g.fillStyle = "rgba(255,210,63,0.7)";
      g.fillText(`fc ${formatHz(this.cutoff)}`, cx, cyy - 6);
    }
  }

  /** Mark the strongest ridges in the front row: what a tracker would lock on to. */
  private labelPeaks(g: CanvasRenderingContext2D, vals: Float32Array, xs: number[], pts: [number, number][], z: number,
                     pr: (x: number, y: number, z: number) => [number, number], hy: (d: number) => number,
                     centers: Float64Array, YM: number) {
    const peaks: number[] = [];
    for (let q = 2; q < vals.length - 2; q++) {
      if (vals[q]! >= vals[q - 1]! && vals[q]! > vals[q + 1]! && hy(vals[q]!) > YM * 0.35) peaks.push(q);
    }
    peaks.sort((a, b) => vals[b]! - vals[a]!);
    const big = !this.compact;
    peaks.slice(0, 3).forEach((q, i) => {
      const [bx, by] = pts[q]!, tp = pr(xs[q]!, YM * 1.32, z), alpha = i ? 0.45 : 1;
      g.strokeStyle = `rgba(255,210,63,${alpha})`;
      g.fillStyle = `rgba(255,210,63,${alpha})`;
      g.lineWidth = i ? 1 : 1.5;
      g.beginPath();
      g.moveTo(bx, by - 4);
      g.lineTo(tp[0], tp[1] + (i ? 8 : big ? 24 : 18));
      g.stroke();
      if (i === 0) {
        const label = `${formatHz(centers[q]!)} Hz`;
        g.font = `500 ${big ? 12 : 10}px 'JetBrains Mono', monospace`;
        const tw = g.measureText(label).width + 14, th = big ? 20 : 16;
        g.beginPath();
        g.roundRect(tp[0] - tw / 2, tp[1] + 4 - th / 2, tw, th, 4);
        g.fill();
        g.fillStyle = "#000";
        g.textAlign = "center";
        g.textBaseline = "middle";
        g.fillText(label, tp[0], tp[1] + 4);
        g.textBaseline = "alphabetic";
      } else {
        g.beginPath();
        g.arc(tp[0], tp[1], 3, 0, Math.PI * 2);
        g.fill();
      }
    });
  }
}
