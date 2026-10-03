import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router';

import { Page } from '@/components/layout/Page';
import { ListFooter } from '@/components/finance/ListParts';
import { DayHeader, ExpenseRow } from '@/components/finance/TransactionRow';
import { Button, Fab, IconButton } from '@/components/ui/Button';
import { ChoiceSheet } from '@/components/ui/ChoiceSheet';
import { Centered, EmptyState, ErrorView, ListSkeleton } from '@/components/ui/Feedback';
import { SearchField } from '@/components/ui/Fields';
import { Icon } from '@/components/ui/Icon';
import { CardList } from '@/components/ui/Surface';
import { SwipeRow } from '@/components/ui/SwipeRow';
import {
  activeFilterCount,
  EMPTY_EXPENSE_FILTER,
  EXPENSE_SORTS,
  groupByDay,
  hasAnyFilter,
  type ExpenseFilter,
} from '@/domain/expenseFilter';
import { cardLabel, expenseTitle, type Expense } from '@/domain/models';
import { useAccounts, useCapabilities, useClaims, useCreditCards, useExpenseList } from '@/hooks/data';
import { useDebounced } from '@/hooks/useDebounced';
import { useInfiniteScroll } from '@/hooks/useInfiniteScroll';
import { useDeleteExpense } from '@/hooks/mutations';
import { errorMessage } from '@/lib/errors';
import { formatCurrency, relativeDay } from '@/lib/format';
import { useFeedback } from '@/state/feedback';
import { updateListState, useListState } from '@/state/listState';
import { useSettings } from '@/state/settings';

import { FilterSheet } from './FilterSheet';

