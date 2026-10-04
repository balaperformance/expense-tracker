import { describe, expect, it, vi } from 'vitest';

import { accountBalances, type AccountRow, type LedgerRow } from '../../../supabase/functions/push-notify/core/balances.ts';
import { cardsDueTomorrow, type CardEntryRow, type CardRow } from '../../../supabase/functions/push-notify/core/cards.ts';
import { localClock } from '../../../supabase/functions/push-notify/core/dates.ts';
import { formatAmount } from '../../../supabase/functions/push-notify/core/money.ts';
import { isGoneStatus, isRetryableStatus } from '../../../supabase/functions/push-notify/core/pushStatus.ts';
import {
  cardDueKey,
  dailyKey,
  lowBalanceKey,
  runNotifications,
  summaryDue,
  summaryKey,
  type LowBalanceState,
  type NotifyStore,
  type NotifyUser,
  type Preferences,
  type PushMessage,
  type PushSender,
  type SendResult,
} from '../../../supabase/functions/push-notify/core/run.ts';
import { personalSpendingCents, type ExpenseRow } from '../../../supabase/functions/push-notify/core/spending.ts';

// ---------------------------------------------------------------------------
// Fixtures: in-memory stand-ins for the database and the push service. Nothing
// here is a real account — these are invented rows.
// ---------------------------------------------------------------------------

const ALL_ON: Preferences = { daily: true, summary: true, lowBalance: true, cardDue: true };

type UserData = {
  expenses?: ExpenseRow[];
  paidFor?: string[];
  accounts?: AccountRow[];
  ledger?: LedgerRow[];
  cards?: CardRow[];
  cardEntries?: CardEntryRow[];
};

class FakeStore implements NotifyStore {
  readonly claimed = new Set<string>();
  readonly states = new Map<string, LowBalanceState>();
  readonly spendingRequests: Array<{ from: string; to: string }> = [];
  failFor: string | null = null;

  constructor(
    private readonly users: NotifyUser[],
    readonly data: Record<string, UserData> = {},
  ) {}

  listUsers() {
    return Promise.resolve(this.users);
  }

  spendingCents(userId: string, from: string, to: string) {
    if (this.failFor === userId) return Promise.reject(new Error('boom'));
    this.spendingRequests.push({ from, to });
    const d = this.data[userId];
    return Promise.resolve(personalSpendingCents(d?.expenses ?? [], new Set(d?.paidFor ?? []), from, to));
  }

  accountBalances(userId: string) {
    const d = this.data[userId];
    return Promise.resolve(accountBalances(d?.accounts ?? [], d?.ledger ?? []));
  }

  cardsDueTomorrow(userId: string, today: string) {
    const d = this.data[userId];
    return Promise.resolve(cardsDueTomorrow(d?.cards ?? [], d?.cardEntries ?? [], today));
  }

  lowBalanceStates(userId: string) {
    return Promise.resolve(new Map([...this.states].filter(([k]) => k.startsWith(`${userId}|`)).map(([k, v]) => [k.split('|')[1] ?? '', v])));
  }

  setLowBalanceState(userId: string, accountId: string, state: LowBalanceState) {
    this.states.set(`${userId}|${accountId}`, state);
    return Promise.resolve();
  }

  claim(userId: string, key: string) {
    const full = `${userId}|${key}`;
    if (this.claimed.has(full)) return Promise.resolve(false);
    this.claimed.add(full);
    return Promise.resolve(true);
  }

  release(userId: string, key: string) {
    this.claimed.delete(`${userId}|${key}`);
    this.saved.delete(`${userId}|${key}`);
    return Promise.resolve();
  }

  /** What the in-app history would show, by `user|key`. */
  readonly saved = new Map<string, PushMessage>();
  failSaving = false;

  saveMessage(userId: string, key: string, message: PushMessage) {
    if (this.failSaving) return Promise.reject(new Error('column missing'));
    this.saved.set(`${userId}|${key}`, message);
    return Promise.resolve();
  }
}

class FakeSender implements PushSender {
  readonly sent: Array<{ userId: string; message: PushMessage }> = [];
  results: SendResult[] = [];

