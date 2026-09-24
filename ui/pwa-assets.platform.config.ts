import { defineConfig } from '@vite-pwa/assets-generator/config';

// Platform-masked icons (Android maskable, iOS home screen): full-bleed, so
// the operating system's own corner shape is the only one the user sees.
export default defineConfig({
  preset: {
    transparent: { sizes: [], favicons: [], padding: 0 },
    maskable: { sizes: [512], padding: 0, resizeOptions: { background: '#0B0909' } },
    apple: { sizes: [180], padding: 0, resizeOptions: { background: '#0B0909' } },
  },
  images: ['assets/app-icon.svg'],
});
