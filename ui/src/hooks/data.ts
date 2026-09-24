/**
 * Read hooks — one per screen's data need. Ports of the Flutter providers'
 * load() methods, with react-query doing the caching and deduplication.
 */
import { keepPreviousData, useInfiniteQuery, useQuery } from '@tanstack/react-query';
import { useCallback } from 'react';

import { buildBudgetProgress, buildCategoryBreakdown, sumBy, type CategorySpend, type MonthlyPoint } from '@/domain/analytics';
import { PAGE_SIZE } from '@/domain/defaults';
import type { ExpenseFilter } from '@/domain/expenseFilter';
import type { Expense } from '@/domain/models';
import { buildStatement, type StatementTypeFilter } from '@/domain/statement';
import { addMonths, firstOfMonth, monthRange, trailingMonths } from '@/lib/dates';
import { fetchAccountBalances } from '@/services/accounts';
import { fetchBudgetsForMonth } from '@/services/budgets';
import { resolveCapabilities, type SchemaCapabilities } from '@/services/capabilities';
import { fetchCategories, fetchPaymentMethods } from '@/services/catalog';
import { fetchById, fetchForMonth, fetchMonthlyTotals, fetchPage } from '@/services/expenses';
import {
  fetchIncomeById,
  fetchIncomeForMonth,
  fetchIncomeMonthlyTotals,
  fetchIncomePage,
} from '@/services/income';
import { fetchForAccount, netBefore } from '@/services/ledger';
import { useUserId } from '@/state/auth';
import { keys } from '@/state/queryClient';

const EMPTY_CAPS: SchemaCapabilities = {
  merchant: false,
  bankAccounts: false,
  expenseBankLink: false,
  incomeBankLink: false,
  transfers: false,
};

export function useCapabilities(): SchemaCapabilities {
  const userId = useUserId();
  const { data } = useQuery({
    queryKey: keys.capabilities(userId),
    queryFn: () => resolveCapabilities(true),
    staleTime: Infinity,
  });
  return data ?? EMPTY_CAPS;
}

export function useCategories() {
  const userId = useUserId();
  return useQuery({ queryKey: keys.categories(userId), queryFn: () => fetchCategories(userId), staleTime: 5 * 60_000 });
}

export function usePaymentMethods() {
  const userId = useUserId();
  return useQuery({ queryKey: keys.paymentMethods(userId), queryFn: () => fetchPaymentMethods(userId), staleTime: 5 * 60_000 });
}

/** Bank accounts with ledger-derived balances; empty until the Phase 2 migration exists. */
export function useAccounts() {
  const userId = useUserId();
  const caps = useCapabilities();
  return useQuery({
    queryKey: [...keys.accounts(userId), caps.bankAccounts],
    queryFn: () => (caps.bankAccounts ? fetchAccountBalances(userId) : Promise.resolve([])),
  });
}

// ---------------------------------------------------------------------------
// Dashboard & reports
// ---------------------------------------------------------------------------

const TREND_MONTHS = 6;

type MonthRaw = {
  month: string;
  totalExpense: number;
  totalIncome: number;
  expenses: Expense[];
  trend: MonthlyPoint[];
};

export type MonthSummary = MonthRaw & { breakdown: CategorySpend[] };

/** The five reads behind a month's figures, issued concurrently. */
async function loadMonth(userId: string, month: string): Promise<MonthRaw> {
  const months = trailingMonths(month, TREND_MONTHS);
  const trendStart = months[0] ?? firstOfMonth(month);
  const trendEnd = addMonths(month, 1);
  const [expenses, income, expenseTotals, incomeTotals] = await Promise.all([
    fetchForMonth(userId, month),
    fetchIncomeForMonth(userId, month),
    fetchMonthlyTotals(userId, trendStart, trendEnd),
    fetchIncomeMonthlyTotals(userId, trendStart, trendEnd),
  ]);
  return {
    month: firstOfMonth(month),
    totalExpense: sumBy(expenses, (e) => e.amount),
    totalIncome: sumBy(income, (i) => i.amount),
    expenses,
    trend: months.map((m) => ({
      month: m,
      expense: expenseTotals.get(m.slice(0, 7)) ?? 0,
      income: incomeTotals.get(m.slice(0, 7)) ?? 0,
    })),
  };
}

