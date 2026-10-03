/**
 * `public.tags`, `expense_tags` and `income_tags` (migration 006).
 *
 * Reads are plain selects. The only write is `set_transaction_tags`, which
 * finds or creates each named tag and makes the transaction's links exactly
 * that set, in one database transaction — so a tag is never created twice and
 * a failure leaves the transaction's tags as they were.
 */
import type { Tag, TagKind } from '@/domain/tags';
import { optStr, str } from '@/lib/row';

import { capabilities, resolveCapabilities } from './capabilities';
import { allRowsOf, db, ensureOk, rowsOf } from './db';

/** Every tag the user has. Small: one row per distinct label. */
export async function fetchTags(userId: string): Promise<Tag[]> {
  await resolveCapabilities();
  if (!capabilities().tags) return [];
  const rows = await allRowsOf((from, to, withCount) =>
    db()
      .from('tags')
      .select('id, name', withCount ? { count: 'exact' } : undefined)
      .eq('user_id', userId)
      .order('name')
      .order('id')
      .range(from, to),
  );
  return rows.map((row) => ({ id: str(row, 'id'), name: str(row, 'name') }));
}

const LINKS: Record<TagKind, { table: string; column: string }> = {
  expense: { table: 'expense_tags', column: 'expense_id' },
  income: { table: 'income_tags', column: 'income_id' },
};

/** The ids of the tags on one expense or income row. */
export async function fetchTagIdsFor(userId: string, kind: TagKind, id: string): Promise<string[]> {
  await resolveCapabilities();
  if (!capabilities().tags) return [];
  const { table, column } = LINKS[kind];
  const rows = rowsOf(await db().from(table).select('tag_id, created_at').eq('user_id', userId).eq(column, id).order('created_at').order('tag_id'));
  return rows.map((row) => str(row, 'tag_id'));
}

/** Makes [names] the transaction's complete set of tags, creating any that do not exist yet. */
export async function setTags(kind: TagKind, id: string, names: readonly string[]): Promise<void> {
  ensureOk(await db().rpc('set_transaction_tags', { p_kind: kind, p_id: id, p_names: [...names] }));
}

/** The expense and income rows a ledger movement is linked to — read after a treatment changes them. */
export async function documentsOfEntry(userId: string, entryId: string): Promise<{ expenseId: string | null; incomeId: string | null }> {
  const [row] = rowsOf(await db().from('account_transactions').select('expense_id, income_id').eq('user_id', userId).eq('id', entryId).limit(1));
  return { expenseId: row ? optStr(row, 'expense_id') : null, incomeId: row ? optStr(row, 'income_id') : null };
}
