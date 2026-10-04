/**
 * The in-app notification history: every notification the push-notify sender
 * produced (notification_log, migration 010), newest first, read or unread.
 *
 * Pure: the rows are read in services/notificationInbox.ts.
 */
import { toIso } from '@/lib/dates';
import { formatTime, relativeDay } from '@/lib/format';
import { optStr, str, type Row } from '@/lib/row';

/** The four kinds the sender knows today. Any other kind still shows, under a generic label. */
export type KnownKind = 'daily' | 'summary' | 'lowBalance' | 'cardDue';

export type InboxItem = {
  /** The sender's event key: unique per user. */
  key: string;
  kind: string;
  title: string;
  body: string;
  /** A path inside the app, or null when there is nowhere to go. */
  path: string | null;
  sentAt: Date;
  read: boolean;
};

/** The sender's push title is the app's name on every message; the kind says more in a list. */
const GENERIC_PUSH_TITLE = 'Expense Tracker';

const LABELS: Record<KnownKind, string> = {
  daily: 'Daily expense reminder',
  summary: 'Spending summary',
  lowBalance: 'Low balance',
  cardDue: 'Credit card due',
};

export const isKnownKind = (kind: string): kind is KnownKind => Object.hasOwn(LABELS, kind);

export const kindLabel = (kind: string): string => (isKnownKind(kind) ? LABELS[kind] : 'Notification');

/** A path inside this app, or null. Anything else a row might hold is ignored (as the service worker does). */
export function safePath(value: string | null): string | null {
  if (!value || !value.startsWith('/') || value.startsWith('//') || value.length > 200) return null;
  return value;
}

export function itemFromRow(row: Row): InboxItem | null {
  const key = str(row, 'event_key');
  const sentAt = new Date(str(row, 'sent_at'));
  if (!key || Number.isNaN(sentAt.getTime())) return null;
  const kind = str(row, 'kind');
  const title = optStr(row, 'title')?.trim();
  return {
    key,
    kind,
    // A message names itself only when it says more than the app's name; rows from before 010 have no text at all.
    title: title && title !== GENERIC_PUSH_TITLE ? title : kindLabel(kind),
    body: optStr(row, 'body')?.trim() ?? '',
    path: safePath(optStr(row, 'url')),
    sentAt,
    read: optStr(row, 'read_at') != null,
  };
}

/** Newest first; a malformed row is dropped rather than breaking the list. */
export function inboxFromRows(rows: readonly Row[]): InboxItem[] {
  return rows
    .map(itemFromRow)
    .filter((item): item is InboxItem => item != null)
    .sort((a, b) => b.sentAt.getTime() - a.sentAt.getTime());
}

export const unreadCount = (items: readonly InboxItem[]) => items.filter((item) => !item.read).length;

/** The bell's badge: the count, capped so it fits the dot. */
export const badgeLabel = (count: number): string | undefined => (count <= 0 ? undefined : count > 99 ? '99+' : String(count));

/** "Today · 10:00 PM", "Yesterday · 8:00 PM", "12 Mar · 9:00 AM" — in the device's own time. */
export function sentLabel(sentAt: Date, now: Date = new Date()): string {
  const hhmm = `${String(sentAt.getHours()).padStart(2, '0')}:${String(sentAt.getMinutes()).padStart(2, '0')}`;
  return `${relativeDay(toIso(sentAt), now)} · ${formatTime(hhmm)}`;
}

/** Marks [keys] (or every item) read without reordering — the optimistic view of a mark-read. */
export function withRead(items: readonly InboxItem[], keys?: ReadonlySet<string>): InboxItem[] {
  return items.map((item) => (item.read || (keys && !keys.has(item.key)) ? item : { ...item, read: true }));
}
