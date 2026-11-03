/**
 * Accessibility: axe-core (WCAG 2.2 A/AA rules) on the page empty, with a file loaded, and after
 * cloaking, plus keyboard-only use. Runs with the other e2e tests.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { type Browser, chromium, type Page } from "playwright";
import { flybyWav, lowContrast, URL_, workDir } from "./helpers.ts";

const dir = workDir();
const AXE = readFileSync(require.resolve("axe-core/axe.min.js"), "utf8");

type Violation = { id: string; impact: string; help: string; nodes: { target: string[] }[] };

async function audit(page: Page): Promise<Violation[]> {
  await page.evaluate(AXE);
  return page.evaluate(async () => {
    // @ts-expect-error injected
    const r = await axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa", "best-practice"] } });
    return r.violations.map((v: Violation) => ({ id: v.id, impact: v.impact, help: v.help, nodes: v.nodes.map((n) => ({ target: n.target })) }));
  });
}

const describeViolations = (vs: Violation[]) =>
  vs.map((v) => `${v.impact} ${v.id}: ${v.help} — ${v.nodes.slice(0, 4).map((n) => n.target.join(" ")).join(", ")}${v.nodes.length > 4 ? ` (+${v.nodes.length - 4})` : ""}`).join("\n");

describe.skipIf(!URL_)("accessibility", () => {
  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch();
    flybyWav(join(dir, "clip.wav"), 6);
  });
  afterAll(async () => {
    await browser?.close();
    rmSync(dir, { recursive: true, force: true });
  });

  test("no WCAG A/AA violations: empty, loaded, cloaked", async () => {
    // bypassCSP: the built page's CSP (rightly) refuses the injected axe script.
    const page = await (await browser.newContext({ bypassCSP: true })).newPage();
    await page.goto(URL_!);
    const found: string[] = [];
    const check = async (state: string) => {
      const v = await audit(page);
      if (v.length) found.push(`[${state}]\n${describeViolations(v)}`);
      const c = await lowContrast(page);
      if (c.length) found.push(`[${state}] text under 4.5:1\n${c.join("\n")}`);
    };
    await check("empty");
    await page.setInputFiles("#file", join(dir, "clip.wav"));
    await page.waitForFunction(() => /exposed|no trackable/.test(document.querySelector("#status")?.textContent ?? ""), null, { timeout: 180_000 });
    await check("loaded");
    await page.click("#cloak");
    await page.waitForFunction(() => /^SAVE/.test(document.querySelector("#cloak")?.textContent ?? ""), null, { timeout: 300_000 });
    await page.evaluate(() => { for (const d of document.querySelectorAll("details")) d.open = true; });
    await check("cloaked");
    if (found.length) console.log(found.join("\n\n"));
    expect(found).toEqual([]);
  }, 600_000);

  test("everything works from the keyboard: open, cloak, save", async () => {
    const page = await (await browser.newContext({ acceptDownloads: true })).newPage();
    await page.goto(URL_!);
    // Tab to the file chooser and open it with the keyboard.
    const chooser = page.waitForEvent("filechooser");
    let reached = false;
    for (let i = 0; i < 12 && !reached; i++) {
      await page.keyboard.press("Tab");
      reached = await page.evaluate(() => document.activeElement?.id === "file" || document.activeElement?.id === "drop");
    }
    expect(reached).toBe(true);
    await page.keyboard.press("Enter");
    await (await chooser).setFiles(join(dir, "clip.wav"));
    await page.waitForFunction(() => /exposed|no trackable/.test(document.querySelector("#status")?.textContent ?? ""), null, { timeout: 180_000 });
    await page.focus("#cloak");
    await page.keyboard.press("Enter");
    await page.waitForFunction(() => /^SAVE/.test(document.querySelector("#cloak")?.textContent ?? ""), null, { timeout: 300_000 });
    const [download] = await Promise.all([page.waitForEvent("download"), page.keyboard.press("Enter")]);
    expect(download.suggestedFilename()).toMatch(/^camo-/);
    // Focus is visible on every control reached by Tab.
    const invisible = await page.evaluate(() => {
      const bad: string[] = [];
      for (const el of document.querySelectorAll<HTMLElement>("a, button, input, select, summary, [tabindex]")) {
        if (el.offsetParent === null || (el as HTMLButtonElement).disabled) continue;
        el.focus();
        const s = getComputedStyle(el);
        const ring = s.outlineStyle !== "none" && s.outlineWidth !== "0px" || s.boxShadow !== "none";
        if (!ring) bad.push(el.id || el.tagName.toLowerCase());
      }
      return bad;
    });
    expect(invisible).toEqual([]);
  }, 600_000);
});
