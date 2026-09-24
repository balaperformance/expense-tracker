import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';

import './styles/tokens.css';
import './styles/base.css';

import { App } from '@/app/App';
import { ConfigError, readEnv } from '@/config/env';

const root = createRoot(document.getElementById('root') as HTMLElement);

/** Shown instead of a blank page when the build is missing its Supabase settings. */
function ConfigProblem({ message }: { message: string }) {
  return (
    <div style={{ minHeight: '100dvh', display: 'grid', placeItems: 'center', padding: 24, textAlign: 'center' }}>
      <div style={{ maxWidth: 420, display: 'flex', flexDirection: 'column', gap: 10 }}>
        <h1 className="t-title-lg">Configuration problem</h1>
        <p className="t-body-sm">{message}</p>
      </div>
    </div>
  );
}

/** Development only: `?demo` opens the seeded preview (src/dev); compiled out of production. */
async function renderDemo(): Promise<boolean> {
  if (!import.meta.env.DEV) return false;
  if (new URLSearchParams(location.search).has('demo')) sessionStorage.setItem('et.demo', '1');
  if (sessionStorage.getItem('et.demo') !== '1') return false;
  const { DemoApp } = await import('./dev/DemoApp');
  root.render(<DemoApp />);
  return true;
}

async function start() {
  try {
    readEnv();
  } catch (error) {
    if (!(error instanceof ConfigError)) throw error;
    root.render(<ConfigProblem message={error.message} />);
    return;
  }
  if (await renderDemo()) return;
  root.render(
    <StrictMode>
      <App />
    </StrictMode>,
  );
}

void start();
