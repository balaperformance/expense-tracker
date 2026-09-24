/**
 * Public runtime configuration.
 *
 * Only two values reach the browser, and both are designed to be public: the
 * project URL and the anon / publishable key. Row-level security is what
 * protects the data. A privileged key in this bundle would bypass RLS for
 * anyone who opened dev tools, so one is refused outright rather than used.
 */

export type AppEnv = {
  supabaseUrl: string;
  supabaseAnonKey: string;
};

export class ConfigError extends Error {
  override readonly name = 'ConfigError';
}

function isPrivilegedKey(key: string): boolean {
  if (key.startsWith('sb_secret_')) return true;
  const parts = key.split('.');
  if (parts.length !== 3) return false;
  try {
    const payload = JSON.parse(atob(parts[1]?.replace(/-/g, '+').replace(/_/g, '/') ?? '')) as {
      role?: unknown;
    };
    return payload.role === 'service_role';
  } catch {
    return false;
  }
}

export function readEnv(): AppEnv {
  const url = (import.meta.env.VITE_SUPABASE_URL ?? '').trim();
  const key = (import.meta.env.VITE_SUPABASE_ANON_KEY ?? '').trim();

  if (!url || !key) {
    throw new ConfigError(
      'VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY must be set. Copy .env.example to .env.local ' +
        'and fill in the project URL and anon (publishable) key.',
    );
  }

  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new ConfigError('VITE_SUPABASE_URL is not a valid URL.');
  }
  if (parsed.protocol !== 'https:' && parsed.hostname !== 'localhost' && parsed.hostname !== '127.0.0.1') {
    throw new ConfigError('VITE_SUPABASE_URL must use https.');
  }

  if (isPrivilegedKey(key)) {
    throw new ConfigError(
      'VITE_SUPABASE_ANON_KEY is a service-role / secret key. It would bypass row-level security ' +
        'for every visitor, so the app will not start with it. Use the anon (publishable) key.',
    );
  }

  return { supabaseUrl: parsed.origin, supabaseAnonKey: key };
}
