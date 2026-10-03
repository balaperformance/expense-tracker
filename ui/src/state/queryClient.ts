/**
 * Server-state cache. Replaces the Flutter providers' hand-rolled
 * "stale flag + invalidate()" pattern with react-query: every key is scoped
 * by user id, and a sign-out clears the whole cache.
 */
import { QueryClient, type QueryClient as QueryClientType } from '@tanstack/react-query';

import type { ExpenseFilter } from '@/domain/expenseFilter';

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      gcTime: 10 * 60_000,
      retry: (failureCount, error) => {
        // Permission and validation errors will not fix themselves.
        const message = error instanceof Error ? error.message : '';
        if (/permission|session expired/i.test(message)) return false;
        return failureCount < 2;
      },
      refetchOnWindowFocus: true,
    },
    mutations: { retry: false },
  },
});

export const keys = {
  capabilities: (userId: string) => ['capabilities', userId] as const,
  profile: (userId: string) => ['profile', userId] as const,
  categories: (userId: string) => ['categories', userId] as const,
  paymentMethods: (userId: string) => ['paymentMethods', userId] as const,
  accounts: (userId: string) => ['accounts', userId] as const,
  dashboard: (userId: string, month: string) => ['dashboard', userId, month] as const,
  reports: (userId: string, month: string) => ['reports', userId, month] as const,
  budgets: (userId: string, month: string) => ['budgets', userId, month] as const,
  expenses: (userId: string, filter: ExpenseFilter) => ['expenses', userId, filter] as const,
  expense: (userId: string, id: string) => ['expense', userId, id] as const,
  income: (userId: string, search: string) => ['income', userId, search] as const,
  incomeItem: (userId: string, id: string) => ['incomeItem', userId, id] as const,
  statement: (userId: string, accountId: string, period: string) => ['statement', userId, accountId, period] as const,
  creditCards: (userId: string) => ['creditCards', userId] as const,
  cardStatement: (userId: string, cardId: string) => ['cardStatement', userId, cardId] as const,
  exportPreview: (userId: string, request: unknown) => ['export', userId, request] as const,
  /** Money lent and purchases paid for someone, with what is still owed. */
  claims: (userId: string) => ['claims', userId] as const,
  transferMatches: (userId: string, request: unknown) => ['transferMatches', userId, request] as const,
  purchases: (userId: string, beforeDate: string) => ['purchases', userId, beforeDate] as const,
  /** Recent purchases behind Quick add on a new expense. */
  frequentExpenses: (userId: string, day: string) => ['frequentExpenses', userId, day] as const,
  /** Every tag the user has — the suggestions on the expense and income forms. */
  tags: (userId: string) => ['tags', userId] as const,
  /** The tags on one expense or income row. */
  transactionTags: (userId: string, kind: string, id: string) => ['transactionTags', userId, kind, id] as const,
  /** The four notification switches. Not money-bearing, so a write elsewhere never refetches them. */
  notificationPrefs: (userId: string) => ['notificationPrefs', userId] as const,
};

/** Money-bearing query families. A write to any table can move several of them. */
const FINANCE_ROOTS = [
  'accounts',
  'dashboard',
  'reports',
  'budgets',
  'expenses',
  'expense',
  'income',
  'incomeItem',
  'statement',
  'creditCards',
  'cardStatement',
  'export',
  'claims',
  'transferMatches',
  'purchases',
  'frequentExpenses',
  'tags',
  'transactionTags',
];

/**
 * Marks every financial figure stale after a write. Only queries on screen
 * refetch immediately; the rest refresh when next shown. The data involved is
 * one user's months, so this is cheaper than getting a narrower rule wrong.
 */
export function invalidateFinance(client: QueryClientType = queryClient): Promise<void> {
  return client.invalidateQueries({
    predicate: (query) => FINANCE_ROOTS.includes(String(query.queryKey[0])),
  });
}
