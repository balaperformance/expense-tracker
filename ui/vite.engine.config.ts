/**
 * Builds the phone app's statement engine: src/engine/main.ts and the web
 * statement-import modules it uses (PDF.js included) as ONE self-contained
 * script, written into the Flutter app's assets.
 *
 *   npm run build:engine
 *
 * Re-run it whenever the statement parsers, classification or duplicate
 * rules change, so both apps read statements the same way.
 */
import { fileURLToPath } from 'node:url';

import { defineConfig, type Plugin } from 'vite';

const WORKER_URL_IMPORT = 'pdfjs-dist/build/pdf.worker.min.mjs?url';

/**
 * The web build loads PDF.js's worker from a URL. The engine runs PDF.js on
 * its own thread instead (main.ts), so that URL is replaced by an empty
 * string rather than inlining the worker a second time.
 */
function noWorkerUrl(): Plugin {
  const id = '\0engine:no-worker-url';
  return {
    name: 'engine:no-worker-url',
    enforce: 'pre',
    resolveId: (source) => (source === WORKER_URL_IMPORT ? id : null),
    load: (loaded) => (loaded === id ? 'export default "";' : null),
  };
}

export default defineConfig({
  plugins: [noWorkerUrl()],
  resolve: { alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) } },
  publicDir: false,
  build: {
    outDir: fileURLToPath(new URL('../mobile/assets/statement_engine', import.meta.url)),
    emptyOutDir: true,
    target: 'es2022',
    minify: true,
    sourcemap: false,
    lib: {
      entry: fileURLToPath(new URL('./src/engine/main.ts', import.meta.url)),
      formats: ['iife'],
      name: 'StatementEngineBundle',
      fileName: () => 'engine.js',
    },
    rollupOptions: { output: { inlineDynamicImports: true } },
  },
});
