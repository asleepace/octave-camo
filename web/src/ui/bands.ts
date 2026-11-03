/** Long-term spectrum, original vs cloaked, on a log axis with the lowband cutoff marked. */
import { logX } from "../spectrum.ts";
import { formatHz } from "./terrain.ts";

// Sized for about half the page width, so 10-unit text renders near 10 px.
const W = 560, H = 220;
const TICKS = [31.5, 125, 500, 2000, 8000];

function smoothPath(pts: [number, number][]): string {
  if (!pts.length) return "";
  let d = `M${pts[0]![0].toFixed(1)},${pts[0]![1].toFixed(1)}`;
  for (let i = 0; i < pts.length - 1; i++) {
    const p0 = pts[i - 1] ?? pts[i]!, p1 = pts[i]!, p2 = pts[i + 1]!, p3 = pts[i + 2] ?? p2;
    const c1 = [p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6];
    const c2 = [p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6];
    d += ` C${c1[0]!.toFixed(1)},${c1[1]!.toFixed(1)} ${c2[0]!.toFixed(1)},${c2[1]!.toFixed(1)} ${p2[0].toFixed(1)},${p2[1].toFixed(1)}`;
  }
  return d;
}

export function bandChart(centers: Float64Array, input: Float32Array, output: Float32Array | null,
                          cutoff: number, compact = false): string {
  const all = [...input, ...(output ?? [])];
  const top = Math.ceil((Math.max(...all) + 3) / 10) * 10, floor = top - 70;
  const y = (d: number) => (Math.min(1, Math.max(0, (top - d) / (top - floor))) * H);
  const curve = (vals: Float32Array) => smoothPath(Array.from(vals, (d, i) => [logX(centers[i]!) * W, y(d)]));
  const xc = logX(cutoff) * W;
  const grid = [0, 1, 2].map((k) => {
    const d = top - k * 30, yy = y(d);
    return `<line x1="0" x2="${W}" y1="${yy}" y2="${yy}" stroke="#1f1f1f" stroke-dasharray="2 6"/>
      <text x="-10" y="${yy + 3}" text-anchor="end" class="fill-neutral-600" font-size="10">${d}</text>`;
  }).join("");
  const ticks = TICKS.map((f) => `<text x="${logX(f) * W}" y="${H + 18}" text-anchor="middle" class="fill-neutral-500" font-size="10">${formatHz(f)}</text>`).join("");
  const out = output ? curve(output) : "";
  return `<svg viewBox="-34 -22 ${W + 40} ${H + 44}" class="w-full h-auto overflow-visible font-mono" role="img"
      aria-label="Average level per frequency band, original${output ? " and cloaked" : ""}">
    ${compact ? "" : grid}
    <line x1="0" x2="${W}" y1="${H}" y2="${H}" stroke="#333" stroke-dasharray="2 4"/>
    <line x1="${xc}" x2="${xc}" y1="0" y2="${H}" stroke="#ffd23f" stroke-opacity="0.5" stroke-dasharray="2 4"/>
    <text x="${xc + 8}" y="-8" class="fill-accent" font-size="10">regenerated below ${formatHz(cutoff)} Hz</text>
    ${out ? `<path d="${out} L${W},${H} L0,${H} Z" fill="#ffd23f" fill-opacity="0.06"/>` : ""}
    <path d="${curve(input)}" fill="none" stroke="#fff" stroke-opacity="${output ? 0.45 : 0.9}" stroke-width="1.2"
      ${output ? 'stroke-dasharray="3 3"' : ""}/>
    ${out ? `<path d="${out}" fill="none" stroke="#ffd23f" stroke-width="1.6"/>` : ""}
    ${compact ? "" : ticks}
  </svg>`;
}
