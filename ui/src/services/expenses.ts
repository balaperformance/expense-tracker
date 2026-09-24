/**
 * `public.expenses`. Port of `repositories/expense_repository.dart`.
 */
import { monthRange } from '@/lib/dates';
import { MONTHLY_AGGREGATE_LIMIT, EXPORT_ROW_LIMIT, PAGE_SIZE } from '@/domain/defaults';
import { sanitiseSearch, sortAscending, sortColumn, type ExpenseFilter } from '@/domain/expenseFilter';
import { blankToNull, expenseFromRow, expenseTitle, type Expense } from '@/domain/models';
import { smsReferenceNote } from '@/domain/sms/smsDraft';

import { capabilities, phase2Ready, resolveCapabilities } from './capabilities';
import { db, ensureOk, nowIso, rowOf, rowsOf } from './db';
import { syncForExpense } from './ledger';

const TABLE = 'expenses';

/** Optional columns are selected only when their migration has run. */
function select(): string {
  const caps = capabilities();
  return (
    'id, user_id, amount, category_id, payment_method_id, expense_date, description, notes, created_at, updated_at' +
    `${caps.merchant ? ', merchant' : ''}${caps.expenseBankLink ? ', bank_account_id' : ''}` +
    ', categories(*), payment_methods(*)'
  );
}

export type ExpenseDraft = {
  amount: number;
  expenseDate: string;
  categoryId: string | null;
  paymentMethodId: string | null;
  bankAccountId: string | null;
  merchant: string | null;
  description: string | null;
  notes: string | null;
};

function writable(draft: ExpenseDraft): Record<string, unknown> {
  const caps = capabilities();
  const map: Record<string, unknown> = {
    amount: draft.amount,
    expense_date: draft.expenseDate,
    category_id: draft.categoryId,
    payment_method_id: draft.paymentMethodId,
    description: blankToNull(draft.description),
    notes: blankToNull(draft.notes),
  };
  if (caps.merchant) map.merchant = blankToNull(draft.merchant);
  if (caps.expenseBankLink) map.bank_account_id = draft.bankAccountId;
  return map;
}

export async function fetchPage(userId: string, filter: ExpenseFilter, page: number): Promise<Expense[]> {
  await resolveCapabilities();
  let query = db().from(TABLE).select(select()).eq('user_id', userId);

  if (filter.categoryIds.length) query = query.in('category_id', [...filter.categoryIds]);
  if (filter.paymentMethodIds.length) query = query.in('payment_method_id', [...filter.paymentMethodIds]);
  if (filter.from) query = query.gte('expense_date', filter.from);
  if (filter.to) query = query.lte('expense_date', filter.to);

  const term = sanitiseSearch(filter.search);
  if (term) {
    const clauses = [`description.ilike.%${term}%`, `notes.ilike.%${term}%`];
    if (capabilities().merchant) clauses.push(`merchant.ilike.%${term}%`);
    query = query.or(clauses.join(','));
  }

  const from = page * PAGE_SIZE;
  const result = await query
    .order(sortColumn(filter.sort), { ascending: sortAscending(filter.sort) })
    .order('created_at', { ascending: false })
    .range(from, from + PAGE_SIZE - 1);
  return rowsOf(result).map(expenseFromRow);
}

export async function fetchById(userId: string, id: string): Promise<Expense | null> {
  await resolveCapabilities();
  const rows = rowsOf(await db().from(TABLE).select(select()).eq('user_id', userId).eq('id', id).limit(1));
  const [row] = rows;
  return row ? expenseFromRow(row) : null;
}

/** Every expense in a month — dashboard, reports and budgets aggregate client-side. */
export async function fetchForMonth(userId: string, month: string): Promise<Expense[]> {
  await resolveCapabilities();
  const range = monthRange(month);
  const result = await db()
    .from(TABLE)
    .select(select())
    .eq('user_id', userId)
    .gte('expense_date', range.start)
    .lt('expense_date', range.endExclusive)
    .order('expense_date', { ascending: false })
    .limit(MONTHLY_AGGREGATE_LIMIT);
  return rowsOf(result).map(expenseFromRow);
}

