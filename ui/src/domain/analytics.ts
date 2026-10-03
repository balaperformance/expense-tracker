/**
 * Aggregates computed from raw rows. Port of `models/analytics.dart` and
 * `models/budget.dart`'s progress type. Shared by the dashboard, reports,
 * budgets and export so they can never disagree.
 */
import { FALLBACK_CATEGORY_COLOR } from '@/lib/color';
import { firstOfMonth, type IsoDate } from '@/lib/dates';

import { FALLBACK_CATEGORY_ICON } from './defaults';
import type { Budget, Expense, ExpenseCategory } from './models';

export type CategorySpend = {
  categoryId: string | null;
  name: string;
  color: string;
  icon: string;
  total: number;
  transactionCount: number;
};

export type MonthlyPoint = {
  /** First day of the month. */
  month: string;
  expense: number;
  income: number;
};

export function shareOf(spend: CategorySpend, periodTotal: number): number {
  return periodTotal <= 0 ? 0 : spend.total / periodTotal;
}

export function sumBy<T>(items: readonly T[], value: (item: T) => number): number {
  return items.reduce((sum, item) => sum + value(item), 0);
}

/**
 * The expenses that are the user's own spending: everything except purchases
 * paid on someone else's behalf ([paidForIds]), which are owed back. Every
 * spending figure — dashboard, reports, budgets, exports — goes through this.
 */
export function personalSpending<T extends { id: string }>(expenses: readonly T[], paidForIds: ReadonlySet<string>): T[] {
  return paidForIds.size ? expenses.filter((e) => !paidForIds.has(e.id)) : [...expenses];
}

/** Groups expenses by category, largest first. */
export function buildCategoryBreakdown(
  expenses: readonly Expense[],
  categories: readonly ExpenseCategory[],
): CategorySpend[] {
  const byId = new Map(categories.map((c) => [c.id, c]));
  const totals = new Map<string | null, { total: number; count: number }>();

  for (const expense of expenses) {
    const bucket = totals.get(expense.categoryId) ?? { total: 0, count: 0 };
    bucket.total += expense.amount;
    bucket.count += 1;
    totals.set(expense.categoryId, bucket);
  }

  return [...totals.entries()]
    .map(([categoryId, { total, count }]) => {
      const category = categoryId == null ? undefined : byId.get(categoryId);
      return {
        categoryId,
        name: category?.name ?? 'Uncategorised',
        color: category?.color ?? FALLBACK_CATEGORY_COLOR,
        icon: category?.icon ?? FALLBACK_CATEGORY_ICON,
        total,
        transactionCount: count,
      };
    })
    .sort((a, b) => b.total - a.total);
}

/**
 * The month [day] falls in is still running: its income and spending are only
 * what has happened so far — a salary paid at month-end has not arrived yet —
 * so the two are not compared as if the month were over.
 */
export function isMonthInProgress(month: IsoDate, day: IsoDate): boolean {
  return firstOfMonth(month) === firstOfMonth(day);
}

/**
 * What a month's summary leads with.
 *
 *   balance  the month is running and there are accounts: the money available
 *            now, from the account balances
 *   spent    the month is running and there are no accounts: spending so far
 *   net      the month is over: income less spending — saved or overspent. Only
 *            then are both figures complete enough to compare.
 *
 * Nothing is projected: a salary that has not arrived counts for nothing.
 */
export type MonthStanding =
  | { kind: 'balance'; available: number }
  | { kind: 'spent'; spent: number }
  | { kind: 'net'; net: number; saved: boolean };

export function monthStanding({
  inProgress,
  available,
  income,
  expense,
}: {
  inProgress: boolean;
  /** Every account's balance added up; null when there are no accounts. */
  available: number | null;
  income: number;
  expense: number;
}): MonthStanding {
  if (inProgress) return available != null ? { kind: 'balance', available } : { kind: 'spent', spent: expense };
  const net = income - expense;
  return { kind: 'net', net, saved: net >= 0 };
}

/** The average expense: spending over the number of expenses, never a forecast. */
export function averagePerExpense(total: number, count: number): number {
  return count > 0 ? total / count : 0;
}

/** `yyyy-MM` → total, for the trend charts. */
export function bucketByMonth<T>(items: readonly T[], date: (item: T) => string, value: (item: T) => number) {
  const totals = new Map<string, number>();
  for (const item of items) {
    const key = date(item).slice(0, 7);
    totals.set(key, (totals.get(key) ?? 0) + value(item));
  }
  return totals;
}

// ---------------------------------------------------------------------------
// Budgets
// ---------------------------------------------------------------------------

export type BudgetProgress = {
  budget: Budget;
  spent: number;
};

export const budgetRemaining = (p: BudgetProgress) => p.budget.amount - p.spent;
/** Unclamped, so the UI can tell "at 100%" from "well over". */
export const budgetRatio = (p: BudgetProgress) => (p.budget.amount <= 0 ? 0 : p.spent / p.budget.amount);
export const budgetIsOver = (p: BudgetProgress) => p.spent > p.budget.amount;
/** Below 100% on purpose so the warning is actionable. */
export const budgetIsApproaching = (p: BudgetProgress) => !budgetIsOver(p) && budgetRatio(p) >= 0.8;
export const budgetNeedsAttention = (p: BudgetProgress) => budgetIsOver(p) || budgetIsApproaching(p);

export type BudgetMonth = {
  overall: BudgetProgress | null;
  /** Most-used first. */
  categories: BudgetProgress[];
};

/** Pairs each budget with the spend actually recorded in its month. */
export function buildBudgetProgress(budgets: readonly Budget[], expenses: readonly Expense[]): BudgetMonth {
  const spendByCategory = new Map<string | null, number>();
  let total = 0;
  for (const expense of expenses) {
    spendByCategory.set(expense.categoryId, (spendByCategory.get(expense.categoryId) ?? 0) + expense.amount);
    total += expense.amount;
  }

  let overall: BudgetProgress | null = null;
  const categories: BudgetProgress[] = [];
  for (const budget of budgets) {
    if (budget.categoryId == null) overall = { budget, spent: total };
    else categories.push({ budget, spent: spendByCategory.get(budget.categoryId) ?? 0 });
  }
  categories.sort((a, b) => budgetRatio(b) - budgetRatio(a));
  return { overall, categories };
}

/** Budgets at or over their limit, surfaced as warnings. */
export function budgetAlerts(month: BudgetMonth): BudgetProgress[] {
  return [
    ...(month.overall && budgetNeedsAttention(month.overall) ? [month.overall] : []),
    ...month.categories.filter(budgetNeedsAttention),
  ];
}
