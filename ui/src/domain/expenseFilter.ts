/**
 * Query parameters for the expenses list. Port of `models/expense_filter.dart`.
 */
export type ExpenseSort = 'newestFirst' | 'oldestFirst' | 'highestAmount' | 'lowestAmount';

export const EXPENSE_SORTS: ReadonlyArray<{ value: ExpenseSort; label: string }> = [
  { value: 'newestFirst', label: 'Newest first' },
  { value: 'oldestFirst', label: 'Oldest first' },
  { value: 'highestAmount', label: 'Highest amount' },
  { value: 'lowestAmount', label: 'Lowest amount' },
];

export function sortColumn(sort: ExpenseSort): 'expense_date' | 'amount' {
  return sort === 'newestFirst' || sort === 'oldestFirst' ? 'expense_date' : 'amount';
}

export function sortAscending(sort: ExpenseSort): boolean {
  return sort === 'oldestFirst' || sort === 'lowestAmount';
}

export type ExpenseFilter = {
  search: string;
  categoryIds: readonly string[];
  paymentMethodIds: readonly string[];
  from: string | null;
  to: string | null;
  sort: ExpenseSort;
};

export const EMPTY_EXPENSE_FILTER: ExpenseFilter = {
  search: '',
  categoryIds: [],
  paymentMethodIds: [],
  from: null,
  to: null,
  sort: 'newestFirst',
};

/** Number of active constraints, shown as a badge on the filter button. */
export function activeFilterCount(filter: ExpenseFilter): number {
  let count = 0;
  if (filter.categoryIds.length) count++;
  if (filter.paymentMethodIds.length) count++;
  if (filter.from != null || filter.to != null) count++;
  return count;
}

export function hasAnyFilter(filter: ExpenseFilter): boolean {
  return activeFilterCount(filter) > 0 || filter.search.trim().length > 0;
}

/** Strips characters that would break PostgREST `or=` clause parsing. */
export function sanitiseSearch(raw: string): string {
  return raw.trim().replace(/[,()*%\\]/g, '');
}

/** Groups a newest-first list into consecutive day buckets. */
export function groupByDay<T>(items: readonly T[], day: (item: T) => string, amount: (item: T) => number) {
  const groups: { day: string; items: T[]; total: number }[] = [];
  for (const item of items) {
    const key = day(item);
    let last = groups[groups.length - 1];
    if (!last || last.day !== key) {
      last = { day: key, items: [], total: 0 };
      groups.push(last);
    }
    last.items.push(item);
    last.total += amount(item);
  }
  return groups;
}
