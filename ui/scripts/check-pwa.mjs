#!/usr/bin/env node
/**
 * Validates the production build as an installable PWA: the manifest's
 * required members and icons, the service worker's precache and navigation
 * fallback, the iOS standalone meta tags, and the Cloudflare headers.
 * Run after `npm run build`.
 */
import { existsSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const dist = 'dist';
let failures = 0;
const check = (condition, message) => {
  if (condition) console.log(`✓ ${message}`);
  else {
    failures += 1;
    console.log(`✗ ${message}`);
  }
};

if (!existsSync(dist)) {
  console.error('✗ dist/ not found — run `npm run build` first.');
  process.exit(1);
}

// ---- Manifest ---------------------------------------------------------------
const manifest = JSON.parse(readFileSync(join(dist, 'manifest.webmanifest'), 'utf8'));
check(Boolean(manifest.name && manifest.short_name), `manifest name / short_name ("${manifest.name}" / "${manifest.short_name}")`);
check(manifest.start_url === '/' && manifest.scope === '/', 'manifest start_url and scope are /');
check(manifest.display === 'standalone', 'manifest display is standalone');
check(/^#[0-9a-f]{6}$/i.test(manifest.theme_color ?? '') && /^#[0-9a-f]{6}$/i.test(manifest.background_color ?? ''), 'manifest theme_color and background_color');
const icons = manifest.icons ?? [];
const hasIcon = (size, purpose) =>
  icons.some((icon) => icon.sizes === size && (purpose ? (icon.purpose ?? '').includes(purpose) : true) && existsSync(join(dist, icon.src)));
check(hasIcon('192x192'), 'manifest 192×192 icon exists');
check(hasIcon('512x512'), 'manifest 512×512 icon exists');
check(hasIcon('512x512', 'maskable'), 'manifest maskable icon exists');

// ---- HTML -------------------------------------------------------------------
const html = readFileSync(join(dist, 'index.html'), 'utf8');
check(/rel="manifest"/.test(html), 'index.html links the manifest');
check(/viewport-fit=cover/.test(html), 'viewport-fit=cover for iOS safe areas');
check(/apple-mobile-web-app-capable/.test(html) && /apple-mobile-web-app-status-bar-style/.test(html), 'iOS standalone meta tags');
check(/rel="apple-touch-icon"/.test(html) && existsSync(join(dist, 'apple-touch-icon-180x180.png')), 'apple-touch-icon 180×180');
check(/name="theme-color"/.test(html), 'theme-color meta');
check(!/<script(?![^>]*\bsrc=)[^>]*>\s*\S/.test(html), 'no inline scripts (strict CSP)');

// ---- Service worker ---------------------------------------------------------
const sw = readFileSync(join(dist, 'sw.js'), 'utf8');
check(/index\.html/.test(sw), 'service worker precaches index.html');
check(/NavigationRoute|createHandlerBoundToURL/.test(sw), 'service worker serves the app shell for navigations (offline)');
check(!/supabase\.co/.test(sw), 'service worker never caches Supabase responses');
check(/ocr-assets/.test(sw), 'OCR assets cached on first use');
check(/importScripts\(\s*["'`]push-sw\.js["'`]/.test(sw), 'service worker loads the push handlers (push-sw.js)');
const pushSw = existsSync(join(dist, 'push-sw.js')) ? readFileSync(join(dist, 'push-sw.js'), 'utf8') : '';
check(/addEventListener\(\s*['"]push['"]/.test(pushSw) && /showNotification/.test(pushSw), 'push-sw.js shows a notification for every push');
check(/addEventListener\(\s*['"]notificationclick['"]/.test(pushSw), 'push-sw.js opens the app when a notification is clicked');
check(!/supabase|localStorage|fetch\(/.test(pushSw), 'push-sw.js touches no data and makes no requests');

// ---- Headers ----------------------------------------------------------------
const headers = readFileSync(join(dist, '_headers'), 'utf8');
check(/Content-Security-Policy:/.test(headers) && /supabase\.co/.test(headers), 'CSP restricts connections to the Supabase project');
check(/frame-ancestors 'none'/.test(headers), 'clickjacking protection');
check(/\/sw\.js\s+Cache-Control: no-cache/.test(headers), 'service worker is never HTTP-cached');
check(/\/push-sw\.js\s+Cache-Control: no-cache/.test(headers), 'push handlers script is never HTTP-cached');

// ---- Size -------------------------------------------------------------------
const tooLarge = ['tesseract/tesseract-core-simd-lstm.wasm.js', 'tesseract/eng.traineddata.gz'].filter(
  (file) => statSync(join(dist, file)).size > 25 * 1024 * 1024,
);
check(tooLarge.length === 0, 'every file is under Cloudflare Pages’ 25 MiB limit');

console.log(failures ? `\n${failures} PWA check(s) failed.` : '\nAll PWA checks passed.');
process.exit(failures ? 1 : 0);
