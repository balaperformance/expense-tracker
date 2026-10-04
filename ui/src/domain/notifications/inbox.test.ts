import { describe, expect, it } from 'vitest';

import { badgeLabel, inboxFromRows, itemFromRow, kindLabel, safePath, sentLabel, unreadCount, withRead } from './inbox';

// Invented rows in the shape notification_log returns (migration 010).
const row = (over: Record<string, unknown> = {}) => ({
  event_key: 'daily:2026-10-03',
  kind: 'daily',
  sent_at: '2026-10-03T16:30:00Z',
  title: 'Expense Tracker',
  body: "Today's spending: ₹370.50. Don't forget to add any missing expenses.",
  url: '/expenses/new',
  read_at: null,
  ...over,
});

describe('a history row', () => {
  it('is titled by its kind when the push title is only the app’s name', () => {
    const item = itemFromRow(row());
    expect(item).toMatchObject({ key: 'daily:2026-10-03', title: 'Daily expense reminder', path: '/expenses/new', read: false });
    expect(item?.body).toContain('₹370.50');
  });

  it('keeps a title that says more than the app’s name (a future kind)', () => {
    expect(itemFromRow(row({ kind: 'weekly', title: 'Your week in review' }))?.title).toBe('Your week in review');
  });

  it('gives a kind it does not know a generic label', () => {
    expect(itemFromRow(row({ kind: 'somethingNew', title: null }))?.title).toBe('Notification');
    expect(kindLabel('lowBalance')).toBe('Low balance');
    expect(kindLabel('cardDue')).toBe('Credit card due');
    expect(kindLabel('summary')).toBe('Spending summary');
  });

  it('reads a row from before migration 010 (no text) by its kind alone', () => {
    const item = itemFromRow(row({ kind: 'cardDue', title: null, body: null, url: null }));
    expect(item).toMatchObject({ title: 'Credit card due', body: '', path: null });
  });

  it('is read once read_at is set', () => {
    expect(itemFromRow(row({ read_at: '2026-10-03T17:00:00Z' }))?.read).toBe(true);
  });

  it('is dropped when it has no key or no valid time', () => {
    expect(itemFromRow(row({ event_key: '' }))).toBeNull();
    expect(itemFromRow(row({ sent_at: 'not a date' }))).toBeNull();
  });
});

describe('links', () => {
  it('only ever leads inside the app', () => {
    expect(safePath('/accounts/a1')).toBe('/accounts/a1');
    expect(safePath('https://evil.example')).toBeNull();
    expect(safePath('//evil.example')).toBeNull();
    expect(safePath(null)).toBeNull();
    expect(safePath(`/${'x'.repeat(300)}`)).toBeNull();
  });
});

describe('the list', () => {
  const rows = [
    row({ event_key: 'a', sent_at: '2026-10-01T10:00:00Z' }),
    row({ event_key: 'c', sent_at: '2026-10-03T10:00:00Z', read_at: '2026-10-03T11:00:00Z' }),
    row({ event_key: 'b', sent_at: '2026-10-02T10:00:00Z' }),
    row({ event_key: '' }),
  ];

  it('is newest first and skips malformed rows', () => {
    expect(inboxFromRows(rows).map((i) => i.key)).toEqual(['c', 'b', 'a']);
  });

  it('counts the unread, and the badge caps at 99+', () => {
    const items = inboxFromRows(rows);
    expect(unreadCount(items)).toBe(2);
    expect(badgeLabel(0)).toBeUndefined();
    expect(badgeLabel(7)).toBe('7');
    expect(badgeLabel(140)).toBe('99+');
  });

  it('marks one, or all, read without reordering', () => {
    const items = inboxFromRows(rows);
    expect(withRead(items, new Set(['a'])).map((i) => [i.key, i.read])).toEqual([
      ['c', true],
      ['b', false],
      ['a', true],
    ]);
    expect(unreadCount(withRead(items))).toBe(0);
  });
});

describe('when it was sent', () => {
  it('reads as a day and a time on the device’s clock', () => {
    const now = new Date(2026, 9, 4, 9, 0);
    expect(sentLabel(new Date(2026, 9, 4, 8, 5), now)).toBe('Today · 8:05 AM');
    expect(sentLabel(new Date(2026, 9, 3, 22, 0), now)).toBe('Yesterday · 10:00 PM');
  });
});
