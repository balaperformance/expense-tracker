/**
 * Personal spending — the one definition the Reports page and the dashboard
 * use (src/domain/analytics.ts `personalSpending`, fed by `loadMonth` in
 * src/hooks/data.ts): every row of `expenses` in the period, except purchases
 * paid on someone else's behalf.
 *
 * Transfers between your accounts, money lent, loan repayments,
 * reimbursements, refunds and card bill payments are never rows of `expenses`
 * (migration 005 stores them only in the ledger), so they cannot be counted
 * here. Card purchases are expenses and count when made, as in Reports.
 */
import type { IsoDate } from './dates.ts';
import { toCents } from './money.ts';

export type ExpenseRow = { id: string; amount: number; date: IsoDate };

/** Spending from [from] to [to], both inclusive, in cents. */
export function personalSpendingCents(
  expenses: readonly ExpenseRow[],
  paidForIds: ReadonlySet<string>,
  from: IsoDate,
  to: IsoDate,
): number {
  let total = 0;
  for (const expense of expenses) {
    if (expense.date < from || expense.date > to || paidForIds.has(expense.id)) continue;
    total += toCents(expense.amount);
  }
  return total;
}