  send(userId: string, message: PushMessage) {
    const result = this.results.shift() ?? { delivered: 1, removed: 0, retryable: 0 };
    if (result.delivered > 0) this.sent.push({ userId, message });
    return Promise.resolve(result);
  }

  bodies(userId?: string) {
    return this.sent.filter((s) => userId == null || s.userId === userId).map((s) => s.message.body);
  }
}

const user = (id: string, timezone = 'Asia/Kolkata', prefs: Partial<Preferences> = {}): NotifyUser => ({
  userId: id,
  timezone,
  currency: 'INR',
  prefs: { ...ALL_ON, ...prefs },
});

/** An instant given as Asia/Kolkata wall time (UTC+5:30, no daylight saving). */
const ist = (isoDateTime: string) => new Date(`${isoDateTime}:00+05:30`);

const account = (id: string, name: string, opening: number, isActive = true): AccountRow => ({ id, name, openingBalance: opening, isActive });

// ---------------------------------------------------------------------------
// The user's own clock
// ---------------------------------------------------------------------------

describe('reading the user’s own clock', () => {
  it('converts an instant to the zone’s date and time, across midnight', () => {
    expect(localClock(new Date('2026-10-03T16:30:00Z'), 'Asia/Kolkata')).toEqual({ date: '2026-10-03', hour: 22, minute: 0 });
    // 20:00 UTC is already the next morning in India…
    expect(localClock(new Date('2026-10-03T20:00:00Z'), 'Asia/Kolkata')).toEqual({ date: '2026-10-04', hour: 1, minute: 30 });
    // …and still the afternoon in California (daylight saving, UTC-7).
    expect(localClock(new Date('2026-10-03T20:00:00Z'), 'America/Los_Angeles')).toEqual({ date: '2026-10-03', hour: 13, minute: 0 });
  });

  it('reads midnight as hour 0, not 24', () => {
    expect(localClock(new Date('2026-10-03T18:30:00Z'), 'Asia/Kolkata')).toEqual({ date: '2026-10-04', hour: 0, minute: 0 });
  });

  it('is nothing for a time zone that does not exist', () => {
    expect(localClock(new Date('2026-10-03T16:30:00Z'), 'Mars/Olympus')).toBeNull();
    expect(localClock(new Date('2026-10-03T16:30:00Z'), '')).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// 1. Daily reminder
// ---------------------------------------------------------------------------

describe('the daily expense reminder', () => {
  const expenses: ExpenseRow[] = [
    { id: 'e1', amount: 250.5, date: '2026-10-03' },
    { id: 'e2', amount: 120, date: '2026-10-03' },
    { id: 'e3', amount: 999, date: '2026-10-02' },
    { id: 'paid', amount: 5000, date: '2026-10-03' }, // paid for someone else: not the user's spending
  ];

  it('sends today’s personal spending at 10 PM local', async () => {
    const store = new FakeStore([user('u1')], { u1: { expenses, paidFor: ['paid'] } });
    const sender = new FakeSender();
    const report = await runNotifications(ist('2026-10-03T22:05'), store, sender);
    expect(sender.bodies()).toEqual(["Today's spending: ₹370.50. Don't forget to add any missing expenses."]);
    expect(report.sent.daily).toBe(1);
    expect(sender.sent[0]?.message.url).toBe('/expenses/new');
  });

  it('still sends when nothing was spent, with ₹0', async () => {
    const sender = new FakeSender();
    await runNotifications(ist('2026-10-03T22:00'), new FakeStore([user('u1')]), sender);
    expect(sender.bodies()).toEqual(["Today's spending: ₹0. Don't forget to add any missing expenses."]);
  });

  it('is not sent before or after the 10 PM hour', async () => {
    for (const time of ['2026-10-03T21:59', '2026-10-03T23:00', '2026-10-03T09:00']) {
      const sender = new FakeSender();
      await runNotifications(ist(time), new FakeStore([user('u1')]), sender);
      expect(sender.sent).toHaveLength(0);
    }
  });

  it('is sent once a day however often the schedule runs', async () => {
    const store = new FakeStore([user('u1')]);
    const sender = new FakeSender();
    for (const time of ['22:00', '22:15', '22:30', '22:45']) await runNotifications(ist(`2026-10-03T${time}`), store, sender);
    expect(sender.sent).toHaveLength(1);
    expect(store.claimed.has(`u1|${dailyKey('2026-10-03')}`)).toBe(true);
    // The next evening is a new event.
    await runNotifications(ist('2026-10-04T22:00'), store, sender);
    expect(sender.sent).toHaveLength(2);
  });

  it('follows each user’s own time zone', async () => {
    const store = new FakeStore([user('india'), user('la', 'America/Los_Angeles')]);
    const sender = new FakeSender();
    // 16:30 UTC is 22:00 in India and 09:30 in Los Angeles.
    await runNotifications(new Date('2026-10-03T16:30:00Z'), store, sender);
    expect(sender.sent.map((s) => s.userId)).toEqual(['india']);
    // 05:00 UTC the next day is 22:00 in Los Angeles.
    await runNotifications(new Date('2026-10-04T05:00:00Z'), store, sender);
    expect(sender.sent.map((s) => s.userId)).toEqual(['india', 'la']);
  });

  it('is not sent when the switch is off', async () => {
    const sender = new FakeSender();
    await runNotifications(ist('2026-10-03T22:00'), new FakeStore([user('u1', 'Asia/Kolkata', { daily: false })]), sender);
    expect(sender.sent).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// 2. Spending summary
// ---------------------------------------------------------------------------

describe('which days carry the spending summary', () => {
  it('is the 16th, covering the 1st to the 15th', () => {
    expect(summaryDue({ date: '2026-10-16', hour: 20 })).toEqual({ period: 'mid', from: '2026-10-01', to: '2026-10-15' });
  });

  it('is the month’s last day, covering the whole month', () => {
    expect(summaryDue({ date: '2026-10-31', hour: 20 })).toEqual({ period: 'end', from: '2026-10-01', to: '2026-10-31' });
    expect(summaryDue({ date: '2026-09-30', hour: 20 })).toEqual({ period: 'end', from: '2026-09-01', to: '2026-09-30' });
  });

  it('knows short months and leap years', () => {
    expect(summaryDue({ date: '2027-02-28', hour: 20 })?.period).toBe('end');
    expect(summaryDue({ date: '2027-02-27', hour: 20 })).toBeNull();
    expect(summaryDue({ date: '2028-02-29', hour: 20 })?.period).toBe('end');
    expect(summaryDue({ date: '2028-02-28', hour: 20 })).toBeNull();
  });

  it('is no other day, and no other hour', () => {
    expect(summaryDue({ date: '2026-10-15', hour: 20 })).toBeNull();
    expect(summaryDue({ date: '2026-10-17', hour: 20 })).toBeNull();
    expect(summaryDue({ date: '2026-10-16', hour: 19 })).toBeNull();
    expect(summaryDue({ date: '2026-10-16', hour: 21 })).toBeNull();
  });
});

describe('the spending summary', () => {
  const expenses: ExpenseRow[] = [
    { id: 'a', amount: 1000, date: '2026-10-01' },
    { id: 'b', amount: 2450, date: '2026-10-15' },
    { id: 'c', amount: 700, date: '2026-10-16' }, // after the half-month window
    { id: 'd', amount: 8300, date: '2026-10-31' },
    { id: 'x', amount: 9999, date: '2026-10-10' }, // paid for someone else
    { id: 'o', amount: 400, date: '2026-09-30' }, // another month
  ];

  it('on the 16th reports the 1st–15th only', async () => {
    const sender = new FakeSender();
    const store = new FakeStore([user('u1')], { u1: { expenses, paidFor: ['x'] } });
    await runNotifications(ist('2026-10-16T20:10'), store, sender);
    expect(sender.bodies()).toEqual(['Spending update: ₹3,450 spent so far this month.']);
    expect(store.spendingRequests).toEqual([{ from: '2026-10-01', to: '2026-10-15' }]);
    expect(sender.sent[0]?.message.url).toBe('/reports');
  });

  it('on the last day reports the complete month', async () => {
    const sender = new FakeSender();
    const store = new FakeStore([user('u1')], { u1: { expenses, paidFor: ['x'] } });
    await runNotifications(ist('2026-10-31T20:00'), store, sender);
    expect(sender.bodies()).toEqual(['Spending update: ₹12,450 spent this month.']);
  });

  it('is sent once per occasion, and each occasion has its own key', async () => {
    const store = new FakeStore([user('u1')]);
    const sender = new FakeSender();
    for (const time of ['20:00', '20:15', '20:30', '20:45']) await runNotifications(ist(`2026-10-16T${time}`), store, sender);
    expect(sender.sent).toHaveLength(1);
    expect(summaryKey('2026-10-16', 'mid')).not.toBe(summaryKey('2026-10-31', 'end'));
    expect(summaryKey('2026-10-16', 'mid')).not.toBe(summaryKey('2026-11-16', 'mid'));
  });

  it('is not sent when the switch is off', async () => {
    const sender = new FakeSender();
    await runNotifications(ist('2026-10-16T20:00'), new FakeStore([user('u1', 'Asia/Kolkata', { summary: false })]), sender);
    expect(sender.sent).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// 3. Credit card due date
// ---------------------------------------------------------------------------

describe('the credit card due-date reminder', () => {
  // Statement on the 5th, due on the 25th. The 5 Oct statement is due 25 Oct.
  const card: CardRow = { id: 'visa', name: 'HDFC Visa', statementDay: 5, paymentDueDay: 25, openingOutstanding: 0, isActive: true };
  const bill: CardEntryRow[] = [{ cardId: 'visa', direction: 'debit', amount: 4200, date: '2026-09-20' }];

  it('reminds the day before the due date, from 9 AM', async () => {
    const sender = new FakeSender();
    const store = new FakeStore([user('u1')], { u1: { cards: [card], cardEntries: bill } });
    await runNotifications(ist('2026-10-24T09:00'), store, sender);
    expect(sender.bodies()).toEqual(['Credit card reminder: HDFC Visa payment is due tomorrow.']);
    expect(sender.sent[0]?.message.url).toBe('/cards/visa');
  });

  it('does not remind before 9 AM, on other days, or on the due date itself', async () => {
    for (const time of ['2026-10-24T08:45', '2026-10-23T12:00', '2026-10-25T12:00', '2026-10-26T12:00']) {
      const sender = new FakeSender();
      await runNotifications(ist(time), new FakeStore([user('u1')], { u1: { cards: [card], cardEntries: bill } }), sender);
      expect(sender.sent).toHaveLength(0);
    }
  });

  it('sends one reminder per card and due date, however often it runs', async () => {
    const store = new FakeStore([user('u1')], { u1: { cards: [card], cardEntries: bill } });
    const sender = new FakeSender();
    for (const time of ['09:00', '12:00', '18:30', '22:00']) await runNotifications(ist(`2026-10-24T${time}`), store, sender);
    // (the 10 PM run also sends that evening's daily reminder, which is a different event)
    expect(sender.bodies().filter((body) => body.startsWith('Credit card'))).toHaveLength(1);
    expect(cardDueKey('visa', '2026-10-25')).not.toBe(cardDueKey('visa', '2026-11-25'));
    expect(cardDueKey('visa', '2026-10-25')).not.toBe(cardDueKey('amex', '2026-10-25'));
  });

  it('skips a bill that is already paid or that was nothing', async () => {
    const paid: CardEntryRow[] = [...bill, { cardId: 'visa', direction: 'credit', amount: 4200, date: '2026-10-10' }];
    const sender = new FakeSender();
    await runNotifications(ist('2026-10-24T10:00'), new FakeStore([user('u1')], { u1: { cards: [card], cardEntries: paid } }), sender);
    await runNotifications(ist('2026-10-24T10:00'), new FakeStore([user('u2')], { u2: { cards: [card], cardEntries: [] } }), sender);
    expect(sender.sent).toHaveLength(0);
  });

  it('uses the user’s own date, not the server’s', async () => {
    const store = new FakeStore([user('la', 'America/Los_Angeles')], { la: { cards: [card], cardEntries: bill } });
    const sender = new FakeSender();
    // 22:00 UTC on the 24th is still the 24th afternoon in Los Angeles: remind.
    await runNotifications(new Date('2026-10-24T22:00:00Z'), store, sender);
    expect(sender.sent).toHaveLength(1);
  });

  it('is not sent when the switch is off', async () => {
    const sender = new FakeSender();
    const store = new FakeStore([user('u1', 'Asia/Kolkata', { cardDue: false })], { u1: { cards: [card], cardEntries: bill } });
    await runNotifications(ist('2026-10-24T10:00'), store, sender);
    expect(sender.sent).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// 4. Low bank balance
// ---------------------------------------------------------------------------

describe('the low-balance alert', () => {
  const hdfc = account('hdfc', 'HDFC Savings', 1000);
  const debit = (amount: number): LedgerRow => ({ accountId: 'hdfc', direction: 'debit', amount });
  const credit = (amount: number): LedgerRow => ({ accountId: 'hdfc', direction: 'credit', amount });
  const at = (minutes: number) => new Date(Date.UTC(2026, 9, 5, 6, 0) + minutes * 60_000); // daytime in India: no scheduled kinds due

  /** Runs once per entry of [ledgers] — the ledger as it stands at each run. */
  async function simulate(ledgers: LedgerRow[][], prefs: Partial<Preferences> = {}, accounts = [hdfc]) {
    const data: UserData = { accounts };
    const store = new FakeStore([user('u1', 'Asia/Kolkata', prefs)], { u1: data });
    const sender = new FakeSender();
    for (const [i, ledger] of ledgers.entries()) {
      data.ledger = ledger;
      await runNotifications(at(i * 15), store, sender);
    }
    return { store, sender };
  }

  it('names the account and its balance when it drops below ₹500', async () => {
    const { sender } = await simulate([[], [debit(580)]]); // 1000 → 420
    expect(sender.bodies()).toEqual(['Low balance: HDFC Savings is ₹420.']);
    expect(sender.sent[0]?.message.url).toBe('/accounts/hdfc');
  });

  it('alerts an account that is already low the first time it is seen, once', async () => {
    const { sender, store } = await simulate([[debit(900)], [debit(900)], [debit(900)]]); // ₹100 from the start
    expect(sender.bodies()).toEqual(['Low balance: HDFC Savings is ₹100.']);
    expect(store.states.get('u1|hdfc')).toEqual({ isLow: true, episode: 1 });
  });

  it('alerts a low account an earlier version recorded on its first look without alerting', async () => {
    const store = new FakeStore([user('u1')], { u1: { accounts: [hdfc], ledger: [debit(900)] } });
    store.states.set('u1|hdfc', { isLow: true, episode: 0 });
    const sender = new FakeSender();
    await runNotifications(at(0), store, sender);
    await runNotifications(at(15), store, sender);
    expect(sender.bodies()).toEqual(['Low balance: HDFC Savings is ₹100.']);
    expect(store.states.get('u1|hdfc')).toEqual({ isLow: true, episode: 1 });
  });

  it('does not repeat while the balance stays low, however many checks run', async () => {
    const { sender } = await simulate([[], [debit(580)], [debit(580)], [debit(580), debit(100)], [debit(580), debit(100)]]);
    expect(sender.sent).toHaveLength(1);
  });

  it('notifies again only after it recovered to ₹500 or more and then fell again', async () => {
    const { sender } = await simulate([
      [], // 1000
      [debit(580)], // 420  → notify
      [debit(580), credit(80)], // 500: recovered (500 is not below 500)
      [debit(580), credit(80), debit(1)], // 499 → notify again
    ]);
    expect(sender.bodies()).toEqual(['Low balance: HDFC Savings is ₹420.', 'Low balance: HDFC Savings is ₹499.']);
  });

  it('treats exactly ₹500 as fine', async () => {
    const { sender } = await simulate([[], [debit(500)]]); // 1000 → 500
    expect(sender.sent).toHaveLength(0);
  });

  it('a recovery that never reaches ₹500 is not a recovery', async () => {
    const { sender } = await simulate([[], [debit(580)], [debit(580), credit(50)], [debit(580), credit(50), debit(60)]]); // 420, 470, 410
    expect(sender.sent).toHaveLength(1);
  });

  it('watches each account on its own', async () => {
    const savings = account('sav', 'Savings', 600);
    const { sender } = await simulate([[], [debit(580)]], {}, [hdfc, savings]); // only HDFC drops
    expect(sender.bodies()).toEqual(['Low balance: HDFC Savings is ₹420.']);
  });

  it('alerts every account that is low, each once', async () => {
    const savings = account('sav', 'Savings Account', 365.74);
    const salary = account('sal', 'Salary Account', 267.6);
    const { sender } = await simulate([[], [], []], {}, [savings, salary]);
    expect(sender.bodies()).toEqual(['Low balance: Savings Account is ₹365.74.', 'Low balance: Salary Account is ₹267.60.']);
  });

  it('ignores closed accounts', async () => {
    const { sender } = await simulate([[], [debit(580)]], {}, [account('hdfc', 'HDFC Savings', 1000, false)]);
    expect(sender.sent).toHaveLength(0);
  });

  it('sends nothing while the switch is off, and the current spell once it is turned on', async () => {
    const off = new FakeStore([user('u1', 'Asia/Kolkata', { lowBalance: false })], { u1: { accounts: [hdfc], ledger: [] } });
    const sender = new FakeSender();
    await runNotifications(at(0), off, sender);
    off.data.u1 = { accounts: [hdfc], ledger: [debit(580)] };
    await runNotifications(at(15), off, sender);
    await runNotifications(at(30), off, sender);
    expect(sender.sent).toHaveLength(0);

    // Switched on while still low: the spell has not been alerted yet, so it is — once.
    const on = new FakeStore([user('u1')], off.data);
    for (const [key, state] of off.states) on.states.set(key, state);
    await runNotifications(at(45), on, sender);
    await runNotifications(at(60), on, sender);
    expect(sender.bodies()).toEqual(['Low balance: HDFC Savings is ₹420.']);
  });

  it('tries again next run when no device could be reached, and does not lose the alert', async () => {
    const data: UserData = { accounts: [hdfc], ledger: [] };
    const store = new FakeStore([user('u1')], { u1: data });
    const sender = new FakeSender();
    await runNotifications(at(0), store, sender);
    data.ledger = [debit(580)];
    sender.results = [{ delivered: 0, removed: 0, retryable: 1 }]; // push service down
    await runNotifications(at(15), store, sender);
    expect(sender.sent).toHaveLength(0);
    await runNotifications(at(30), store, sender);
    expect(sender.bodies()).toEqual(['Low balance: HDFC Savings is ₹420.']);
    await runNotifications(at(45), store, sender);
    expect(sender.sent).toHaveLength(1);
  });

  it('gives each drop its own event key', () => {
    expect(lowBalanceKey('hdfc', 1)).not.toBe(lowBalanceKey('hdfc', 2));
    expect(lowBalanceKey('hdfc', 1)).not.toBe(lowBalanceKey('sav', 1));
  });
});

// ---------------------------------------------------------------------------
// Delivery
// ---------------------------------------------------------------------------

describe('delivery', () => {
  it('does not keep trying a user whose devices are all gone', async () => {
    const store = new FakeStore([user('u1')]);
    const sender = new FakeSender();
    sender.results = [{ delivered: 0, removed: 1, retryable: 0 }];
    await runNotifications(ist('2026-10-03T22:00'), store, sender);
    await runNotifications(ist('2026-10-03T22:15'), store, sender);
    expect(sender.sent).toHaveLength(0);
    expect(store.claimed.has(`u1|${dailyKey('2026-10-03')}`)).toBe(true);
  });

  it('retries a daily reminder in the same hour after a transient failure', async () => {
    const store = new FakeStore([user('u1')]);
    const sender = new FakeSender();
    sender.results = [{ delivered: 0, removed: 0, retryable: 2 }];
    await runNotifications(ist('2026-10-03T22:00'), store, sender);
    expect(sender.sent).toHaveLength(0);
    await runNotifications(ist('2026-10-03T22:15'), store, sender);
    expect(sender.sent).toHaveLength(1);
  });

  it('counts a message as sent when at least one device took it', async () => {
    const sender = new FakeSender();
    sender.results = [{ delivered: 1, removed: 1, retryable: 1 }];
    const report = await runNotifications(ist('2026-10-03T22:00'), new FakeStore([user('u1')]), sender);
    expect(report.sent.daily).toBe(1);
  });

  it('keeps going for everyone else when one user’s run fails', async () => {
    const store = new FakeStore([user('bad'), user('good')]);
    store.failFor = 'bad';
    const sender = new FakeSender();
    const report = await runNotifications(ist('2026-10-03T22:00'), store, sender);
    expect(report.failed).toBe(1);
    expect(sender.sent.map((s) => s.userId)).toEqual(['good']);
    // The failed user's claim was given back, so the next run can still send it.
    expect(store.claimed.has(`bad|${dailyKey('2026-10-03')}`)).toBe(false);
  });

  it('skips a user with an invalid time zone instead of failing', async () => {
    const sender = new FakeSender();
    const report = await runNotifications(ist('2026-10-03T22:00'), new FakeStore([user('u1', 'Not/AZone')]), sender);
    expect(report.failed).toBe(0);
    expect(sender.sent).toHaveLength(0);
  });

  it('treats a gone subscription as final and a server error as passing', () => {
    expect(isGoneStatus(404)).toBe(true);
    expect(isGoneStatus(410)).toBe(true);
    expect(isGoneStatus(401)).toBe(false);
    expect(isRetryableStatus(null)).toBe(true);
    expect(isRetryableStatus(503)).toBe(true);
    expect(isRetryableStatus(429)).toBe(true);
    expect(isRetryableStatus(400)).toBe(false);
    expect(isRetryableStatus(410)).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// In-app history
// ---------------------------------------------------------------------------

describe('the in-app history', () => {
  it('keeps the exact message that was sent, under its event key', async () => {
    const store = new FakeStore([user('u1')]);
    const sender = new FakeSender();
    await runNotifications(ist('2026-10-03T22:00'), store, sender);
    expect(store.saved.get(`u1|${dailyKey('2026-10-03')}`)).toEqual(sender.sent[0]?.message);
  });

  it('keeps a message no device could take, so the app still shows it', async () => {
    const store = new FakeStore([user('u1')]);
    const sender = new FakeSender();
    sender.results = [{ delivered: 0, removed: 1, retryable: 0 }];
    await runNotifications(ist('2026-10-03T22:00'), store, sender);
    expect(store.saved.has(`u1|${dailyKey('2026-10-03')}`)).toBe(true);
  });

  it('drops the message with the claim when the send will be retried', async () => {
    const store = new FakeStore([user('u1')]);
    const sender = new FakeSender();
    sender.results = [{ delivered: 0, removed: 0, retryable: 1 }];
    await runNotifications(ist('2026-10-03T22:00'), store, sender);
    expect(store.saved.size).toBe(0);
  });

  it('never holds up delivery when the history cannot be written', async () => {
    const quiet = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    const store = new FakeStore([user('u1')]);
    store.failSaving = true;
    const sender = new FakeSender();
    const report = await runNotifications(ist('2026-10-03T22:00'), store, sender);
    expect(report.sent.daily).toBe(1);
    expect(report.failed).toBe(0);
    quiet.mockRestore();
  });
});

describe('how an amount reads', () => {
  it('uses Indian grouping, the rupee sign, and paise only when there are some', () => {
    expect(formatAmount(1_245_000, 'INR')).toBe('₹12,450');
    expect(formatAmount(12_345_600, 'INR')).toBe('₹1,23,456');
    expect(formatAmount(42_050, 'INR')).toBe('₹420.50');
    expect(formatAmount(0, 'INR')).toBe('₹0');
    expect(formatAmount(-12_000, 'INR')).toBe('-₹120');
    expect(formatAmount(123_456, 'USD')).toBe('$1,234.56');
  });
});
