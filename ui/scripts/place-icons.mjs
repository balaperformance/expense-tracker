// The platform icons are generated next to their source in assets/; the app
// serves them from public/.
import { existsSync, renameSync } from 'node:fs';

for (const name of ['maskable-icon-512x512.png', 'apple-touch-icon-180x180.png']) {
  const from = `assets/${name}`;
  if (existsSync(from)) renameSync(from, `public/${name}`);
}
