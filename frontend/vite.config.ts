import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  // plume dev loads plume.json's frontend.dev_url: keep them the same.
  server: { port: 5173, strictPort: true },
});
