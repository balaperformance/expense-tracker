/**
 * Shared plumbing for the repositories.
 *
 * Every query in this layer carries an explicit `user_id` filter, as the
 * Flutter repositories do. RLS is what enforces isolation server-side; the
 * client-side filter keeps result sets small and states the intent.
 */
import { toAppError } from '@/lib/errors';
import { asRow, asRows, type Row } from '@/lib/row';
import { getSupabase } from '@/lib/supabase';

export const db = () => getSupabase();

type Result = { data: unknown; error: unknown };

/** The rows of a successful response, or an [AppError]. */
export function rowsOf(result: Result): Row[] {
  if (result.error) throw toAppError(result.error);
  return asRows(result.data);
}

/** The single row of a successful `.single()` response, or an [AppError]. */
export function rowOf(result: Result): Row {
  if (result.error) throw toAppError(result.error);
  const row = asRow(result.data);
  if (!row) throw toAppError(new Error('Expected one row'));
  return row;
}

const PAGE_ROWS = 1000;

/**
 * Every row of a query, read page by page. PostgREST caps one response at the
 * project's max-rows, so a figure summed over a long history (a card's
 * outstanding) must not stop at the first page. The first page asks for the
 * exact count, and reading continues until that many rows have arrived —
 * whatever page size the server actually allows. [page] must apply a stable
 * order (end it with a unique column such as id). [max] stops early, for
 * reads that deliberately cap their size (exports).
 */
export async function allRowsOf(
  page: (from: number, to: number, withCount: boolean) => PromiseLike<Result & { count?: number | null }>,
  max = Number.POSITIVE_INFINITY,
): Promise<Row[]> {
  const first = await page(0, Math.min(PAGE_ROWS, max) - 1, true);
  const rows = rowsOf(first);
  // Without a count, keep reading until a page comes back empty.
  const total = Math.min(first.count ?? Number.POSITIVE_INFINITY, max);
  while (rows.length < total) {
    const next = rowsOf(await page(rows.length, rows.length + Math.min(PAGE_ROWS, total - rows.length) - 1, false));
    if (!next.length) break;
    rows.push(...next);
  }
  return rows.length > max ? rows.slice(0, max) : rows;
}

/** `yyyy-MM` → total, summed in whole cents. */
export function monthlyTotals(rows: readonly Row[], dateKey: string): Map<string, number> {
  const cents = new Map<string, number>();
  for (const row of rows) {
    const key = String(row[dateKey]).slice(0, 7);
    cents.set(key, (cents.get(key) ?? 0) + Math.round((Number(row.amount) || 0) * 100));
  }
  return new Map([...cents].map(([key, value]) => [key, value / 100]));
}

/** Nothing but success, for writes whose body is not needed. */
export function ensureOk(result: { error: unknown }): void {
  if (result.error) throw toAppError(result.error);
}

export const nowIso = () => new Date().toISOString();
