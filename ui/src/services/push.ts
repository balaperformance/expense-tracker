/**
 * Web Push from the browser's side: asking for permission, subscribing this
 * device, and telling the project about it (migration 008). The server does
 * everything after that — the schedule, the sums and the sending live in the
 * `push-notify` Edge Function, so nothing here needs the app to be open at
 * 10 PM.
 *
 * The browser only ever asks for permission from [enablePush], which the
 * user triggers with a button. Nothing in this file asks on its own.
 */
import { readPref, StorageKeys, writePref } from '@/lib/storage';
import { getSupabase } from '@/lib/supabase';

import { ensureOk } from './db';

/** The public half of the project's VAPID key; the private half stays a secret of the Edge Function. */
const VAPID_PUBLIC_KEY = (import.meta.env.VITE_VAPID_PUBLIC_KEY ?? '').trim();

export type PushSupport = 'ok' | 'unsupported' | 'notConfigured';

/** Whether this browser can do push at all, and whether this build was given a key. */
export function pushSupport(): PushSupport {
  const capable =
    typeof window !== 'undefined' && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
  if (!capable) return 'unsupported';
  return VAPID_PUBLIC_KEY ? 'ok' : 'notConfigured';
}

export type PermissionState = NotificationPermission | 'unsupported';

export function notificationPermission(): PermissionState {
  return typeof Notification === 'undefined' ? 'unsupported' : Notification.permission;
}

/** The VAPID key as the bytes `subscribe()` wants. */
function applicationServerKey(): Uint8Array<ArrayBuffer> {
  const base64 = VAPID_PUBLIC_KEY.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(VAPID_PUBLIC_KEY.length / 4) * 4, '=');
  const raw = atob(base64);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

const SERVICE_WORKER_WAIT_MS = 5000;

/** The page's service worker once it is active, or null (a dev server runs none). */
async function readyRegistration(): Promise<ServiceWorkerRegistration | null> {
  const timeout = new Promise<null>((resolve) => setTimeout(() => resolve(null), SERVICE_WORKER_WAIT_MS));
  return Promise.race([navigator.serviceWorker.ready, timeout]);
}

/** This device's push subscription, if it has one. Never prompts. */
export async function currentSubscription(): Promise<PushSubscription | null> {
  if (pushSupport() === 'unsupported') return null;
  const registration = await navigator.serviceWorker.getRegistration();
  return registration ? registration.pushManager.getSubscription() : null;
}

/** True when [subscription] was made with the key this build carries (it changes if the key is rotated). */
function usesCurrentKey(subscription: PushSubscription): boolean {
  const key = subscription.options.applicationServerKey;
  if (!key) return false;
  const have = new Uint8Array(key);
  const want = applicationServerKey();
  return have.length === want.length && have.every((byte, i) => byte === want[i]);
}

/** Tells the project about this device and its time zone; the server sends nothing until this has happened. */
async function registerSubscription(subscription: PushSubscription): Promise<void> {
  const json = subscription.toJSON();
  const p256dh = json.keys?.p256dh;
  const auth = json.keys?.auth;
  if (!json.endpoint || !p256dh || !auth) throw new Error('The browser returned an incomplete push subscription.');
  ensureOk(
    await getSupabase().rpc('register_push_subscription', {
      p_endpoint: json.endpoint,
      p_p256dh: p256dh,
      p_auth: auth,
      p_user_agent: navigator.userAgent,
      p_timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC',
    }),
  );
}

export type EnableResult = 'enabled' | 'denied' | 'dismissed' | 'unavailable';

/**
 * Turns notifications on for this device. Asks the browser for permission
 * only if it has never been asked ('default'); a refusal is remembered by the
 * browser, so the user is not asked again — they are told how to allow it.
 */
