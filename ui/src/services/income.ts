/**
 * `public.income`. Port of `repositories/income_repository.dart`.
 * The table has no `notes` or `updated_at` column.
 */
import { monthRange } from '@/lib/dates';
import { EXPORT_ROW_LIMIT, MONTHLY_AGGREGATE_LIMIT, PAGE_SIZE } from '@/domain/defaults';
import { sanitiseSearch } from '@/domain/expenseFilter';
import { blankToNull, incomeFromRow, incomeTitle, type Income } from '@/domain/models';
import type { MovementDetails } from '@/domain/statementImport/model';

import { capabilities, resolveCapabilities } from './capabilities';
import { allRowsOf, db, ensureOk, monthlyTotals, rowOf, rowsOf } from './db';
import { syncForIncome } from './ledger';

const TABLE = 'income';

const select = () =>
  `id, user_id, amount, source, income_date, description, created_at${capabilities().incomeBankLink ? ', bank_account_id' : ''}`;

export type IncomeDraft = {
  amount: number;
  incomeDate: string;
  source: string | null;
  description: string | null;
  bankAccountId: string | null;
};

function writable(draft: IncomeDraft): Record<string, unknown> {
  const map: Record<string, unknown> = {
    amount: draft.amount,
    income_date: draft.incomeDate,
    source: blankToNull(draft.source),
    description: blankToNull(draft.description),
  };
  if (capabilities().incomeBankLink) map.bank_account_id = draft.bankAccountId;
  return map;
}

export async function fetchIncomePage(userId: string, search: string, page: number): Promise<Income[]> {
  await resolveCapabilities();
  let query = db().from(TABLE).select(select()).eq('user_id', userId);
  const term = sanitiseSearch(search);
  if (term) query = query.or(`source.ilike.%${term}%,description.ilike.%${term}%`);
  const from = page * PAGE_SIZE;
  const result = await query
    .order('income_date', { ascending: false })
    .order('created_at', { ascending: false })
    .range(from, from + PAGE_SIZE - 1);
  return rowsOf(result).map(incomeFromRow);
}

export async function fetchIncomeById(userId: string, id: string): Promise<Income | null> {
  await resolveCapabilities();
  const [row] = rowsOf(await db().from(TABLE).select(select()).eq('user_id', userId).eq('id', id).limit(1));
  return row ? incomeFromRow(row) : null;
}

export async function fetchIncomeForMonth(userId: string, month: string): Promise<Income[]> {
  await resolveCapabilities();
  const range = monthRange(month);
  // Paged: one response is capped at the project's max-rows, below this limit.
  const rows = await allRowsOf(
    (from, to, withCount) =>
      db()
        .from(TABLE)
        .select(select(), withCount ? { count: 'exact' } : undefined)
        .eq('user_id', userId)
        .gte('income_date', range.start)
        .lt('income_date', range.endExclusive)
        .order('income_date', { ascending: false })
        .order('id')
        .range(from, to),
    MONTHLY_AGGREGATE_LIMIT,
  );
  return rows.map(incomeFromRow);
}

export async function fetchIncomeRange(userId: string, from: string, toExclusive: string): Promise<Income[]> {
  await resolveCapabilities();
  const rows = await allRowsOf(
    (first, last, withCount) =>
      db()
        .from(TABLE)
        .select(select(), withCount ? { count: 'exact' } : undefined)
        .eq('user_id', userId)
        .gte('income_date', from)
        .lt('income_date', toExclusive)
        .order('income_date', { ascending: true })
        .order('created_at', { ascending: true })
        .order('id')
        .range(first, last),
    EXPORT_ROW_LIMIT,
  );
  return rows.map(incomeFromRow);
}

export async function fetchIncomeMonthlyTotals(userId: string, from: string, toExclusive: string): Promise<Map<string, number>> {
  const rows = await allRowsOf(
    (first, last, withCount) =>
      db()
        .from(TABLE)
        .select('id, amount, income_date', withCount ? { count: 'exact' } : undefined)
        .eq('user_id', userId)
        .gte('income_date', from)
        .lt('income_date', toExclusive)
        .order('id')
        .range(first, last),
    MONTHLY_AGGREGATE_LIMIT * 12,
  );
  return monthlyTotals(rows, 'income_date');
}

async function syncLedger(income: Income, details?: MovementDetails | null): Promise<void> {
  const caps = capabilities();
  if (!caps.bankAccounts || !caps.incomeBankLink) return;
  await syncForIncome({
    userId: income.userId,
    documentId: income.id,
    accountId: income.bankAccountId,
    amount: income.amount,
    date: income.incomeDate,
    description: incomeTitle(income),
    details,
  });
}

/** [details]: what an imported statement printed about the payment, kept on its ledger movement. */
export async function createIncome(userId: string, draft: IncomeDraft, { details }: { details?: MovementDetails | null } = {}): Promise<Income> {
  await resolveCapabilities();
  const row = rowOf(
    await db()
      .from(TABLE)
      .insert({ user_id: userId, ...writable(draft) })
      .select(select())
      .single(),
  );
  const created = incomeFromRow(row);
  await syncLedger(created, details);
  return created;
}

export async function updateIncome(userId: string, id: string, draft: IncomeDraft): Promise<Income> {
  await resolveCapabilities();
  const row = rowOf(
    await db().from(TABLE).update(writable(draft)).eq('id', id).eq('user_id', userId).select(select()).single(),
  );
  const updated = incomeFromRow(row);
  await syncLedger(updated);
  return updated;
}

export async function deleteIncome(userId: string, id: string): Promise<void> {
  ensureOk(await db().from(TABLE).delete().eq('id', id).eq('user_id', userId));
}
