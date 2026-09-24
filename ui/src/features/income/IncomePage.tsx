import { useMemo } from 'react';
import { useNavigate } from 'react-router';

import { Page } from '@/components/layout/Page';
import { ListFooter } from '@/components/finance/ListParts';
import { DayHeader, IncomeRow } from '@/components/finance/TransactionRow';
import { Fab } from '@/components/ui/Button';
import { Centered, EmptyState, ErrorView, ListSkeleton } from '@/components/ui/Feedback';
import { SearchField } from '@/components/ui/Fields';
import { CardList } from '@/components/ui/Surface';
import { SwipeRow } from '@/components/ui/SwipeRow';
import { groupByDay } from '@/domain/expenseFilter';
import { incomeTitle, type Income } from '@/domain/models';
import { useAccounts, useCapabilities, useIncomeList } from '@/hooks/data';
import { useDebounced } from '@/hooks/useDebounced';
import { useInfiniteScroll } from '@/hooks/useInfiniteScroll';
import { useDeleteIncome } from '@/hooks/mutations';
import { errorMessage } from '@/lib/errors';
import { formatCurrency, relativeDay } from '@/lib/format';
import { useFeedback } from '@/state/feedback';
import { updateListState, useListState } from '@/state/listState';
import { useSettings } from '@/state/settings';

export function IncomePage() {
  const navigate = useNavigate();
  const { currency } = useSettings();
  const { toast, confirm } = useFeedback();
  const caps = useCapabilities();
  const accounts = useAccounts().data ?? [];
  const { incomeSearch: search } = useListState();
  const setSearch = (value: string) => updateListState({ incomeSearch: value });
  const debounced = useDebounced(search);
  const list = useIncomeList(debounced);
  const remove = useDeleteIncome();

  const items = useMemo(() => list.data?.pages.flat() ?? [], [list.data]);
  const groups = useMemo(() => groupByDay(items, (i) => i.incomeDate, (i) => i.amount), [items]);
  const sentinel = useInfiniteScroll(() => {
    if (list.hasNextPage && !list.isFetchingNextPage) void list.fetchNextPage();
  }, list.hasNextPage);

  const destination = (income: Income) =>
    caps.bankAccounts && income.bankAccountId
      ? (accounts.find((b) => b.account.id === income.bankAccountId)?.account.nickname ?? null)
      : null;

  const confirmDelete = async (income: Income) => {
    const ok = await confirm({
      title: 'Delete income?',
      message: `${formatCurrency(income.amount, currency)} · ${incomeTitle(income)}. This cannot be undone.`,
    });
    if (!ok) return;
    try {
      await remove.mutateAsync(income.id);
      toast('success', 'Income deleted');
    } catch (error) {
      toast('error', errorMessage(error, 'Could not delete the income.'));
    }
  };

  let body;
  if (list.isPending) body = <ListSkeleton />;
  else if (list.isError && !items.length) {
    body = (
      <Centered>
        <ErrorView message={errorMessage(list.error)} onRetry={() => void list.refetch()} />
      </Centered>
    );
  } else if (!items.length && !debounced.trim()) {
    body = (
      <Centered>
        <EmptyState
          icon="income"
          title="No income yet"
          message="Record salary, freelance work or any other money in."
          actionLabel="Add income"
          onAction={() => void navigate('/income/new')}
        />
      </Centered>
    );
  } else if (!items.length) {
    body = (
      <Centered>
        <EmptyState icon="searchOff" title="No matches" message={`Nothing matches "${debounced}".`} actionLabel="Clear search" onAction={() => setSearch('')} />
      </Centered>
    );
  } else {
    body = (
      <div style={{ opacity: list.isPlaceholderData ? 0.6 : 1, transition: 'opacity var(--dur-fast)' }}>
        {groups.map((group, i) => (
          <section key={group.day}>
            <DayHeader label={relativeDay(group.day)} total={group.total} currency={currency} tone="positive" first={i === 0} />
            <CardList>
              {group.items.map((income) => (
                <SwipeRow key={income.id} onDelete={() => void confirmDelete(income)}>
                  <IncomeRow
                    income={income}
                    currency={currency}
                    showDate={false}
                    destinationLabel={destination(income)}
                    onClick={() => void navigate(`/income/${income.id}`)}
                  />
                </SwipeRow>
              ))}
            </CardList>
          </section>
        ))}
        <div ref={sentinel} />
        <ListFooter loading={list.isFetchingNextPage} hasMore={list.hasNextPage} count={items.length} noun={['entry', 'entries']} />
      </div>
    );
  }

  return (
    <Page title="Income" below={<SearchField value={search} onChange={setSearch} placeholder="Search source or description" />}>
      {body}
      <Fab label="Income" railed onClick={() => void navigate('/income/new')} />
    </Page>
  );
}
