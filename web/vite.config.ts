import tailwindcss from "@tailwindcss/vite";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { gzipSync } from "node:zlib";
import { defineConfig, type Plugin } from "vite";
import pkg from "./package.json" with { type: "json" };

/**
 * The commit being built: the checkout's (on a manually run workflow GITHUB_SHA is the branch's
 * head, not the commit checked out), else CI's. Nothing in the build depends on the clock.
 */
function commit(): string {
  try {
    return execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return process.env.GITHUB_SHA ?? "unknown";
  }
}

/** Every file in a directory, as paths relative to it, sorted (stable output). */
function files(dir: string, root = dir): string[] {
  return readdirSync(dir).sort().flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? files(path, root) : [relative(root, path)];
  });
}

/**
 * Writes checksums.txt (sha256sum format) for every file the site serves, so anyone can check
 * the live site against a release's checksums, or against their own rebuild of the same commit:
 *   curl -O <site>/checksums.txt && … && sha256sum -c checksums.txt
 */
export function checksums(dir: string): string {
  return files(dir).filter((f) => f !== "checksums.txt")
    .map((f) => `${createHash("sha256").update(readFileSync(join(dir, f))).digest("hex")}  ${f}`).join("\n") + "\n";
}

function checksumsFile(): Plugin {
  let outDir = "dist";
  return {
    name: "octave-camo-checksums",
    apply: "build",
    configResolved: (config) => { outDir = resolve(config.root, config.build.outDir); },
    closeBundle: () => writeFileSync(join(outDir, "checksums.txt"), checksums(outDir)),
  };
}

/** Size as the README badges show it: decimal megabytes, one decimal ("3.6 MB"). */
export const megabytes = (bytes: number) => `${(bytes / 1e6).toFixed(1)} MB`;

/**
 * shields.io endpoint badges for the wasm's size, raw and gzipped (what a browser downloads), from
 * the exact file the site serves. Deterministic (gzip level 9), so the site build stays reproducible.
 */
export function wasmBadges(wasm: Uint8Array): Record<string, { schemaVersion: 1; label: string; message: string; color: string }> {
  return {
    "wasm.json": { schemaVersion: 1, label: "wasm", message: megabytes(wasm.length), color: "blue" },
    "wasm-gzip.json": { schemaVersion: 1, label: "wasm gzipped", message: megabytes(gzipSync(wasm, { level: 9 }).length), color: "brightgreen" },
  };
}

function badgeFiles(): Plugin {
  let outDir = "dist";
  return {
    name: "octave-camo-badges",
    apply: "build",
    configResolved: (config) => { outDir = resolve(config.root, config.build.outDir); },
    closeBundle: () => {
      const wasm = join(outDir, "octave-camo.wasm");
      if (!existsSync(wasm)) return;                       // a local build without the Swift toolchain
      mkdirSync(join(outDir, "badges"), { recursive: true });
      for (const [name, badge] of Object.entries(wasmBadges(readFileSync(wasm)))) {
        writeFileSync(join(outDir, "badges", name), JSON.stringify(badge) + "\n");
      }
    },
  };
}

/**
 * The page handles people's videos, so the built site pins down what it may load or contact:
 * only its own files. No connect-src beyond 'self' means no script on the page can send data
 * anywhere else, even if a dependency tried. ('wasm-unsafe-eval' runs the WebAssembly scrubber
 * and AAC encoder; blob: workers are how the encoders start. Neither reaches the network.)
 */
export const CONTENT_SECURITY_POLICY = [
  "default-src 'none'",
  "script-src 'self' 'wasm-unsafe-eval'",
  "worker-src 'self' blob:",
  "connect-src 'self' blob:",
  "img-src 'self' data: blob:",
  "media-src 'self' blob:",
  "style-src 'self' 'unsafe-inline'",
  "font-src 'self' data:",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'none'",
].join("; ");

function contentSecurityPolicy(): Plugin {
  return {
    name: "octave-camo-csp",
    apply: "build",              // the dev server needs inline scripts for hot reload
    transformIndexHtml: (html) => html.replace("<head>", `<head>
  <meta http-equiv="Content-Security-Policy" content="${CONTENT_SECURITY_POLICY}" />
  <meta name="referrer" content="no-referrer" />`),
  };
}

// GitHub Pages serves the site at /octave-camo/.
export default defineConfig({
  base: process.env.BASE_PATH ?? "/octave-camo/",
  // Badges before checksums: checksums.txt covers every file the site serves.
  plugins: [tailwindcss(), contentSecurityPolicy(), badgeFiles(), checksumsFile()],
  define: {
    __VERSION__: JSON.stringify(pkg.version),
    __COMMIT__: JSON.stringify(commit()),
  },
  worker: { format: "es" },
  build: { target: "es2022" },
});
