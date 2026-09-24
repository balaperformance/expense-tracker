/**
 * Aggregates computed from raw rows. Port of `models/analytics.dart` and
 * `models/budget.dart`'s progress type. Shared by the dashboard, reports,
 * budgets and export so they can never disagree.
 */
import { FALLBACK_CATEGORY_COLOR } from '@/lib/color';

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
