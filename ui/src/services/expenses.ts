/**
 * `public.expenses`. Port of `repositories/expense_repository.dart`.
 */
import { monthRange } from '@/lib/dates';
import { MONTHLY_AGGREGATE_LIMIT, EXPORT_ROW_LIMIT, PAGE_SIZE } from '@/domain/defaults';
import { sanitiseSearch, sortAscending, sortColumn, type ExpenseFilter } from '@/domain/expenseFilter';
import { blankToNull, expenseFromRow, expenseTitle, type Expense } from '@/domain/models';
import { smsReferenceNote } from '@/domain/sms/smsDraft';
import type { MovementDetails } from '@/domain/statementImport/model';

import { capabilities, phase2Ready, resolveCapabilities } from './capabilities';
import { allRowsOf, db, ensureOk, monthlyTotals, nowIso, rowOf, rowsOf } from './db';
import { syncForExpense } from './ledger';

const TABLE = 'expenses';

/** Optional columns are selected only when their migration has run. */
function optionalColumns(): string {
  const caps = capabilities();
  return `${caps.merchant ? ', merchant' : ''}${caps.expenseBankLink ? ', bank_account_id' : ''}${caps.creditCards ? ', credit_card_id' : ''}`;
}

function select(): string {
  return (
    'id, user_id, amount, category_id, payment_method_id, expense_date, description, notes, created_at, updated_at' +
    optionalColumns() +
    ', categories(*), payment_methods(*)'
  );
}

export type ExpenseDraft = {
  amount: number;
  expenseDate: string;
  categoryId: string | null;
  paymentMethodId: string | null;
  bankAccountId: string | null;
  /** A card purchase: never also bank-funded, so bankAccountId is ignored when this is set. */
  creditCardId: string | null;
  /** Left out by the forms, which no longer ask for it: an existing merchant is kept as it is. */
  merchant?: string | null;
  description: string | null;
  notes: string | null;
};

function writable(draft: ExpenseDraft): Record<string, unknown> {
  const caps = capabilities();
  const cardId = caps.creditCards ? draft.creditCardId : null;
  const map: Record<string, unknown> = {
    amount: draft.amount,
    expense_date: draft.expenseDate,
    category_id: draft.categoryId,
    payment_method_id: draft.paymentMethodId,
    description: blankToNull(draft.description),
    notes: blankToNull(draft.notes),
  };
  if (caps.merchant && draft.merchant !== undefined) map.merchant = blankToNull(draft.merchant);
  // One funding source: a card purchase must not also debit a bank account.
  if (caps.expenseBankLink) map.bank_account_id = cardId ? null : draft.bankAccountId;
  if (caps.creditCards) map.credit_card_id = cardId;
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
  // Paged: one response is capped at the project's max-rows, below this limit.
  const rows = await allRowsOf(
    (from, to, withCount) =>
      db()
        .from(TABLE)
        .select(select(), withCount ? { count: 'exact' } : undefined)
        .eq('user_id', userId)
        .gte('expense_date', range.start)
        .lt('expense_date', range.endExclusive)
        .order('expense_date', { ascending: false })
        .order('id')
        .range(from, to),
    MONTHLY_AGGREGATE_LIMIT,
  );
  return rows.map(expenseFromRow);
}

/** An arbitrary day range, oldest first — for export. */
export async function fetchRange(
  userId: string,
  from: string,
  toExclusive: string,
  categoryIds: readonly string[] = [],
): Promise<Expense[]> {
  await resolveCapabilities();
  const rows = await allRowsOf((first, last, withCount) => {
    let query = db()
      .from(TABLE)
      .select(select(), withCount ? { count: 'exact' } : undefined)
      .eq('user_id', userId)
      .gte('expense_date', from)
      .lt('expense_date', toExclusive);
    if (categoryIds.length) query = query.in('category_id', [...categoryIds]);
    return query
      .order('expense_date', { ascending: true })
      .order('created_at', { ascending: true })
      .order('id')
      .range(first, last);
  }, EXPORT_ROW_LIMIT);
  return rows.map(expenseFromRow);
}

