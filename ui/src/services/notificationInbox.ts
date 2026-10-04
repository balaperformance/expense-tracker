/**
 * The in-app notification history (notification_log, migration 010). The
 * push-notify sender writes the rows; the app only reads its own and marks
 * them read — RLS and a column grant on read_at allow nothing more.
 */
import { inboxFromRows, type InboxItem } from '@/domain/notifications/inbox';

import { db, ensureOk, nowIso, rowsOf } from './db';

/** Enough for a long history on one screen; the sender prunes rows after 120 days. */
export const INBOX_LIMIT = 100;

export async function fetchInbox(userId: string): Promise<InboxItem[]> {
  const result = await db()
    .from('notification_log')
    .select('event_key, kind, sent_at, title, body, url, read_at')
    .eq('user_id', userId)
    .order('sent_at', { ascending: false })
    .limit(INBOX_LIMIT);
  return inboxFromRows(rowsOf(result));
}

export async function markInboxRead(userId: string, key: string): Promise<void> {
  ensureOk(
    await db()
      .from('notification_log')
      .update({ read_at: nowIso() })
      .eq('user_id', userId)
      .eq('event_key', key)
      .is('read_at', null),
  );
}

export async function markAllInboxRead(userId: string): Promise<void> {
  ensureOk(await db().from('notification_log').update({ read_at: nowIso() }).eq('user_id', userId).is('read_at', null));
}
