/**
 * The sender's database access, as the service role (the sender acts for no
 * signed-in user: it is woken by the schedule). It only reads the tables the
 * app already has and writes its own bookkeeping; the arithmetic is all in
 * core/, shared with the tests.
 *
 * Optional tables (credit cards, receivables) may not exist if their
 * migration was never run; a missing table reads as "no rows", exactly as
 * the app's capability checks degrade.
 */
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';

import { accountBalances, type AccountBalance, type LedgerRow } from './core/balances.ts';
import { cardsDueTomorrow, lastStatementDueDate, type CardDue, type CardEntryRow, type CardRow } from './core/cards.ts';
import { addDays, type IsoDate } from './core/dates.ts';
import type { MobileTokenStore } from './core/fcm.ts';
import type { LowBalanceState, NotifyStore, NotifyUser, NotificationKind } from './core/run.ts';
import { personalSpendingCents, type ExpenseRow } from './core/spending.ts';

type Row = Record<string, unknown>;
type Failure = { code?: string; message: string };
type Page = PromiseLike<{ data: Row[] | null; error: Failure | null }>;

const PAGE = 1000;
const CHUNK = 100;
const LOG_RETENTION_DAYS = 120;
const TABLE_MISSING = new Set(['PGRST205', '42P01']);
const UNIQUE_VIOLATION = '23505';

const text = (row: Row, key: string): string => (typeof row[key] === 'string' ? row[key] : '');
const number = (row: Row, key: string): number => Number(row[key]) || 0;
const day = (row: Row, key: string): number => {
  const value = Math.trunc(number(row, key));
  return value >= 1 && value <= 31 ? value : 1;
};

/** Every row of a query, page by page, until an empty page: the server may cap a page below [PAGE]. */
async function allRows(page: (from: number, to: number) => Page): Promise<Row[]> {
  const rows: Row[] = [];
  for (;;) {
    const { data, error } = await page(rows.length, rows.length + PAGE - 1);
    if (error) {
      if (error.code && TABLE_MISSING.has(error.code)) return [];
      throw new Error(`database read failed (${error.code ?? 'unknown'})`);
    }
    if (!data?.length) return rows;
    rows.push(...data);
  }
}