/**
 * Expenses from [from] up to [toExclusive], newest first, at most [limit] —
 * the purchases offered when choosing what a reimbursement pays back.
 * [lean] reads only what Quick add needs: no notes, category or method rows.
 */
export async function fetchRecent(userId: string, from: string, toExclusive: string, limit: number, { lean = false } = {}): Promise<Expense[]> {
  await resolveCapabilities();
  const result = await db()
    .from(TABLE)
    .select(lean ? `id, user_id, amount, category_id, payment_method_id, expense_date, description, created_at${optionalColumns()}` : select())
    .eq('user_id', userId)
    .gte('expense_date', from)
    .lt('expense_date', toExclusive)
    .order('expense_date', { ascending: false })
    .order('created_at', { ascending: false })
    .limit(limit);
  return rowsOf(result).map(expenseFromRow);
}

/**
 * `yyyy-MM` → total over a contiguous range: one request for a whole trend chart.
 * [excludeIds] leaves out expenses that are not personal spending (paid for someone else).
 */
export async function fetchMonthlyTotals(
  userId: string,
  from: string,
  toExclusive: string,
  excludeIds: ReadonlySet<string> = new Set(),
): Promise<Map<string, number>> {
  const rows = await allRowsOf(
    (first, last, withCount) =>
      db()
        .from(TABLE)
        .select('id, amount, expense_date', withCount ? { count: 'exact' } : undefined)
        .eq('user_id', userId)
        .gte('expense_date', from)
        .lt('expense_date', toExclusive)
        .order('id')
        .range(first, last),
    MONTHLY_AGGREGATE_LIMIT * 12,
  );
  return monthlyTotals(excludeIds.size ? rows.filter((row) => !excludeIds.has(String(row.id))) : rows, 'expense_date');
}

/**
 * Every purchase on one card — or on any card when [cardId] is null — over the
 * whole history, since a card's outstanding is the sum of all of them.
 */
export async function fetchForCreditCard(userId: string, cardId: string | null): Promise<Expense[]> {
  await resolveCapabilities();
  if (!capabilities().creditCards) return [];
  const rows = await allRowsOf((from, to, withCount) => {
    const query = db()
      .from(TABLE)
      .select(select(), withCount ? { count: 'exact' } : undefined)
      .eq('user_id', userId);
    return (cardId ? query.eq('credit_card_id', cardId) : query.not('credit_card_id', 'is', null)).order('id').range(from, to);
  });
  return rows.map(expenseFromRow);
}

/** Mirrors an expense into the ledger; cash and card purchases produce no movement. */
async function syncLedger(expense: Expense, details?: MovementDetails | null): Promise<void> {
  if (!phase2Ready(capabilities())) return;
  await syncForExpense({
    userId: expense.userId,
    documentId: expense.id,
    accountId: expense.bankAccountId,
    amount: expense.amount,
    date: expense.expenseDate,
    description: expenseTitle(expense),
    categoryId: expense.categoryId,
    details,
  });
}

/** [details]: what an imported statement printed about the payment, kept on its ledger movement. */
export async function createExpense(userId: string, draft: ExpenseDraft, { details }: { details?: MovementDetails | null } = {}): Promise<Expense> {
  await resolveCapabilities();
  const row = rowOf(
    await db()
      .from(TABLE)
      .insert({ user_id: userId, ...writable(draft) })
      .select(select())
      .single(),
  );
  const created = expenseFromRow(row);
  await syncLedger(created, details);
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
  creditCardId = null,
}: {
  userId: string;
  amount: number;
  date: string;
  reference: string | null;
  bankAccountId: string | null;
  creditCardId?: string | null;
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
      query = bankAccountId == null || creditCardId != null ? query.is('bank_account_id', null) : query.eq('bank_account_id', bankAccountId);
    }
    if (capabilities().creditCards) {
      query = creditCardId == null ? query.is('credit_card_id', null) : query.eq('credit_card_id', creditCardId);
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
