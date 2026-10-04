/**
 * Read hooks — one per screen's data need. Ports of the Flutter providers'
 * load() methods, with react-query doing the caching and deduplication.
 */
import { keepPreviousData, useInfiniteQuery, useQuery } from '@tanstack/react-query';
import { useCallback, useMemo } from 'react';

import {
  buildBudgetProgress,
  buildCategoryBreakdown,
  personalSpending,
  sumBy,
  type CategorySpend,
  type MonthlyPoint,
} from '@/domain/analytics';
import { summariseCard, type CardSummary } from '@/domain/creditCards';
import { PAGE_SIZE } from '@/domain/defaults';
import type { ExpenseFilter } from '@/domain/expenseFilter';
import { FREQUENT_HISTORY_ROWS, FREQUENT_WINDOW_DAYS, frequentExpenses, type FrequentExpense } from '@/domain/frequentExpenses';
import type { CreditCard, Expense } from '@/domain/models';
import type { ClaimSummary } from '@/domain/receivables';
import { buildStatement, type StatementTypeFilter } from '@/domain/statement';
import { tagNames, type Tag, type TagKind } from '@/domain/tags';
import { findTransferMatches, TRANSFER_MATCH_DAYS } from '@/domain/treatment';
import { addDays, addMonths, firstOfMonth, monthRange, today, trailingMonths } from '@/lib/dates';
import { fetchAccountBalances } from '@/services/accounts';
import { fetchBudgetsForMonth } from '@/services/budgets';
import { resolveCapabilities, type SchemaCapabilities } from '@/services/capabilities';
import { fetchCategories, fetchPaymentMethods } from '@/services/catalog';
import { fetchCardEntries, fetchCards } from '@/services/creditCards';
import { fetchById, fetchForMonth, fetchMonthlyTotals, fetchPage, fetchRecent } from '@/services/expenses';
import { fetchClaims, fetchPaidForExpenseIds } from '@/services/receivables';
import {
  fetchIncomeById,
  fetchIncomeForMonth,
  fetchIncomeMonthlyTotals,
  fetchIncomePage,
} from '@/services/income';
import { fetchForAccount, netBefore } from '@/services/ledger';
import { fetchTagIdsFor, fetchTags } from '@/services/tags';
import { useUserId } from '@/state/auth';
import { keys } from '@/state/queryClient';

