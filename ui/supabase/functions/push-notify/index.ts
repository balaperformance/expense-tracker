/**
 * push-notify — the only place the app's push notifications are produced.
 *
 * Deployed as a Supabase Edge Function and woken every 15 minutes by pg_cron
 * (migration 008), so notifications are generated here, server-side, whether
 * or not the app is open. There is no signed-in caller: the schedule proves
 * itself with a shared secret, and the function reads and writes as the
 * service role. Everything Deno-specific lives in this file and in the two
 * adapters beside it; the rules are plain TypeScript under core/.
 *
 * Two channels deliver the same notifications: Web Push to browsers (the web
 * app, migration 008) and Firebase Cloud Messaging to phones (the Android app,
 * migration 009). Each is optional; at least one must be configured.
 *
 * Secrets (supabase secrets set …, never in the app or in git):
 *   PUSH_NOTIFY_SECRET   the same string stored in Vault as push_notify_secret
 * Web Push — all three, or none:
 *   VAPID_PUBLIC_KEY     the Web Push key pair (npx web-push generate-vapid-keys);
 *   VAPID_PRIVATE_KEY      the public half is also the web app's VITE_VAPID_PUBLIC_KEY
 *   VAPID_SUBJECT        mailto:you@example.com — who the push services may contact
 * Firebase Cloud Messaging:
 *   FCM_SERVICE_ACCOUNT  the Firebase service-account key file's JSON (Project
 *                        settings → Service accounts → Generate new private key)
 *
 * Provided by the platform: SUPABASE_URL and the service-role key
 * (SUPABASE_SERVICE_ROLE_KEY, or SUPABASE_SECRET_KEYS on newer projects).
 *
 * Deploy WITHOUT JWT verification — the caller is the database, not a user:
 *   supabase functions deploy push-notify --no-verify-jwt --workdir ui
 */
import { createClient } from 'npm:@supabase/supabase-js@2';

import { ChannelSender } from './core/channels.ts';
import { FcmClient, FcmPushSender, parseServiceAccount } from './core/fcm.ts';
import { runNotifications, type PushSender } from './core/run.ts';
import { SupabaseMobileTokens, SupabaseStore } from './supabaseStore.ts';
import { WebPushSender } from './webPushSender.ts';

function serviceRoleKey(): string {
  const raw = Deno.env.get('SUPABASE_SECRET_KEYS');
  if (raw) {
    try {
      const parsed = JSON.parse(raw) as Record<string, unknown>;
      const key = parsed.default ?? Object.values(parsed)[0];
      if (typeof key === 'string' && key.length > 0) return key;
    } catch {
      // fall through to the classic variable
    }
  }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
}

/** Compares two strings by their hashes, so the time taken never reveals how much of a guess was right. */
async function sameSecret(given: string, expected: string): Promise<boolean> {
  const digest = async (value: string) => new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)));
  const [a, b] = await Promise.all([digest(given), digest(expected)]);
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return difference === 0;
}

const json = (body: unknown, status = 200) => Response.json(body, { status, headers: { 'Cache-Control': 'no-store' } });

Deno.serve(async (request) => {
  if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const expected = Deno.env.get('PUSH_NOTIFY_SECRET') ?? '';
  if (!expected) return json({ error: 'not_configured', missing: ['PUSH_NOTIFY_SECRET'] }, 503);
  if (!(await sameSecret(request.headers.get('x-push-secret') ?? '', expected))) return json({ error: 'unauthorized' }, 401);

  const url = Deno.env.get('SUPABASE_URL') ?? '';
  const key = serviceRoleKey();
  const publicKey = Deno.env.get('VAPID_PUBLIC_KEY') ?? '';
  const privateKey = Deno.env.get('VAPID_PRIVATE_KEY') ?? '';
  const subject = Deno.env.get('VAPID_SUBJECT') ?? '';
  const fcmJson = Deno.env.get('FCM_SERVICE_ACCOUNT') ?? '';
  const vapid = [publicKey, privateKey, subject];
  const webPush = vapid.every(Boolean);
  const fcm = fcmJson ? parseServiceAccount(fcmJson) : null;
  // Names only, never values.
  const missing = [
    !url && 'SUPABASE_URL',
    !key && 'SUPABASE_SERVICE_ROLE_KEY',
    ...(vapid.some(Boolean) && !webPush
      ? [!publicKey && 'VAPID_PUBLIC_KEY', !privateKey && 'VAPID_PRIVATE_KEY', !subject && 'VAPID_SUBJECT']
      : []),
    fcmJson && !fcm && 'FCM_SERVICE_ACCOUNT (not a Firebase service-account key)',
    !webPush && !fcmJson && 'VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY / VAPID_SUBJECT or FCM_SERVICE_ACCOUNT',
  ].filter(Boolean);
  if (missing.length) return json({ error: 'not_configured', missing }, 503);

  const client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } });
  const store = new SupabaseStore(client);
  const channels: PushSender[] = [
    ...(webPush ? [new WebPushSender(client, { subject, publicKey, privateKey })] : []),
    ...(fcm ? [new FcmPushSender(new FcmClient(fcm), new SupabaseMobileTokens(client))] : []),
  ];
  try {
    const now = new Date();
    const report = await runNotifications(now, store, new ChannelSender(channels));
    await store.prune(now);
    return json(report);
  } catch (error) {
    console.error('push-notify: run failed:', error instanceof Error ? error.message : 'unknown error');
    return json({ error: 'run_failed' }, 500);
  }
});
