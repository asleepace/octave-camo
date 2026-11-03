/**
 * Renders public/og.png, the 1200×630 link-preview image (Open Graph / X), from the HTML below
 * with headless Chromium. Run after changing the wording:  bun scripts/og-image.ts
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { chromium } from "playwright";

const fonts = join(import.meta.dir, "..", "node_modules", "@fontsource", "jetbrains-mono", "files");
const font = (weight: number) =>
  `@font-face { font-family: "JetBrains Mono"; font-weight: ${weight};
    src: url(data:font/woff2;base64,${readFileSync(join(fonts, `jetbrains-mono-latin-${weight}-normal.woff2`)).toString("base64")}) format("woff2"); }`;

/** A Doppler curve: a tone falling as its source passes, centred at x0, from y0 to y1. */
const curve = (x0: number, y0: number, y1: number, width: number) => {
  const points: string[] = [];
  for (let x = 0; x <= 1200; x += 8) {
    const t = (x - x0) / width;
    points.push(`${x},${(y0 + (y1 - y0) * (0.5 + 0.5 * Math.tanh(t * 2.2))).toFixed(1)}`);
  }
  return points.join(" ");
};

const html = `<!doctype html><html><head><meta charset="utf-8"><style>
${font(300)} ${font(400)} ${font(500)}
* { margin: 0; box-sizing: border-box; }
body { width: 1200px; height: 630px; background: #000; color: #d4d4d4; font-family: "JetBrains Mono", monospace; overflow: hidden; position: relative; }
svg.bg { position: absolute; inset: 0; }
.content { position: absolute; left: 80px; right: 80px; top: 72px; bottom: 64px; display: flex; flex-direction: column; }
.brand { display: flex; align-items: center; gap: 18px; font-size: 26px; letter-spacing: 0.16em; color: #fff; font-weight: 500; }
h1 { margin-top: 56px; font-size: 60px; line-height: 1.12; font-weight: 400; color: #fff; letter-spacing: -0.01em; max-width: 900px; }
h1 em { font-style: normal; color: #ffd23f; }
.what { margin-top: 28px; font-size: 24px; color: #a3a3a3; font-weight: 300; }
.foot { margin-top: auto; display: flex; justify-content: space-between; font-size: 20px; color: #8a8a8a; letter-spacing: 0.04em; }
.foot b { color: #ffd23f; font-weight: 400; }
</style></head><body>
<svg class="bg" viewBox="0 0 1200 630" fill="none" stroke-linecap="round">
  <defs>
    <linearGradient id="fade" x1="0" x2="1" y1="0" y2="0">
      <stop offset="0.38" stop-color="#fff" stop-opacity="0"/><stop offset="0.72" stop-color="#fff" stop-opacity="1"/>
    </linearGradient>
    <mask id="right"><rect width="1200" height="630" fill="url(#fade)"/></mask>
  </defs>
  <g mask="url(#right)">
  ${Array.from({ length: 9 }, (_, i) => `<polyline points="${curve(820 + i * 22, 250 + i * 34, 330 + i * 34, 120 + i * 10)}" stroke="#ffd23f" stroke-opacity="${(0.05 + i * 0.012).toFixed(3)}" stroke-width="2"/>`).join("")}
  <polyline points="${curve(860, 190, 300, 150)}" stroke="#665419" stroke-width="10" stroke-opacity="0.55"/>
  <polyline points="${curve(860, 300, 470, 150)}" stroke="#ffd23f" stroke-width="12" stroke-opacity="0.35"/>
  </g>
</svg>
<div class="content">
  <div class="brand">
    <svg viewBox="0 0 120 120" width="44" height="44" fill="none" stroke-linecap="round"><path d="M8 48 C38 48 44 32 60 32 C76 32 82 48 112 48" stroke="#665419" stroke-width="13"/><path d="M8 86 C38 86 44 54 60 54 C76 54 82 86 112 86" stroke="#ffd23f" stroke-width="16"/></svg>
    OCTAVE CAMO
  </div>
  <h1>Remove <em>location clues</em><br>from your videos</h1>
  <p class="what">planes · trains · ships · mains hum · light flicker · metadata</p>
  <div class="foot"><span>runs in your browser · <b>nothing is uploaded</b></span><span>open source</span></div>
</div>
</body></html>`;

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
await page.setContent(html, { waitUntil: "load" });
await page.evaluate(() => document.fonts.ready);
const out = join(import.meta.dir, "..", "public", "og.png");
await page.screenshot({ path: out, type: "png" });
await browser.close();
console.log(`wrote ${out}`);
