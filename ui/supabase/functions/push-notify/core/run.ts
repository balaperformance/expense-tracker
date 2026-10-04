/**
 * What to send, to whom and when — with nothing here that touches a network,
 * a database or the clock, so every rule is unit-tested with fakes.
 *
 * The Edge Function calls [runNotifications] every 15 minutes. For each user
 * with a subscribed device it reads that user's own wall clock and decides
 * which of the four notifications are due *now*:
 *
 *   daily        22:00–22:59 local            once per local date
 *   summary      20:00–20:59 local on the 16th and on the month's last day
 *                16th → spending 1st–15th; last day → the whole month
 *   card due     from 09:00 local on the day before a bill's due date, once
 *                per card + due date, and only while the bill is unpaid
 *   low balance  once per spell below the threshold for each active account,
 *                including one already low when first seen; again only after
 *                it has recovered
 *
 * Every event has a deterministic key (see the `*Key` helpers). The key is
 * CLAIMED with a unique insert before anything is sent, so overlapping runs
 * and retries cannot produce the same notification twice. A claim is given
 * back only when every device failed for a reason that may pass (network, 5xx)
 * so the next run tries again.
 */
import type { AccountBalance } from './balances.ts';
import type { CardDue } from './cards.ts';
import { addDays, firstOfMonth, lastOfMonth, localClock, parts, type IsoDate } from './dates.ts';
import { formatAmount } from './money.ts';

/** Fixed by the product: below ₹500. */
export const LOW_BALANCE_CENTS = 50_000;
export const DAILY_HOUR = 22;
export const SUMMARY_HOUR = 20;
/** The day-before card reminder goes out from 09:00 local, not at midnight. */
export const CARD_DUE_FROM_HOUR = 9;
/** The day of the month the mid-month summary is sent. */
export const MID_MONTH_DAY = 16;

export type NotificationKind = 'daily' | 'summary' | 'lowBalance' | 'cardDue';

export type Preferences = { daily: boolean; summary: boolean; lowBalance: boolean; cardDue: boolean };

/** A user with at least one subscribed device. */
export type NotifyUser = { userId: string; timezone: string; currency: string; prefs: Preferences };

/** What travels to the device. Amounts are what the user asked to see; no ids of people, accounts or amounts beyond that. */
export type PushMessage = { title: string; body: string; url: string; tag: string };

export type SendResult = {
  /** Devices that accepted the message. */
  delivered: number;
  /** Devices whose subscription the push service reported gone (and which were switched off). */
  removed: number;
  /** Failures that may pass: network trouble, a 5xx. */
  retryable: number;
};

export type LowBalanceState = { isLow: boolean; episode: number };

export interface NotifyStore {
  /** Users with an active subscription, with their preferences, time zone and currency. */
  listUsers(): Promise<NotifyUser[]>;
  /** Personal spending from [from] to [to] inclusive, in cents (see spending.ts). */
  spendingCents(userId: string, from: IsoDate, to: IsoDate): Promise<number>;
  /** Every bank account's balance (see balances.ts). */
  accountBalances(userId: string): Promise<AccountBalance[]>;
  /** Unpaid card bills due tomorrow (see cards.ts). */
  cardsDueTomorrow(userId: string, today: IsoDate): Promise<CardDue[]>;
  lowBalanceStates(userId: string): Promise<Map<string, LowBalanceState>>;
  setLowBalanceState(userId: string, accountId: string, state: LowBalanceState): Promise<void>;
  /** Records [key] for the user; false when it was already recorded (so: already sent). */
  claim(userId: string, key: string, kind: NotificationKind): Promise<boolean>;
  release(userId: string, key: string): Promise<void>;
}

export interface PushSender {
  send(userId: string, message: PushMessage): Promise<SendResult>;
}

export type RunReport = {
  users: number;
  sent: Record<NotificationKind, number>;
  /** Users whose run stopped on an error (never their data). */
  failed: number;
};

// ---------------------------------------------------------------------------
// Event keys
// ---------------------------------------------------------------------------

export const dailyKey = (date: IsoDate) => `daily:${date}`;
export const summaryKey = (date: IsoDate, period: 'mid' | 'end') => `summary:${date.slice(0, 7)}:${period}`;
export const cardDueKey = (cardId: string, dueDate: IsoDate) => `card:${cardId}:${dueDate}`;
export const lowBalanceKey = (accountId: string, episode: number) => `low:${accountId}:${episode}`;

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

const TITLE = 'Expense Tracker';

export function dailyMessage(cents: number, currency: string): PushMessage {
  return {
    title: TITLE,
    body: `Today's spending: ${formatAmount(cents, currency)}. Don't forget to add any missing expenses.`,
    url: '/expenses/new',
    tag: 'daily',
  };
}

export function summaryMessage(cents: number, currency: string, period: 'mid' | 'end'): PushMessage {
  const when = period === 'mid' ? 'so far this month' : 'this month';
  return { title: TITLE, body: `Spending update: ${formatAmount(cents, currency)} spent ${when}.`, url: '/reports', tag: 'summary' };
}

export function lowBalanceMessage(account: AccountBalance, currency: string): PushMessage {
  return {
    title: TITLE,
    body: `Low balance: ${account.name} is ${formatAmount(account.balanceCents, currency)}.`,
    url: `/accounts/${account.id}`,
    tag: `low-${account.id}`,
  };
}

export function cardDueMessage(card: CardDue): PushMessage {
  return {
    title: TITLE,
    body: `Credit card reminder: ${card.name} payment is due tomorrow.`,
    url: `/cards/${card.cardId}`,
    tag: `card-${card.cardId}`,
  };
}

