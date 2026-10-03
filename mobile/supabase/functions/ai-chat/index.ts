/**
 * ai-chat — the only place the app's AI assistant talks to a model.
 *
 * Deployed as a Supabase Edge Function. Everything Deno-specific lives in
 * this file; the request handling, tool loop, tools and providers are plain
 * TypeScript under core/, tools/ and providers/ so they run under `deno test`
 * with no network and no database.
 *
 * Secrets (set with `supabase secrets set`, never in the app):
 *   GEMINI_API_KEY   primary provider
 *   GROQ_API_KEY     fallback provider
 *   GEMINI_MODEL     optional, defaults in providers/gemini.ts
 *   GROQ_MODEL       optional, defaults in providers/groq.ts
 *
 * Provided by the platform:
 *   SUPABASE_URL, SUPABASE_PUBLISHABLE_KEYS (or legacy SUPABASE_ANON_KEY)
 *
 * Deliberately never read: SUPABASE_SERVICE_ROLE_KEY, SUPABASE_SECRET_KEYS,
 * SUPABASE_DB_URL. Every database call in this function is made as the
 * signed-in user, so row-level security applies exactly as it does in the app.
 */
import { createClient } from "npm:@supabase/supabase-js@2";

import { createHandler, type Session } from "./core/handler.ts";
import { LIMITS, RateLimiter } from "./core/limits.ts";
import { SupabaseDb } from "./db/supabase_db.ts";
import { DEFAULT_GEMINI_MODEL, GeminiProvider } from "./providers/gemini.ts";
import { DEFAULT_GROQ_MODEL, GroqProvider } from "./providers/groq.ts";
import type { AIProvider } from "./providers/provider.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const PUBLISHABLE_KEY = resolvePublishableKey();

/**
 * The publishable (anon) key: safe to be public, grants nothing by itself.
 * Newer projects expose it as a JSON map; older ones as SUPABASE_ANON_KEY.
 */
function resolvePublishableKey(): string {
  const raw = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
  if (raw) {
    try {
      const parsed = JSON.parse(raw) as Record<string, unknown>;
      const key = parsed.default ?? Object.values(parsed)[0];
      if (typeof key === "string" && key.length > 0) return key;
    } catch {
      // fall through to the legacy variable
    }
  }
  return Deno.env.get("SUPABASE_ANON_KEY") ?? "";
}

/**
 * Turns the caller's bearer token into a session.
 *
 * The client is built with the publishable key plus the caller's own
 * Authorization header, then asked to verify the token with the auth server.
 * The resulting client acts *as that user*: RLS is enforced by Postgres on
 * every query, and there is no privileged client anywhere in this function.
 */
async function openSession(authorization: string | null): Promise<Session | null> {
  if (!authorization || !SUPABASE_URL || !PUBLISHABLE_KEY) return null;
  const match = /^Bearer\s+(.+)$/i.exec(authorization.trim());
  if (!match) return null;
  const token = match[1].trim();
  if (token.length < 20 || token.length > 4096) return null;

  const client = createClient(SUPABASE_URL, PUBLISHABLE_KEY, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  const { data, error } = await client.auth.getUser(token);
  if (error || !data.user?.id) return null;

  return { userId: data.user.id, db: new SupabaseDb(client) };
}

function providers(): AIProvider[] {
  const list: AIProvider[] = [];
  const gemini = Deno.env.get("GEMINI_API_KEY");
  if (gemini) {
    list.push(new GeminiProvider(gemini, Deno.env.get("GEMINI_MODEL") || DEFAULT_GEMINI_MODEL));
  }
  const groq = Deno.env.get("GROQ_API_KEY");
  if (groq) {
    list.push(new GroqProvider(groq, Deno.env.get("GROQ_MODEL") || DEFAULT_GROQ_MODEL));
  }
  return list;
}

const handler = createHandler({
  openSession,
  providers,
  rateLimiter: new RateLimiter(LIMITS.rateLimitMaxRequests, LIMITS.rateLimitWindowMs),
  // Operational events only: which provider fell back, which tool threw.
  // Never a message, never an amount, never a user id.
  log: (event, fields) => console.warn(JSON.stringify({ event, ...fields })),
});

Deno.serve(handler);
