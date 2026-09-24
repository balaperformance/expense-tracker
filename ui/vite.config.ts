import { createReadStream, existsSync, mkdirSync, copyFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import react from '@vitejs/plugin-react';
import { defineConfig, loadEnv, type Plugin } from 'vite';
import { VitePWA } from 'vite-plugin-pwa';

const root = dirname(fileURLToPath(import.meta.url));

/**
 * OCR assets, served from this origin rather than a CDN so a receipt scan
 * works offline once cached and the page never loads third-party script.
 * Only the LSTM cores are shipped: the worker is always created LSTM-only.
 */
const TESSERACT_FILES: Record<string, string> = {
  'worker.min.js': 'node_modules/tesseract.js/dist/worker.min.js',
  'tesseract-core-lstm.wasm.js': 'node_modules/tesseract.js-core/tesseract-core-lstm.wasm.js',
  'tesseract-core-simd-lstm.wasm.js': 'node_modules/tesseract.js-core/tesseract-core-simd-lstm.wasm.js',
  'tesseract-core-relaxedsimd-lstm.wasm.js':
    'node_modules/tesseract.js-core/tesseract-core-relaxedsimd-lstm.wasm.js',
  'eng.traineddata.gz': 'node_modules/@tesseract.js-data/eng/4.0.0_best_int/eng.traineddata.gz',
};

function tesseractAssets(): Plugin {
  let outDir = 'dist';
  return {
    name: 'expense-tracker:tesseract-assets',
    configResolved(config) {
      outDir = resolve(config.root, config.build.outDir);
    },
    configureServer(server) {
      server.middlewares.use('/tesseract', (req, res, next) => {
        const name = (req.url ?? '').replace(/^\//, '').split('?')[0] ?? '';
        const source = TESSERACT_FILES[name];
        if (!source) {
          next();
          return;
        }
        res.setHeader('Content-Type', name.endsWith('.gz') ? 'application/gzip' : 'text/javascript');
        createReadStream(join(root, source)).pipe(res);
      });
    },
    writeBundle() {
      const target = join(outDir, 'tesseract');
      mkdirSync(target, { recursive: true });
      for (const [name, source] of Object.entries(TESSERACT_FILES)) {
        const from = join(root, source);
        if (!existsSync(from)) throw new Error(`Missing OCR asset: ${source}`);
        copyFileSync(from, join(target, name));
      }
    },
  };
}

/**
 * The Content-Security-Policy. It names the project's own Supabase origin —
 * the only place the app may talk to — so it is built from the environment.
 * `wasm-unsafe-eval` is what the on-device OCR engine needs; nothing loads
 * from a third-party origin.
 */
function contentSecurityPolicy(supabaseUrl: string): string {
  let supabaseOrigin = '';
  try {
    supabaseOrigin = new URL(supabaseUrl).origin;
  } catch {
    // Validated again at runtime; the policy stays strict without it.
  }
  const realtime = supabaseOrigin.replace(/^https:/, 'wss:');
  return [
    "default-src 'self'",
    "script-src 'self' 'wasm-unsafe-eval'",
    "worker-src 'self' blob:",
    `connect-src 'self' ${supabaseOrigin} ${realtime}`.trim(),
    "img-src 'self' data: blob:",
    "style-src 'self' 'unsafe-inline'",
    "font-src 'self'",
    "manifest-src 'self'",
    "frame-src 'self'",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
  ].join('; ');
}

/** Cloudflare Pages response headers (`dist/_headers`). */
function cloudflareHeaders(csp: string): Plugin {
  let outDir = 'dist';
  return {
    name: 'expense-tracker:cloudflare-headers',
    apply: 'build',
    configResolved(config) {
      outDir = resolve(config.root, config.build.outDir);
    },
    writeBundle() {
      const headers = `/*
  Content-Security-Policy: ${csp}
  X-Content-Type-Options: nosniff
  X-Frame-Options: DENY
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(self), microphone=(), geolocation=(), payment=(), usb=()
  Strict-Transport-Security: max-age=31536000; includeSubDomains
  Cross-Origin-Opener-Policy: same-origin

/assets/*
  Cache-Control: public, max-age=31536000, immutable

/tesseract/*
  Cache-Control: public, max-age=2592000

/sw.js
  Cache-Control: no-cache

/index.html
  Cache-Control: no-cache

/manifest.webmanifest
  Cache-Control: no-cache
  Content-Type: application/manifest+json
`;
      writeFileSync(join(outDir, '_headers'), headers);
    },
  };
}

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, root, 'VITE_');
  const csp = contentSecurityPolicy(env.VITE_SUPABASE_URL);

  return {
    resolve: {
      alias: { '@': resolve(root, 'src') },
    },
    // `npm run preview` serves the production policy, so it is tested locally.
    preview: {
      headers: { 'Content-Security-Policy': csp, 'X-Content-Type-Options': 'nosniff' },
    },
    build: {
      target: 'es2022',
      sourcemap: false,
      chunkSizeWarningLimit: 600,
    },
    plugins: [
      react(),
      tesseractAssets(),
      cloudflareHeaders(csp),
      VitePWA({
        registerType: 'prompt',
        injectRegister: false,
        includeAssets: ['favicon.ico', 'favicon.svg', 'apple-touch-icon-180x180.png', 'theme-init.js'],
        manifest: {
          id: '/',
          name: 'Expense Tracker',
          short_name: 'Expenses',
          description: 'Spend with intention — a private expense tracker.',
          lang: 'en',
          dir: 'ltr',
          start_url: '/',
          scope: '/',
          display: 'standalone',
          display_override: ['standalone', 'minimal-ui'],
          orientation: 'portrait',
          // The light page colour: the launch screen matches the default theme.
          background_color: '#F5F4F4',
          theme_color: '#F5F4F4',
          categories: ['finance', 'productivity'],
          icons: [
            { src: 'pwa-64x64.png', sizes: '64x64', type: 'image/png' },
            { src: 'pwa-192x192.png', sizes: '192x192', type: 'image/png' },
            { src: 'pwa-512x512.png', sizes: '512x512', type: 'image/png' },
            {
              src: 'maskable-icon-512x512.png',
              sizes: '512x512',
              type: 'image/png',
              purpose: 'maskable',
            },
          ],
          shortcuts: [
            { name: 'Add expense', short_name: 'Expense', url: '/expenses/new' },
            { name: 'Ask the assistant', short_name: 'Assistant', url: '/assistant' },
          ],
        },
        workbox: {
          // The app shell only. OCR assets are cached on first use instead of
          // on install — they are large and most sessions never scan.
          globPatterns: ['**/*.{js,css,html,svg,png,ico,webmanifest}'],
          globIgnores: ['tesseract/**'],
          navigateFallback: '/index.html',
          navigateFallbackDenylist: [/^\/tesseract\//, /^\/_/],
          cleanupOutdatedCaches: true,
          clientsClaim: true,
          runtimeCaching: [
            {
              urlPattern: ({ url, sameOrigin }) => sameOrigin && url.pathname.startsWith('/tesseract/'),
              handler: 'CacheFirst',
              options: {
                cacheName: 'ocr-assets',
                expiration: { maxEntries: 8, maxAgeSeconds: 60 * 60 * 24 * 60 },
                cacheableResponse: { statuses: [200] },
              },
            },
            // Financial data is never cached by the service worker: Supabase
            // requests are cross-origin and fall through to the network.
          ],
        },
        devOptions: { enabled: false },
      }),
    ],
  };
});
