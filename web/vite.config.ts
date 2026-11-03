import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";

// GitHub Pages serves the site at /octave-camo/.
export default defineConfig({
  base: process.env.BASE_PATH ?? "/octave-camo/",
  plugins: [tailwindcss()],
  worker: { format: "es" },
  build: { target: "es2022" },
});
