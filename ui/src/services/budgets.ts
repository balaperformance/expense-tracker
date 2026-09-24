/**
 * `public.budgets`. Port of `repositories/budget_repository.dart`.
 * `month` is always the first day of the month, so lookups are exact matches.
 */
import { addMonths, firstOfMonth } from '@/lib/dates';
import { budgetFromRow, type Budget } from '@/domain/models';

import { db, ensureOk, rowsOf } from './db';

const TABLE = 'budgets';
const SELECT = 'id, user_id, amount, category_id, month, created_at, categories(*)';

export async function fetchBudgetsForMonth(userId: string, month: string): Promise<Budget[]> {
  const result = await db()
    .from(TABLE)
    .select(SELECT)
    .eq('user_id', userId)
    .eq('month', firstOfMonth(month))
    .order('created_at', { ascending: true });
  return rowsOf(result).map(budgetFromRow);
}

/**
 * Creates or replaces the budget for a (category, month) pair. Find-then-write
 * rather than upsert: the table has no unique constraint to conflict on, and
 * adding one would change the existing schema.
 */
export async function setBudget({
  userId,
  categoryId,
  month,
  amount,
}: {
  userId: string;
  categoryId: string | null;
  month: string;
  amount: number;
}): Promise<void> {
  const monthKey = firstOfMonth(month);
  let lookup = db().from(TABLE).select('id').eq('user_id', userId).eq('month', monthKey);
  lookup = categoryId == null ? lookup.is('category_id', null) : lookup.eq('category_id', categoryId);
  const [existing] = rowsOf(await lookup);

  if (existing && typeof existing.id === 'string') {
    ensureOk(await db().from(TABLE).update({ amount }).eq('id', existing.id).eq('user_id', userId));
    return;
  }
  ensureOk(await db().from(TABLE).insert({ user_id: userId, amount, month: monthKey, category_id: categoryId }));
}

export async function deleteBudget(userId: string, id: string): Promise<void> {
  ensureOk(await db().from(TABLE).delete().eq('id', id).eq('user_id', userId));
}

/** Copies last month's budgets forward, skipping any the target month already has. */
export async function copyBudgetsFromPreviousMonth(userId: string, targetMonth: string): Promise<number> {
  const source = await fetchBudgetsForMonth(userId, addMonths(targetMonth, -1));
  if (!source.length) return 0;
  const target = await fetchBudgetsForMonth(userId, targetMonth);
  const taken = new Set(target.map((b) => b.categoryId));
  const rows = source
    .filter((b) => !taken.has(b.categoryId))
    .map((b) => ({ user_id: userId, amount: b.amount, month: firstOfMonth(targetMonth), category_id: b.categoryId }));
  if (!rows.length) return 0;
  ensureOk(await db().from(TABLE).insert(rows));
  return rows.length;
}