const EMPTY_CAPS: SchemaCapabilities = {
  merchant: false,
  bankAccounts: false,
  expenseBankLink: false,
  incomeBankLink: false,
  transfers: false,
  creditCards: false,
  treatments: false,
  tags: false,
  statementDetails: false,
  notifications: false,
  notificationInbox: false,
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

export type CreditCardOverview = { card: CreditCard; summary: CardSummary };

async function loadCards(userId: string): Promise<CreditCardOverview[]> {
  const [cards, entries] = await Promise.all([fetchCards(userId), fetchCardEntries(userId, null)]);
  const day = today();
  return cards.map((card) => ({ card, summary: summariseCard(card, entries, day) }));
}

/**
 * Every card with its derived outstanding, available credit and bill status;
 * empty until migration 004 exists. Inactive cards are included.
 */
export function useCreditCards() {
  const userId = useUserId();
  const caps = useCapabilities();
  return useQuery({
    queryKey: [...keys.creditCards(userId), caps.creditCards],
    queryFn: () => (caps.creditCards ? loadCards(userId) : Promise.resolve([])),
  });
}

/**
 * One card's whole history, merged from purchases, bill payments and card
 * transactions. [enabled] lets the screen wait until it knows the card exists.
 */
export function useCardEntries(cardId: string, enabled = true) {
  const userId = useUserId();
  const caps = useCapabilities();
  return useQuery({
    queryKey: keys.cardStatement(userId, cardId),
    queryFn: () => fetchCardEntries(userId, cardId),
    enabled: enabled && caps.creditCards && cardId !== '',
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

/**
 * The reads behind a month's figures, issued concurrently. Expenses paid on
 * someone else's behalf are owed back, so they are left out of spending —
 * and transfers, loans and repayments never reach these tables at all.
 */
async function loadMonth(userId: string, month: string): Promise<MonthRaw> {
  const months = trailingMonths(month, TREND_MONTHS);
  const trendStart = months[0] ?? firstOfMonth(month);
  const trendEnd = addMonths(month, 1);
  const paidFor = await fetchPaidForExpenseIds(userId);
  const [allExpenses, income, expenseTotals, incomeTotals] = await Promise.all([
    fetchForMonth(userId, month),
    fetchIncomeForMonth(userId, month),
    fetchMonthlyTotals(userId, trendStart, trendEnd, paidFor),
    fetchIncomeMonthlyTotals(userId, trendStart, trendEnd),
  ]);
  const expenses = personalSpending(allExpenses, paidFor);
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
      const [budgets, expenses, paidFor] = await Promise.all([
        fetchBudgetsForMonth(userId, month),
        fetchForMonth(userId, month),
        fetchPaidForExpenseIds(userId),
      ]);
      return buildBudgetProgress(budgets, personalSpending(expenses, paidFor));
    },
  });
}

// ---------------------------------------------------------------------------
// Money owed to you
// ---------------------------------------------------------------------------

/** Every loan and paid-for purchase with what is still owed; empty until migration 005 exists. */
export function useClaims() {
  const userId = useUserId();
  const caps = useCapabilities();
  return useQuery({
    queryKey: [...keys.claims(userId), caps.treatments],
    queryFn: () => (caps.treatments ? fetchClaims(userId) : Promise.resolve([] as ClaimSummary[])),
  });
}

/**
 * Rows on [accountId] that could be the other leg of a transfer of [amount]
 * on [date] — opposite direction to [direction], within a few days.
 */
export function useTransferMatches(request: {
  accountId: string | null;
  direction: 'debit' | 'credit';
  amount: number | null;
  date: string;
  /** Rows already chosen elsewhere (e.g. by another row of the same import). */
  excludeIds?: readonly string[];
}) {
  const userId = useUserId();
  const caps = useCapabilities();
  const { accountId, direction, amount, date } = request;
  return useQuery({
    queryKey: keys.transferMatches(userId, { accountId, direction, amount, date }),
    queryFn: async () =>
      findTransferMatches(
        await fetchForAccount({
          userId,
          accountId: accountId ?? '',
          from: addDays(date, -TRANSFER_MATCH_DAYS),
          toExclusive: addDays(date, TRANSFER_MATCH_DAYS + 1),
        }),
        { direction, amount: amount ?? 0, date },
      ),
    enabled: caps.treatments && accountId != null && amount != null && amount > 0,
    select: (matches) => (request.excludeIds?.length ? matches.filter((m) => !request.excludeIds?.includes(m.id)) : matches),
  });
}

/** Purchases up to a few days after [date], newest first — what a reimbursement can pay back. */
export function usePurchasesBefore(date: string, enabled: boolean) {
  const userId = useUserId();
  return useQuery({
    queryKey: keys.purchases(userId, date),
    queryFn: () => fetchRecent(userId, addDays(date, -PURCHASE_LOOKBACK_DAYS), addDays(date, 4), 80),
    enabled,
    staleTime: 60_000,
  });
}

/** How far back purchases are offered when choosing what a reimbursement pays back. */
export const PURCHASE_LOOKBACK_DAYS = 120;

/**
 * Quick add on a new expense: the user's repeat purchases, most frequent
 * first. One lean, cached read; the suggestions are rebuilt from the cached
 * categories, methods, accounts and cards, so none ever points at something
 * deleted or closed. Empty while loading, on error, or when [enabled] is off.
 */
export function useFrequentExpenses(enabled: boolean): FrequentExpense[] {
  const userId = useUserId();
  const day = today();
  const history = useQuery({
    queryKey: keys.frequentExpenses(userId, day),
    queryFn: async () => {
      const [expenses, paidFor] = await Promise.all([
        fetchRecent(userId, addDays(day, -(FREQUENT_WINDOW_DAYS - 1)), addDays(day, 1), FREQUENT_HISTORY_ROWS, { lean: true }),
        fetchPaidForExpenseIds(userId),
      ]);
      return { expenses, paidFor };
    },
    enabled,
    staleTime: 5 * 60_000,
  });
  const categories = useCategories().data;
  const methods = usePaymentMethods().data;
  const accounts = useAccounts().data;
  const cards = useCreditCards().data;
  return useMemo(() => {
    if (!enabled || !history.data || !categories) return [];
    return frequentExpenses(history.data.expenses, {
      today: day,
      excludeIds: history.data.paidFor,
      categoryIds: new Set(categories.map((c) => c.id)),
      paymentMethodIds: new Set((methods ?? []).map((m) => m.id)),
      accountIds: new Set((accounts ?? []).filter((b) => b.account.isActive).map((b) => b.account.id)),
      cardIds: new Set((cards ?? []).filter((o) => o.card.isActive).map((o) => o.card.id)),
    });
  }, [enabled, history.data, categories, methods, accounts, cards, day]);
}

// ---------------------------------------------------------------------------
// Tags
// ---------------------------------------------------------------------------

/** Every tag the user has; empty until migration 006 exists. */
export function useTags() {
  const userId = useUserId();
  const caps = useCapabilities();
  return useQuery({
    queryKey: [...keys.tags(userId), caps.tags],
    queryFn: () => (caps.tags ? fetchTags(userId) : Promise.resolve([] as Tag[])),
    staleTime: 60_000,
  });
}

/**
 * The tag names on one expense or income row. `names` is null until they are
 * known (or when they could not be read) — a form must not save tags then, or
 * it would replace the real ones with an empty list.
 */
export function useTransactionTags(kind: TagKind, id: string | undefined): { names: string[] | null; isPending: boolean } {
  const userId = useUserId();
  const caps = useCapabilities();
  const tags = useTags();
  const enabled = caps.tags && id != null;
  const links = useQuery({
    queryKey: keys.transactionTags(userId, kind, id ?? ''),
    queryFn: () => fetchTagIdsFor(userId, kind, id ?? ''),
    enabled,
    staleTime: 0,
  });
  const isPending = enabled && (links.isPending || tags.isPending);
  return { names: enabled && links.data && tags.data ? tagNames(tags.data, links.data) : null, isPending };
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
