import { defineConfig } from '@vite-pwa/assets-generator/config';

// Browser icons and favicons: the rounded brand mark, transparent corners.
export default defineConfig({
  headLinkOptions: { preset: '2023' },
  preset: {
    transparent: { sizes: [64, 192, 512], favicons: [[48, 'favicon.ico']], padding: 0 },
    maskable: { sizes: [], padding: 0 },
    apple: { sizes: [], padding: 0 },
  },
  images: ['public/favicon.svg'],
});
