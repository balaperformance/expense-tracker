/**
 * `public.receivables` and the treatment functions (migration 005).
 *
 * What is owed is never read from a stored column: each claim's source (the
 * lent debit or the purchase) and its repayments (ledger credits naming it)
 * are read from their own rows and summarised in domain/receivables.ts.
 *
 * Changing how a bank movement is recorded can take several writes (remove an
 * expense, add the other transfer leg, create a claim). They are never issued
 * one by one from here: `apply_bank_treatment` and `record_bank_movement` do
 * them inside one database transaction, so a failure leaves nothing half-done.
 */
import { today, type IsoDate } from '@/lib/dates';
import { str, num, optStr, nested, type Row } from '@/lib/row';
import {
  receivableFromRow,
  summariseClaims,
  type ClaimRepayment,
  type ClaimSource,
  type ClaimSummary,
  type Receivable,
} from '@/domain/receivables';

import { capabilities, resolveCapabilities } from './capabilities';
import { allRowsOf, db, ensureOk, nowIso, rowsOf } from './db';

const TABLE = 'receivables';
const SELECT = 'id, user_id, kind, person, ledger_entry_id, expense_id, due_date, note, created_at';

/** Every claim the user has, without figures. Small: one row per loan or paid-for purchase. */
export async function fetchClaimLinks(userId: string): Promise<Receivable[]> {
  if (!capabilities().treatments) return [];
  const rows = await allRowsOf((from, to, withCount) =>
    db()
      .from(TABLE)
      .select(SELECT, withCount ? { count: 'exact' } : undefined)
      .eq('user_id', userId)
      .order('id')
      .range(from, to),
  );
  return rows.map(receivableFromRow);
}

/** Ids of expenses paid on someone else's behalf — left out of personal spending. */
export async function fetchPaidForExpenseIds(userId: string): Promise<ReadonlySet<string>> {
  await resolveCapabilities();
  if (!capabilities().treatments) return new Set();
  const rows = await allRowsOf((from, to, withCount) =>
    db()
      .from(TABLE)
      .select('id, expense_id', withCount ? { count: 'exact' } : undefined)
      .eq('user_id', userId)
      .not('expense_id', 'is', null)
      .order('id')
      .range(from, to),
  );
  return new Set(rows.map((r) => optStr(r, 'expense_id')).filter((id): id is string => id != null));
}

const CHUNK = 100;

/** `select … where id in (…)`, in chunks so a long list never overflows the URL. */
async function rowsById(table: string, columns: string, userId: string, ids: readonly string[]): Promise<Row[]> {
  const rows: Row[] = [];
  for (let i = 0; i < ids.length; i += CHUNK) {
    rows.push(...rowsOf(await db().from(table).select(columns).eq('user_id', userId).in('id', ids.slice(i, i + CHUNK))));
  }
  return rows;
}

const clean = (value: string | null) => (value?.trim() ? value.trim() : null);