// ---------------------------------------------------------------------------
// What is due on a user's clock
// ---------------------------------------------------------------------------

/** The summary due now, or null: 16th (the 1st–15th) or the last day (the whole month), in the 20:00 hour. */
export function summaryDue(clock: { date: IsoDate; hour: number }): { period: 'mid' | 'end'; from: IsoDate; to: IsoDate } | null {
  if (clock.hour !== SUMMARY_HOUR) return null;
  const { day } = parts(clock.date);
  const first = firstOfMonth(clock.date);
  if (day === MID_MONTH_DAY) return { period: 'mid', from: first, to: addDays(first, MID_MONTH_DAY - 2) };
  if (clock.date === lastOfMonth(clock.date)) return { period: 'end', from: first, to: clock.date };
  return null;
}

// ---------------------------------------------------------------------------
// The run
// ---------------------------------------------------------------------------

/** Every device failed for a reason that may pass, and none got it: try again next run. */
const shouldRetry = (result: SendResult) => result.delivered === 0 && result.retryable > 0;

/** Claims [key], sends what [build] makes, and gives the claim back if the send should be retried. Returns whether it was sent. */
async function deliver(
  store: NotifyStore,
  sender: PushSender,
  user: NotifyUser,
  kind: NotificationKind,
  key: string,
  build: () => Promise<PushMessage>,
): Promise<{ sent: boolean; retry: boolean }> {
  if (!(await store.claim(user.userId, key, kind))) return { sent: false, retry: false };
  try {
    const result = await sender.send(user.userId, await build());
    if (shouldRetry(result)) {
      await store.release(user.userId, key);
      return { sent: false, retry: true };
    }
    return { sent: result.delivered > 0, retry: false };
  } catch (error) {
    await store.release(user.userId, key);
    throw error;
  }
}

async function runUser(user: NotifyUser, now: Date, store: NotifyStore, sender: PushSender, sent: Record<NotificationKind, number>) {
  const clock = localClock(now, user.timezone);
  if (!clock) return; // not a real time zone: nothing can be scheduled for this user
  const count = (kind: NotificationKind, outcome: { sent: boolean }) => {
    if (outcome.sent) sent[kind] += 1;
  };

  if (user.prefs.daily && clock.hour === DAILY_HOUR) {
    count(
      'daily',
      await deliver(store, sender, user, 'daily', dailyKey(clock.date), async () =>
        dailyMessage(await store.spendingCents(user.userId, clock.date, clock.date), user.currency),
      ),
    );
  }

  const summary = user.prefs.summary ? summaryDue(clock) : null;
  if (summary) {
    count(
      'summary',
      await deliver(store, sender, user, 'summary', summaryKey(clock.date, summary.period), async () =>
        summaryMessage(await store.spendingCents(user.userId, summary.from, summary.to), user.currency, summary.period),
      ),
    );
  }

  if (user.prefs.cardDue && clock.hour >= CARD_DUE_FROM_HOUR) {
    for (const card of await store.cardsDueTomorrow(user.userId, clock.date)) {
      count('cardDue', await deliver(store, sender, user, 'cardDue', cardDueKey(card.cardId, card.dueDate), () => Promise.resolve(cardDueMessage(card))));
    }
  }

  await runLowBalance(user, store, sender, sent);
}

/**
 * One alert per spell below the threshold, for every active account, while
 * the switch is on. The state records the spell already alerted: `isLow`
 * with `episode` > 0 means "alerted, still low". So an account that is
 * already low the first time it is seen is alerted, and so is a spell that
 * began while the switch was off, once it is turned on. A row `isLow` with
 * episode 0 was written by an earlier version on its first look, without an
 * alert — it is alerted now.
 */
async function runLowBalance(user: NotifyUser, store: NotifyStore, sender: PushSender, sent: Record<NotificationKind, number>) {
  const [balances, states] = await Promise.all([store.accountBalances(user.userId), store.lowBalanceStates(user.userId)]);
  for (const account of balances) {
    if (!account.isActive) continue;
    const low = account.balanceCents < LOW_BALANCE_CENTS;
    const previous = states.get(account.id);
    const episode = previous?.episode ?? 0;
    if (!low) {
      // Recovered: the next drop is a new spell.
      if (previous?.isLow) await store.setLowBalanceState(user.userId, account.id, { isLow: false, episode });
      continue;
    }
    const alerted = previous?.isLow === true && episode > 0;
    if (alerted || !user.prefs.lowBalance) continue;

    const next: LowBalanceState = { isLow: true, episode: episode + 1 };
    const outcome = await deliver(store, sender, user, 'lowBalance', lowBalanceKey(account.id, next.episode), () =>
      Promise.resolve(lowBalanceMessage(account, user.currency)),
    );
    if (outcome.retry) continue; // nothing recorded, so the next run tries the same spell again
    if (outcome.sent) sent.lowBalance += 1;
    await store.setLowBalanceState(user.userId, account.id, next);
  }
}

export async function runNotifications(now: Date, store: NotifyStore, sender: PushSender): Promise<RunReport> {
  const users = await store.listUsers();
  const sent: Record<NotificationKind, number> = { daily: 0, summary: 0, lowBalance: 0, cardDue: 0 };
  let failed = 0;
  for (const user of users) {
    try {
      await runUser(user, now, store, sender, sent);
    } catch (error) {
      // One user's trouble must not stop everyone else's notifications.
      failed += 1;
      console.error('push-notify: a user run failed:', error instanceof Error ? error.message : 'unknown error');
    }
  }
  return { users: users.length, sent, failed };
}
