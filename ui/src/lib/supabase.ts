import { createClient, type SupabaseClient } from '@supabase/supabase-js';

import { readEnv } from '@/config/env';

let client: SupabaseClient | null = null;

/**
 * The single Supabase client.
 *
 * Built on first use rather than at import so a configuration problem is
 * shown as a readable screen instead of a blank page. The session is kept in
 * localStorage and refreshed by the SDK, exactly as `supabase_flutter` does.
 */
export function getSupabase(): SupabaseClient {
  if (client) return client;
  const env = readEnv();
  client = createClient(env.supabaseUrl, env.supabaseAnonKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      // An email-confirmation link lands back here; the SDK picks the session
      // out of the URL so the user arrives signed in.
      detectSessionInUrl: true,
      storageKey: 'et.auth',
    },
    global: {
      headers: { 'x-client-info': 'expense-tracker-web/1.0.0' },
    },
  });
  return client;
}