function chunks<T>(items: readonly T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

export class SupabaseStore implements NotifyStore {
  constructor(private readonly client: SupabaseClient) {}

  /** Users with a device that can receive: a browser (008) or a phone (009, absent until it is run). */
  async listUsers(): Promise<NotifyUser[]> {
    const [subscriptions, phones] = await Promise.all([
      allRows((from, to) =>
        this.client.from('push_subscriptions').select('id, user_id').is('disabled_at', null).order('id').range(from, to),
      ),
      allRows((from, to) =>
        this.client.from('mobile_push_tokens').select('id, user_id').is('disabled_at', null).order('id').range(from, to),
      ),
    ]);
    const userIds = [...new Set([...subscriptions, ...phones].map((s) => text(s, 'user_id')).filter(Boolean))];
    const users: NotifyUser[] = [];
    for (const ids of chunks(userIds, CHUNK)) {
      const [prefs, profiles] = await Promise.all([
        allRows((from, to) =>
          this.client
            .from('notification_preferences')
            .select('user_id, daily_reminder, spending_summary, low_balance, card_due, timezone')
            .in('user_id', ids)
            .order('user_id')
            .range(from, to),
        ),
        allRows((from, to) => this.client.from('profiles').select('id, currency').in('id', ids).order('id').range(from, to)),
      ]);
      const currency = new Map(profiles.map((p) => [text(p, 'id'), text(p, 'currency')]));
      const saved = new Map(prefs.map((p) => [text(p, 'user_id'), p]));
      // A device with no saved switches gets them all on, as the table's defaults say.
      for (const userId of ids) {
        const row: Row = saved.get(userId) ?? {};
        users.push({
          userId,
          timezone: text(row, 'timezone') || 'UTC',
          currency: currency.get(userId) || 'INR',
          prefs: {
            daily: row.daily_reminder !== false,
            summary: row.spending_summary !== false,
            lowBalance: row.low_balance !== false,
            cardDue: row.card_due !== false,
          },
        });
      }
    }
    return users;
  }

  async spendingCents(userId: string, from: IsoDate, to: IsoDate): Promise<number> {
    const rows = await allRows((first, last) =>
      this.client
        .from('expenses')
        .select('id, amount, expense_date')
        .eq('user_id', userId)
        .gte('expense_date', from)
        .lte('expense_date', to)
        .order('id')
        .range(first, last),
    );
    if (!rows.length) return 0;
    const expenses: ExpenseRow[] = rows.map((r) => ({ id: text(r, 'id'), amount: number(r, 'amount'), date: text(r, 'expense_date').slice(0, 10) }));
    return personalSpendingCents(expenses, await this.paidForIds(userId), from, to);
  }

  /** Expenses paid on someone else's behalf: the same read the Reports page makes (receivables.expense_id). */
  private async paidForIds(userId: string): Promise<ReadonlySet<string>> {
    const rows = await allRows((from, to) =>
      this.client.from('receivables').select('id, expense_id').eq('user_id', userId).not('expense_id', 'is', null).order('id').range(from, to),
    );
    return new Set(rows.map((r) => text(r, 'expense_id')).filter(Boolean));
  }

  async accountBalances(userId: string): Promise<AccountBalance[]> {
    const accounts = await allRows((from, to) =>
      this.client
        .from('bank_accounts')
        .select('id, nickname, bank_name, opening_balance, is_active')
        .eq('user_id', userId)
        .order('id')
        .range(from, to),
    );
    if (!accounts.length) return [];
    const ledger = await allRows((from, to) =>
      this.client.from('account_transactions').select('id, account_id, direction, amount').eq('user_id', userId).order('id').range(from, to),
    );
    const rows: LedgerRow[] = ledger.map((r) => ({
      accountId: text(r, 'account_id'),
      direction: r.direction === 'credit' ? 'credit' : 'debit',
      amount: number(r, 'amount'),
    }));
    return accountBalances(
      accounts.map((a) => ({
        id: text(a, 'id'),
        name: text(a, 'nickname').trim() || text(a, 'bank_name').trim() || 'Account',
        openingBalance: number(a, 'opening_balance'),
        isActive: a.is_active !== false,
      })),
      rows,
    );
  }

  async cardsDueTomorrow(userId: string, today: IsoDate): Promise<CardDue[]> {
    const rows = await allRows((from, to) =>
      this.client
        .from('credit_cards')
        .select('id, card_name, statement_day, payment_due_day, opening_outstanding, is_active')
        .eq('user_id', userId)
        .order('id')
        .range(from, to),
    );
    const tomorrow = addDays(today, 1);
    // Only a card whose last statement falls due tomorrow needs its movements read.
    const candidates: CardRow[] = rows
      .map((c) => ({
        id: text(c, 'id'),
        name: text(c, 'card_name').trim() || 'Card',
        statementDay: day(c, 'statement_day'),
        paymentDueDay: day(c, 'payment_due_day'),
        openingOutstanding: number(c, 'opening_outstanding'),
        isActive: c.is_active !== false,
      }))
      .filter((card) => lastStatementDueDate(card, today) === tomorrow);
    if (!candidates.length) return [];
    return cardsDueTomorrow(candidates, await this.cardEntries(userId, candidates.map((c) => c.id)), today);
  }

  /** A card's movements from the three tables the app merges (src/services/creditCards.ts `fetchCardEntries`). */
  private async cardEntries(userId: string, cardIds: readonly string[]): Promise<CardEntryRow[]> {
    const ids = [...cardIds];
    const [purchases, payments, transactions] = await Promise.all([
      allRows((from, to) =>
        this.client.from('expenses').select('id, credit_card_id, amount, expense_date').eq('user_id', userId).in('credit_card_id', ids).order('id').range(from, to),
      ),
      allRows((from, to) =>
        this.client
          .from('account_transactions')
          .select('id, credit_card_id, direction, amount, txn_date')
          .eq('user_id', userId)
          .in('credit_card_id', ids)
          .order('id')
          .range(from, to),
      ),
      allRows((from, to) =>
        this.client
          .from('credit_card_transactions')
          .select('id, card_id, direction, amount, txn_date')
          .eq('user_id', userId)
          .in('card_id', ids)
          .order('id')
          .range(from, to),
      ),
    ]);
    return [
      ...purchases.map((r) => ({ cardId: text(r, 'credit_card_id'), direction: 'debit' as const, amount: number(r, 'amount'), date: text(r, 'expense_date').slice(0, 10) })),
      // Only a bank debit is a bill payment; it lowers the card's outstanding.
      ...payments
        .filter((r) => r.direction === 'debit')
        .map((r) => ({ cardId: text(r, 'credit_card_id'), direction: 'credit' as const, amount: number(r, 'amount'), date: text(r, 'txn_date').slice(0, 10) })),
      ...transactions.map((r) => ({
        cardId: text(r, 'card_id'),
        direction: r.direction === 'credit' ? ('credit' as const) : ('debit' as const),
        amount: number(r, 'amount'),
        date: text(r, 'txn_date').slice(0, 10),
      })),
    ];
  }

  async lowBalanceStates(userId: string): Promise<Map<string, LowBalanceState>> {
    const rows = await allRows((from, to) =>
      this.client.from('low_balance_state').select('account_id, is_low, episode').eq('user_id', userId).order('account_id').range(from, to),
    );
    return new Map(rows.map((r) => [text(r, 'account_id'), { isLow: r.is_low === true, episode: Math.trunc(number(r, 'episode')) }]));
  }

  async setLowBalanceState(userId: string, accountId: string, state: LowBalanceState): Promise<void> {
    const { error } = await this.client
      .from('low_balance_state')
      .upsert({ account_id: accountId, user_id: userId, is_low: state.isLow, episode: state.episode, updated_at: new Date().toISOString() }, { onConflict: 'account_id' });
    if (error) throw new Error(`could not save the low-balance state (${error.code ?? 'unknown'})`);
  }

  async claim(userId: string, key: string, kind: NotificationKind): Promise<boolean> {
    const { error } = await this.client.from('notification_log').insert({ user_id: userId, event_key: key, kind });
    if (!error) return true;
    if (error.code === UNIQUE_VIOLATION) return false;
    throw new Error(`could not record the notification (${error.code ?? 'unknown'})`);
  }

  async release(userId: string, key: string): Promise<void> {
    await this.client.from('notification_log').delete().eq('user_id', userId).eq('event_key', key);
  }

  /** Old keys are no longer needed once their date has passed. */
  async prune(now: Date): Promise<void> {
    const cutoff = new Date(now.getTime() - LOG_RETENTION_DAYS * 86_400_000).toISOString();
    await this.client.from('notification_log').delete().lt('sent_at', cutoff);
  }
}

/** The phones a user registered (migration 009) — read, and switched off when FCM says one is gone. */
export class SupabaseMobileTokens implements MobileTokenStore {
  constructor(private readonly client: SupabaseClient) {}

  async activeTokens(userId: string): Promise<{ id: string; token: string }[]> {
    const rows = await allRows((from, to) =>
      this.client.from('mobile_push_tokens').select('id, token').eq('user_id', userId).is('disabled_at', null).order('id').range(from, to),
    );
    return rows.map((r) => ({ id: text(r, 'id'), token: text(r, 'token') })).filter((r) => r.id && r.token);
  }

  async disableToken(id: string): Promise<void> {
    await this.client.from('mobile_push_tokens').update({ disabled_at: new Date().toISOString() }).eq('id', id);
  }
}
