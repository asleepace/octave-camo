import tailwindcss from "@tailwindcss/vite";
import { defineConfig, type Plugin } from "vite";

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
  plugins: [tailwindcss(), contentSecurityPolicy()],
  worker: { format: "es" },
  build: { target: "es2022" },
});