export async function enablePush(): Promise<EnableResult> {
  if (pushSupport() !== 'ok') return 'unavailable';
  let permission = Notification.permission;
  if (permission === 'default') permission = await Notification.requestPermission();
  if (permission === 'denied') return 'denied';
  if (permission !== 'granted') return 'dismissed';

  const registration = await readyRegistration();
  if (!registration) return 'unavailable';
  let subscription = await registration.pushManager.getSubscription();
  if (subscription && !usesCurrentKey(subscription)) {
    await subscription.unsubscribe();
    subscription = null;
  }
  subscription ??= await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: applicationServerKey() });
  await registerSubscription(subscription);
  writePref(StorageKeys.pushEnabled, '1');
  writePref(StorageKeys.pushOff, null);
  return 'enabled';
}

/**
 * Turns notifications off for this device: unsubscribes the browser and
 * removes the project's record of it. [byUser] remembers the choice, so the
 * device is not switched back on by itself; a sign-out is not that choice.
 */
export async function disablePush({ byUser = true } = {}): Promise<void> {
  writePref(StorageKeys.pushEnabled, null);
  if (byUser) writePref(StorageKeys.pushOff, '1');
  const subscription = await currentSubscription();
  if (!subscription) return;
  const { endpoint } = subscription;
  // The browser first — it needs no network, and a push service that no longer knows the
  // endpoint answers 404/410, which switches the project's row off on the next send.
  await subscription.unsubscribe();
  ensureOk(await getSupabase().from('push_subscriptions').delete().eq('endpoint', endpoint));
}

/**
 * Keeps the device registered: refreshes its time zone and last-seen time,
 * and subscribes silently when notifications are allowed but this device has
 * no live subscription — after a sign-in, a dropped subscription or a key
 * change. Notifications are on by default: only the user's own Turn off on
 * this device keeps it unsubscribed. Never prompts.
 */
export async function syncPushSubscription(): Promise<void> {
  if (pushSupport() !== 'ok' || Notification.permission !== 'granted') return;
  const subscription = await currentSubscription();
  if (subscription && usesCurrentKey(subscription)) {
    await registerSubscription(subscription);
    return;
  }
  if (readPref(StorageKeys.pushOff) !== '1') await enablePush();
}

/** Signing out must stop this device receiving that account's notifications. Best effort: never blocks the sign-out. */
export async function releasePushForSignOut(): Promise<void> {
  try {
    await disablePush({ byUser: false });
  } catch {
    // The browser side is done first in disablePush; a failed server cleanup leaves a row that
    // the sender switches off on its first 404/410.
  }
}

// ---------------------------------------------------------------------------
// The four switches (`notification_preferences`)
// ---------------------------------------------------------------------------

export type NotificationPrefs = { daily: boolean; summary: boolean; lowBalance: boolean; cardDue: boolean };
export type NotificationPref = keyof NotificationPrefs;

/** All on: nothing is sent to a device that has not been turned on, so this changes nothing until then. */
export const DEFAULT_NOTIFICATION_PREFS: NotificationPrefs = { daily: true, summary: true, lowBalance: true, cardDue: true };

const COLUMNS: Record<NotificationPref, string> = {
  daily: 'daily_reminder',
  summary: 'spending_summary',
  lowBalance: 'low_balance',
  cardDue: 'card_due',
};

export async function fetchNotificationPrefs(userId: string): Promise<NotificationPrefs> {
  const { data, error } = await getSupabase()
    .from('notification_preferences')
    .select('daily_reminder, spending_summary, low_balance, card_due')
    .eq('user_id', userId)
    .maybeSingle();
  if (error) throw error;
  if (!data) return DEFAULT_NOTIFICATION_PREFS;
  const row = data as Record<string, unknown>;
  const on = (column: string) => row[column] !== false;
  return { daily: on(COLUMNS.daily), summary: on(COLUMNS.summary), lowBalance: on(COLUMNS.lowBalance), cardDue: on(COLUMNS.cardDue) };
}

export async function saveNotificationPref(userId: string, pref: NotificationPref, value: boolean): Promise<void> {
  ensureOk(
    await getSupabase()
      .from('notification_preferences')
      .upsert({ user_id: userId, [COLUMNS[pref]]: value, updated_at: new Date().toISOString() }, { onConflict: 'user_id' }),
  );
}
