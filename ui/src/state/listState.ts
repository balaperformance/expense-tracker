/**
 * List screens' search and filter, kept while the user moves around the app —
 * the Flutter providers outlive their screens, so going to an expense and
 * back must not drop the search. In memory only; cleared on sign-out.
 */
import { useSyncExternalStore } from 'react';

import { EMPTY_EXPENSE_FILTER, type ExpenseFilter } from '@/domain/expenseFilter';

type ListState = {
  expenseSearch: string;
  expenseFilter: Omit<ExpenseFilter, 'search'>;
  incomeSearch: string;
};

const INITIAL: ListState = { expenseSearch: '', expenseFilter: EMPTY_EXPENSE_FILTER, incomeSearch: '' };

let state = INITIAL;
const listeners = new Set<() => void>();

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export function updateListState(patch: Partial<ListState>): void {
  state = { ...state, ...patch };
  listeners.forEach((notify) => notify());
}

export function resetListState(): void {
  updateListState(INITIAL);
}

export function useListState(): ListState {
  return useSyncExternalStore(subscribe, () => state, () => INITIAL);
}