/** An arbitrary day range, oldest first — for export. */
export async function fetchRange(
  userId: string,
  from: string,
  toExclusive: string,
  categoryIds: readonly string[] = [],
): Promise<Expense[]> {
  await resolveCapabilities();
  let query = db()
    .from(TABLE)
    .select(select())
    .eq('user_id', userId)
    .gte('expense_date', from)
    .lt('expense_date', toExclusive);
  if (categoryIds.length) query = query.in('category_id', [...categoryIds]);
  const result = await query
    .order('expense_date', { ascending: true })
    .order('created_at', { ascending: true })
    .limit(EXPORT_ROW_LIMIT);
  return rowsOf(result).map(expenseFromRow);
}

/** `yyyy-MM` → total over a contiguous range: one request for a whole trend chart. */
export async function fetchMonthlyTotals(userId: string, from: string, toExclusive: string): Promise<Map<string, number>> {
  const result = await db()
    .from(TABLE)
    .select('amount, expense_date')
    .eq('user_id', userId)
    .gte('expense_date', from)
    .lt('expense_date', toExclusive)
    .limit(MONTHLY_AGGREGATE_LIMIT * 12);
  const totals = new Map<string, number>();
  for (const row of rowsOf(result)) {
    const key = String(row.expense_date).slice(0, 7);
    totals.set(key, (totals.get(key) ?? 0) + (Number(row.amount) || 0));
  }
  return totals;
}

/** Mirrors an expense into the ledger; cash produces no movement. */
async function syncLedger(expense: Expense): Promise<void> {
  if (!phase2Ready(capabilities())) return;
  await syncForExpense({
    userId: expense.userId,
    documentId: expense.id,
    accountId: expense.bankAccountId,
    amount: expense.amount,
    date: expense.expenseDate,
    description: expenseTitle(expense),
    categoryId: expense.categoryId,
  });
}

export async function createExpense(userId: string, draft: ExpenseDraft): Promise<Expense> {
  await resolveCapabilities();
  const row = rowOf(
    await db()
      .from(TABLE)
      .insert({ user_id: userId, ...writable(draft) })
      .select(select())
      .single(),
  );
  const created = expenseFromRow(row);
  await syncLedger(created);
  return created;
}

export async function updateExpense(userId: string, id: string, draft: ExpenseDraft): Promise<Expense> {
  await resolveCapabilities();
  const row = rowOf(
    await db()
      .from(TABLE)
      .update({ ...writable(draft), updated_at: nowIso() })
      .eq('id', id)
      .eq('user_id', userId)
      .select(select())
      .single(),
  );
  const updated = expenseFromRow(row);
  // Re-sync rather than patch: covers switching accounts, switching to Cash,
  // and changing amount or date in one path.
  await syncLedger(updated);
  return updated;
}

/** The ledger row goes with it via ON DELETE CASCADE. */
export async function deleteExpense(userId: string, id: string): Promise<void> {
  ensureOk(await db().from(TABLE).delete().eq('id', id).eq('user_id', userId));
}

/**
 * Looks for an expense that already records this bank message: first by the
 * reference stored in notes, then by shape (same day, amount and account).
 * Advisory only — a failed lookup returns null rather than blocking a save.
 */
export async function findPossibleDuplicate({
  userId,
  amount,
  date,
  reference,
  bankAccountId,
}: {
  userId: string;
  amount: number;
  date: string;
  reference: string | null;
  bankAccountId: string | null;
}): Promise<Expense | null> {
  try {
    await resolveCapabilities();
    if (reference?.trim()) {
      const term = sanitiseSearch(smsReferenceNote(reference));
      if (term) {
        const byReference = rowsOf(
          await db().from(TABLE).select(select()).eq('user_id', userId).ilike('notes', `%${term}%`).limit(1),
        );
        const [hit] = byReference;
        if (hit) return expenseFromRow(hit);
      }
    }
    let query = db().from(TABLE).select(select()).eq('user_id', userId).eq('amount', amount).eq('expense_date', date);
    if (capabilities().expenseBankLink) {
      query = bankAccountId == null ? query.is('bank_account_id', null) : query.eq('bank_account_id', bankAccountId);
    }
    const [hit] = rowsOf(await query.limit(1));
    return hit ? expenseFromRow(hit) : null;
  } catch {
    return null;
  }
}

export async function countUsingCategory(userId: string, categoryId: string): Promise<number> {
  const { count, error } = await db()
    .from(TABLE)
    .select('id', { count: 'exact', head: true })
    .eq('user_id', userId)
    .eq('category_id', categoryId);
  if (error) return 0;
  return count ?? 0;
}