/** Every claim with what went out, what came back and what is left. */
export async function fetchClaims(userId: string): Promise<ClaimSummary[]> {
  await resolveCapabilities();
  if (!capabilities().treatments) return [];
  const receivables = await fetchClaimLinks(userId);
  if (!receivables.length) return [];

  const ledgerIds = receivables.map((r) => r.ledgerEntryId).filter((id): id is string => id != null);
  const expenseIds = receivables.map((r) => r.expenseId).filter((id): id is string => id != null);
  const [lent, purchases, purchaseDebits, repaid] = await Promise.all([
    rowsById('account_transactions', 'id, account_id, amount, txn_date, description', userId, ledgerIds),
    rowsById('expenses', 'id, amount, expense_date, merchant, description, bank_account_id, credit_card_id, categories(name)', userId, expenseIds),
    // A bank-funded purchase's own debit, so the claim can link to its statement.
    expenseIds.length
      ? (async () => {
          const rows: Row[] = [];
          for (let i = 0; i < expenseIds.length; i += CHUNK) {
            rows.push(
              ...rowsOf(
                await db().from('account_transactions').select('id, expense_id').eq('user_id', userId).in('expense_id', expenseIds.slice(i, i + CHUNK)),
              ),
            );
          }
          return rows;
        })()
      : Promise.resolve([] as Row[]),
    allRowsOf((from, to, withCount) =>
      db()
        .from('account_transactions')
        .select('id, account_id, amount, txn_date, description, receivable_id', withCount ? { count: 'exact' } : undefined)
        .eq('user_id', userId)
        .not('receivable_id', 'is', null)
        .order('id')
        .range(from, to),
    ),
  ]);

  const lentById = new Map(lent.map((r) => [str(r, 'id'), r]));
  const purchaseById = new Map(purchases.map((r) => [str(r, 'id'), r]));
  const debitByExpense = new Map(purchaseDebits.map((r) => [str(r, 'expense_id'), str(r, 'id')]));
  const sources = new Map<string, ClaimSource>();
  for (const receivable of receivables) {
    if (receivable.ledgerEntryId) {
      const row = lentById.get(receivable.ledgerEntryId);
      if (row) {
        sources.set(receivable.id, {
          date: str(row, 'txn_date').slice(0, 10),
          amount: num(row, 'amount'),
          title: clean(optStr(row, 'description')) ?? 'Money lent',
          accountId: optStr(row, 'account_id'),
          cardId: null,
          ledgerEntryId: receivable.ledgerEntryId,
          expenseId: null,
        });
      }
    } else if (receivable.expenseId) {
      const row = purchaseById.get(receivable.expenseId);
      if (row) {
        const category = nested(row, 'categories');
        sources.set(receivable.id, {
          date: str(row, 'expense_date').slice(0, 10),
          amount: num(row, 'amount'),
          title: clean(optStr(row, 'merchant')) ?? clean(optStr(row, 'description')) ?? (category ? optStr(category, 'name') : null) ?? 'Purchase',
          accountId: optStr(row, 'bank_account_id'),
          cardId: optStr(row, 'credit_card_id'),
          ledgerEntryId: debitByExpense.get(receivable.expenseId) ?? null,
          expenseId: receivable.expenseId,
        });
      }
    }
  }
  const repayments: ClaimRepayment[] = repaid.map((r) => ({
    entryId: str(r, 'id'),
    receivableId: str(r, 'receivable_id'),
    accountId: str(r, 'account_id'),
    amount: num(r, 'amount'),
    date: str(r, 'txn_date').slice(0, 10),
    description: optStr(r, 'description'),
  }));
  return summariseClaims({ receivables, sources, repayments, today: today() });
}

/**
 * Marks an expense as paid on someone's behalf, or (with null) clears that.
 * One statement either way. Clearing keeps any money already received, as
 * plain money in on its account.
 */
export async function setExpensePaidFor(
  userId: string,
  expenseId: string,
  paidFor: { person: string; dueDate: IsoDate | null; note: string | null } | null,
): Promise<void> {
  if (!paidFor) {
    ensureOk(await db().from(TABLE).delete().eq('user_id', userId).eq('expense_id', expenseId));
    return;
  }
  ensureOk(
    await db()
      .from(TABLE)
      .upsert(
        {
          user_id: userId,
          kind: 'reimbursable',
          person: paidFor.person.trim(),
          expense_id: expenseId,
          due_date: paidFor.dueDate,
          note: paidFor.note?.trim() ? paidFor.note.trim() : null,
          updated_at: nowIso(),
        },
        { onConflict: 'expense_id' },
      ),
  );
}

/** Changes how an existing bank movement is recorded — every write in one transaction. */
export async function applyTreatment(entryId: string, treatment: Record<string, unknown>): Promise<string> {
  const result = await db().rpc('apply_bank_treatment', { p_entry_id: entryId, p_treatment: treatment });
  ensureOk(result);
  const data: unknown = result.data;
  return typeof data === 'string' ? data : entryId;
}

/** Saves a new bank movement together with its treatment, in one transaction. Returns its id. */
export async function recordBankMovement({
  accountId,
  direction,
  amount,
  date,
  description,
  treatment,
}: {
  accountId: string;
  direction: 'debit' | 'credit';
  amount: number;
  date: IsoDate;
  description: string;
  treatment: Record<string, unknown>;
}): Promise<string> {
  const result = await db().rpc('record_bank_movement', {
    p_account_id: accountId,
    p_direction: direction,
    p_amount: amount,
    p_date: date,
    p_description: description,
    p_treatment: treatment,
  });
  ensureOk(result);
  const data: unknown = result.data;
  if (typeof data !== 'string') throw new Error('The movement was saved without an id');
  return data;
}
