import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "path";
import fullReload from "vite-plugin-full-reload";

const DEFAULT_DEV_PORT = 40889;

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, path.resolve(import.meta.dirname), "");
  const port = Number(
    env.PORT ?? process.env.PORT ?? String(DEFAULT_DEV_PORT),
  );
  if (Number.isNaN(port) || port <= 0) {
    throw new Error(`Invalid PORT: "${env.PORT ?? process.env.PORT}"`);
  }

  const basePath = env.BASE_PATH ?? process.env.BASE_PATH ?? "/";

  return {
    base: basePath,
    plugins: [
      react(),
      tailwindcss(),
      // Vollständiger Reload bei z. B. index.html; TS/TSX nutzt HMR (Fast Refresh).
      fullReload(["index.html"]),
    ],
    resolve: {
      alias: {
        "@": path.resolve(import.meta.dirname, "src"),
        "@assets": path.resolve(import.meta.dirname, "..", "attached_assets"),
      },
      dedupe: ["react", "react-dom"],
    },
    root: path.resolve(import.meta.dirname),
    build: {
      outDir: path.resolve(import.meta.dirname, "dist/public"),
      emptyOutDir: true,
    },
    server: {
      port,
      strictPort: true,
      host: "0.0.0.0",
    },
    preview: {
      port,
      host: "0.0.0.0",
    },
  };
});
