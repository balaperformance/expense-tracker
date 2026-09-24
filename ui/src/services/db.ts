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

/** Nothing but success, for writes whose body is not needed. */
export function ensureOk(result: { error: unknown }): void {
  if (result.error) throw toAppError(result.error);
}

export const nowIso = () => new Date().toISOString();
