/**
 * How long a cloak takes in the browser, on the real wasm build (not a gate: numbers are printed
 * as "perf:" lines). Runs only with E2E_PERF=1 (the Perf workflow). Clip lengths up to the
 * page's 5-minute limit, unthrottled and with the CPU slowed 4× (roughly a mid-range phone).
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { rmSync } from "node:fs";
import { join } from "node:path";
import { type Browser, chromium } from "playwright";
import { flybyWav, Session, URL_, workDir } from "./helpers.ts";

const dir = workDir();

describe.skipIf(!URL_ || !process.env.E2E_PERF)("cloak timing", () => {
  let browser: Browser;
  beforeAll(async () => { browser = await chromium.launch(); });
  afterAll(async () => {
    await browser?.close();
    rmSync(dir, { recursive: true, force: true });
  });

  for (const seconds of [60, 300]) {
    for (const throttle of [1, 4]) {
      for (const preset of ["full", "light"] as const) {
        test(`${seconds} s, CPU ÷${throttle}, ${preset}`, async () => {
          const file = join(dir, `clip-${seconds}.wav`);
          if (!(await Bun.file(file).exists())) flybyWav(file, seconds);
          const s = new Session(browser, dir);
          const page = await s.start();
          const cdp = await page.context().newCDPSession(page);
          await cdp.send("Emulation.setCPUThrottlingRate", { rate: throttle });
          const t0 = performance.now();
          await s.open(file, 1_800_000);
          const analyzed = performance.now();
          await page.selectOption("#preset", preset);
          await s.cloak(3_000_000);
          const cloaked = performance.now();
          const status = (await s.status()).replace(/\s+/g, " ");
          const worker = /· ([\d.]+) s ·/.exec(status)?.[1] ?? "?";
          console.log(`perf: ${seconds} s clip, CPU ÷${throttle}, ${preset}: decode+analyze ${((analyzed - t0) / 1000).toFixed(1)} s, `
            + `cloak ${((cloaked - analyzed) / 1000).toFixed(1)} s (scrubber ${worker} s)`);
          expect(s.problems).toEqual([]);
          await s.close();
        }, 3_600_000);
      }
    }
  }
});