export function ExpensesPage() {
  const navigate = useNavigate();
  const { currency } = useSettings();
  const { toast, confirm } = useFeedback();
  const caps = useCapabilities();
  const accounts = useAccounts().data ?? [];
  const cards = useCreditCards().data ?? [];
  const claims = useClaims().data;
  const paidFor = useMemo(
    () => new Map((claims ?? []).flatMap((c) => (c.receivable.expenseId ? [[c.receivable.expenseId, c.receivable.person] as const] : []))),
    [claims],
  );
  const { expenseSearch: search, expenseFilter: filter } = useListState();
  const setSearch = (value: string) => updateListState({ expenseSearch: value });
  const setFilter = (next: Omit<ExpenseFilter, 'search'>) => updateListState({ expenseFilter: next });
  const [sheet, setSheet] = useState<'filter' | 'sort' | null>(null);
  const [filterKey, setFilterKey] = useState(0);
  const debounced = useDebounced(search);
  const query = useMemo<ExpenseFilter>(() => ({ ...filter, search: debounced }), [filter, debounced]);
  const list = useExpenseList(query);
  const remove = useDeleteExpense();
  const count = activeFilterCount(query);

  const expenses = useMemo(() => list.data?.pages.flat() ?? [], [list.data]);
  const groups = useMemo(() => groupByDay(expenses, (e) => e.expenseDate, (e) => e.amount), [expenses]);
  const sentinel = useInfiniteScroll(() => {
    if (list.hasNextPage && !list.isFetchingNextPage) void list.fetchNextPage();
  }, list.hasNextPage);

  /** Where the money came from: a card, an account nickname, or the payment method / Cash. */
  const fundingLabel = (expense: Expense) => {
    if (expense.creditCardId != null) {
      const card = cards.find((o) => o.card.id === expense.creditCardId)?.card;
      return card ? cardLabel(card) : 'Credit card';
    }
    if (!caps.bankAccounts) return null;
    if (expense.bankAccountId == null) return expense.paymentMethod?.name ?? 'Cash';
    return accounts.find((b) => b.account.id === expense.bankAccountId)?.account.nickname ?? null;
  };
  /** A purchase paid on someone else's behalf says so: it is owed back, not the user's spending. */
  const sourceLabel = (expense: Expense) => {
    const person = paidFor.get(expense.id);
    const funding = fundingLabel(expense);
    return person ? [funding, `paid for ${person}`].filter(Boolean).join(' · ') : funding;
  };

  const confirmDelete = async (expense: Expense) => {
    const ok = await confirm({
      title: 'Delete expense?',
      message: `${formatCurrency(expense.amount, currency)} · ${expenseTitle(expense)}. This cannot be undone.`,
    });
    if (!ok) return;
    try {
      await remove.mutateAsync(expense.id);
      toast('success', 'Expense deleted');
    } catch (error) {
      toast('error', errorMessage(error, 'Could not delete the expense.'));
    }
  };

  const clearFilters = () => setFilter({ ...EMPTY_EXPENSE_FILTER, sort: filter.sort });
  const clearAll = () => {
    setSearch('');
    clearFilters();
  };

  const exportUrl = `/export?type=expenses${query.from && query.to ? `&from=${query.from}&to=${query.to}` : ''}`;

  let body;
  if (list.isPending) body = <ListSkeleton />;
  else if (list.isError && !expenses.length) {
    body = (
      <Centered>
        <ErrorView message={errorMessage(list.error)} onRetry={() => void list.refetch()} />
      </Centered>
    );
  } else if (!expenses.length && !hasAnyFilter(query)) {
    body = (
      <Centered>
        <EmptyState
          icon="expenses"
          title="No expenses yet"
          message="Add your first expense to start seeing it here."
          actionLabel="Add expense"
          onAction={() => void navigate('/expenses/new')}
        />
      </Centered>
    );
  } else if (!expenses.length) {
    body = (
      <Centered>
        <EmptyState icon="searchOff" title="No matches" message="Nothing matches your search and filters." actionLabel="Clear all" onAction={clearAll} />
      </Centered>
    );
  } else {
    body = (
      <div style={{ opacity: list.isPlaceholderData ? 0.6 : 1, transition: 'opacity var(--dur-fast)' }}>
        {groups.map((group, i) => (
          <section key={group.day}>
            <DayHeader label={relativeDay(group.day)} total={group.total} currency={currency} first={i === 0} />
            <CardList>
              {group.items.map((expense) => (
                <SwipeRow key={expense.id} onDelete={() => void confirmDelete(expense)}>
                  <ExpenseRow
                    expense={expense}
                    currency={currency}
                    showDate={false}
                    sourceLabel={sourceLabel(expense)}
                    onClick={() => void navigate(`/expenses/${expense.id}`)}
                  />
                </SwipeRow>
              ))}
            </CardList>
          </section>
        ))}
        <div ref={sentinel} />
        <ListFooter loading={list.isFetchingNextPage} hasMore={list.hasNextPage} count={expenses.length} noun={['expense', 'expenses']} />
      </div>
    );
  }

  return (
    <Page
      title="Expenses"
      actions={
        <>
          <IconButton icon="export" label="Export" onClick={() => void navigate(exportUrl)} />
          <IconButton icon="sort" label="Sort" onClick={() => setSheet('sort')} />
          <IconButton
            icon={count ? 'filterActive' : 'filter'}
            label="Filter"
            badge={count || undefined}
            color={count ? 'var(--primary)' : undefined}
            onClick={() => {
              setFilterKey((k) => k + 1);
              setSheet('filter');
            }}
          />
        </>
      }
      below={
        <div className="stack gap-sm">
          <SearchField value={search} onChange={setSearch} placeholder="Search merchant, note or description" />
          {count ? (
            <div className="row gap-sm">
              <button
                type="button"
                className="row gap-sm grow t-body-sm"
                style={{ color: 'var(--primary)', fontWeight: 600 }}
                onClick={() => {
                  setFilterKey((k) => k + 1);
                  setSheet('filter');
                }}
              >
                <Icon name="filterActive" size={16} />
                {count} {count === 1 ? 'filter' : 'filters'} applied
              </button>
              <Button label="Clear" variant="ghost" size="sm" onClick={clearFilters} />
            </div>
          ) : null}
        </div>
      }
    >
      {body}
      <Fab label="Add" railed onClick={() => void navigate('/expenses/new')} />
      <FilterSheet
        key={filterKey}
        open={sheet === 'filter'}
        initial={query}
        onClose={() => setSheet(null)}
        onApply={(next) => {
          setFilter({ categoryIds: next.categoryIds, paymentMethodIds: next.paymentMethodIds, from: next.from, to: next.to, sort: next.sort });
          setSheet(null);
        }}
      />
      <ChoiceSheet
        open={sheet === 'sort'}
        onClose={() => setSheet(null)}
        title="Sort by"
        options={EXPENSE_SORTS}
        value={filter.sort}
        onChoose={(sort) => {
          setFilter({ ...filter, sort });
          setSheet(null);
        }}
      />
    </Page>
  );
}