/** Adds the category breakdown from the cached category list, so it never costs a request. */
function useWithBreakdown() {
  const categories = useCategories().data;
  return useCallback(
    (raw: MonthRaw): MonthSummary => ({ ...raw, breakdown: buildCategoryBreakdown(raw.expenses, categories ?? []) }),
    [categories],
  );
}

/** Everything the dashboard renders for the current month, in one pass. */
export function useDashboard(anyDayOfMonth: string) {
  const userId = useUserId();
  const month = firstOfMonth(anyDayOfMonth);
  const select = useWithBreakdown();
  return useQuery({ queryKey: keys.dashboard(userId, month), queryFn: () => loadMonth(userId, month), select });
}

/** Report figures for any month; the previous month stays on screen while stepping. */
export function useReport(anyDayOfMonth: string) {
  const userId = useUserId();
  const month = firstOfMonth(anyDayOfMonth);
  const select = useWithBreakdown();
  return useQuery({
    queryKey: keys.reports(userId, month),
    queryFn: () => loadMonth(userId, month),
    placeholderData: keepPreviousData,
    select,
  });
}

export function useBudgets(anyDayOfMonth: string) {
  const userId = useUserId();
  const month = firstOfMonth(anyDayOfMonth);
  return useQuery({
    queryKey: keys.budgets(userId, month),
    queryFn: async () => {
      const [budgets, expenses] = await Promise.all([fetchBudgetsForMonth(userId, month), fetchForMonth(userId, month)]);
      return buildBudgetProgress(budgets, expenses);
    },
  });
}

// ---------------------------------------------------------------------------
// Lists
// ---------------------------------------------------------------------------

export function useExpenseList(filter: ExpenseFilter) {
  const userId = useUserId();
  return useInfiniteQuery({
    queryKey: keys.expenses(userId, filter),
    queryFn: ({ pageParam }) => fetchPage(userId, filter, pageParam),
    initialPageParam: 0,
    getNextPageParam: (last, pages) => (last.length === PAGE_SIZE ? pages.length : undefined),
    placeholderData: keepPreviousData,
  });
}

export function useIncomeList(search: string) {
  const userId = useUserId();
  return useInfiniteQuery({
    queryKey: keys.income(userId, search),
    queryFn: ({ pageParam }) => fetchIncomePage(userId, search, pageParam),
    initialPageParam: 0,
    getNextPageParam: (last, pages) => (last.length === PAGE_SIZE ? pages.length : undefined),
    placeholderData: keepPreviousData,
  });
}

export function useExpense(id: string | undefined) {
  const userId = useUserId();
  return useQuery({
    queryKey: keys.expense(userId, id ?? ''),
    queryFn: () => fetchById(userId, id ?? ''),
    enabled: id != null,
    staleTime: 0,
  });
}

export function useIncomeItem(id: string | undefined) {
  const userId = useUserId();
  return useQuery({
    queryKey: keys.incomeItem(userId, id ?? ''),
    queryFn: () => fetchIncomeById(userId, id ?? ''),
    enabled: id != null,
    staleTime: 0,
  });
}

// ---------------------------------------------------------------------------
// Statement
// ---------------------------------------------------------------------------

/**
 * One account over one period. The brought-forward balance is fetched
 * separately, so a filtered month still shows a correct running balance.
 * The type filter is applied locally and never costs a request.
 */
export function useStatement({
  accountId,
  openingBalance,
  month,
  wholeHistory,
  typeFilter,
}: {
  accountId: string;
  openingBalance: number;
  month: string;
  wholeHistory: boolean;
  typeFilter: StatementTypeFilter;
}) {
  const userId = useUserId();
  const period = wholeHistory ? 'all' : firstOfMonth(month);
  return useQuery({
    queryKey: keys.statement(userId, accountId, period),
    queryFn: async () => {
      const range = monthRange(month);
      const [entries, priorNet] = await Promise.all([
        fetchForAccount({
          userId,
          accountId,
          from: wholeHistory ? null : range.start,
          toExclusive: wholeHistory ? null : range.endExclusive,
        }),
        wholeHistory ? Promise.resolve(0) : netBefore(userId, accountId, range.start),
      ]);
      return { entries, priorNet };
    },
    placeholderData: keepPreviousData,
    select: ({ entries, priorNet }) => buildStatement({ openingBalance: openingBalance + priorNet, entries, typeFilter }),
  });
}
