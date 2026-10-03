import { useEffect, useRef, useState, type ReactNode } from 'react';
import { useNavigate } from 'react-router';

import { CardCarousel, type CarouselPage } from '@/components/charts/CardCarousel';
import { CategoryBreakdownList, CategoryDonut } from '@/components/charts/CategoryCharts';
import { MonthlyTrendCard } from '@/components/charts/TrendCharts';
import { Page } from '@/components/layout/Page';
import { BankAvatar, CardAvatar } from '@/components/finance/Avatars';
import { BudgetAlertBanner, BudgetCard } from '@/components/finance/Budget';
import { Money } from '@/components/finance/Money';
import { BalanceCard, QuickActions } from '@/components/finance/Stats';
import { ExpenseRow } from '@/components/finance/TransactionRow';
import { Fab, IconButton } from '@/components/ui/Button';
import { EmptyState, ErrorView, Skeleton } from '@/components/ui/Feedback';
import { Card, CardList, IconWell, ListRow, SectionHeader } from '@/components/ui/Surface';
import { budgetAlerts } from '@/domain/analytics';
import { dueSummaryText } from '@/domain/creditCards';
import { accountBankLine, accountInitial, currentBalance, totalBalance, type BankAccountBalance } from '@/domain/models';
import { useAccounts, useBudgets, useCreditCards, useDashboard } from '@/hooks/data';
import { errorMessage } from '@/lib/errors';
import { greeting, monthYear, shortMonth } from '@/lib/format';
import { today } from '@/lib/dates';
import { useSettings } from '@/state/settings';

import styles from './Dashboard.module.css';

const DONUT_SIZE = 136;
const TREND_HEIGHT = 244;
const CARD_HEIGHT = 326;

export function DashboardPage() {
  const navigate = useNavigate();
  const settings = useSettings();
  const month = today();
  const dashboard = useDashboard(month);
  const budgets = useBudgets(month);
  const accounts = useAccounts();
  const cards = useCreditCards();
  const currency = settings.currency;

  const frame = (body: ReactNode) => (
    <Page
      eyebrow={greeting().toUpperCase()}
      title={settings.displayName}
      documentTitle="Home"
      actions={
        <>
          <IconButton icon="assistant" label="Ask the assistant" glass onClick={() => void navigate('/assistant')} />
          <IconButton icon="bank" label="Bank accounts" glass className={styles.headerAction} onClick={() => void navigate('/accounts')} />
        </>
      }
    >
      {body}
    </Page>
  );

  if (dashboard.isPending) return frame(<DashboardSkeleton />);
  if (dashboard.isError) {
    return frame(<ErrorView message={errorMessage(dashboard.error)} onRetry={() => void dashboard.refetch()} />);
  }

  const data = dashboard.data;
  const hasAnyData = data.totalExpense > 0 || data.totalIncome > 0 || data.expenses.length > 0;
  const balances = accounts.data ?? [];
  const hasAccounts = balances.length > 0;
  const bankTotal = hasAccounts ? totalBalance(balances) : null;
  // Cards in use, and closed ones still being paid off; the full list is on the Credit cards screen.
  const cardsShown = (cards.data ?? []).filter((o) => o.card.isActive || o.summary.outstanding > 0).slice(0, 3);
  const recent = data.expenses.slice(0, 5);
  const hasTrend = data.trend.some((p) => p.expense > 0 || p.income > 0);
  const chartPages: CarouselPage[] = [
    ...(data.breakdown.length
      ? [
          {
            title: 'Where it went',
            caption: shortMonth(data.month),
            content: (
              <div className={styles.chartsCard}>
                <CategoryDonut breakdown={data.breakdown} currency={currency} size={DONUT_SIZE} />
                <CategoryBreakdownList breakdown={data.breakdown} currency={currency} limit={3} />
              </div>
            ),
          },
        ]
      : []),
    ...(hasTrend
      ? [{ title: 'Monthly spending', content: <MonthlyTrendCard points={data.trend} currency={currency} chartHeight={TREND_HEIGHT} /> }]
      : []),
  ];

  const budgetMonth = budgets.data;
  const alerts = budgetMonth ? budgetAlerts(budgetMonth) : [];

  const heroGroup = (
    <div className={styles.heroGroup}>
      <BalanceCard
        income={data.totalIncome}
        expense={data.totalExpense}
        currency={currency}
        monthLabel={shortMonth(data.month)}
        bankTotal={bankTotal}
        bankTotalHidden={settings.balancesHidden}
        onToggleBankTotal={settings.toggleBalancesHidden}
      />
      <QuickActions
        actions={[
          { label: 'Expense', icon: 'expense', tone: 'var(--expense)', onClick: () => void navigate('/expenses/new') },
          { label: 'Income', icon: 'incomeAdd', tone: 'var(--income)', onClick: () => void navigate('/income/new') },
          { label: 'Accounts', icon: 'bank', tone: 'var(--primary)', onClick: () => void navigate('/accounts') },
          { label: 'Budgets', icon: 'budget', tone: 'var(--accent)', onClick: () => void navigate('/budgets') },
        ]}
      />
    </div>
  );

  // Two independent columns on wide screens (money on the left, charts and
  // activity on the right) so neither waits for the other's height. On a
  // phone the columns dissolve and the charts lead, as in the app.
  return frame(
    <>
      <div className={styles.frame}>
        <div className={[styles.dash, !hasAnyData && styles.dashSingle].filter(Boolean).join(' ')}>
          <div className={styles.colMain}>
            {heroGroup}
            {!hasAnyData ? (
              <Card>
                <EmptyState
                  icon="arrowForward"
                  title="Start tracking"
                  message="Add your first expense and this screen fills in with totals, categories and trends."
                  actionLabel="Add your first expense"
                  onAction={() => void navigate('/expenses/new')}
                />
              </Card>
            ) : null}
            {hasAnyData && budgetMonth && !budgetMonth.overall && alerts.length === 0 ? (
              <Card padding="flush">
                <ListRow
                  leading={<IconWell icon="budget" tone="var(--accent)" />}
                  title="Set a monthly budget"
                  subtitle="See how much of your plan you have used"
                  chevron
                  to="/budgets"
                />
              </Card>
            ) : null}
            {hasAnyData && alerts.length ? <BudgetAlertBanner alerts={alerts} onClick={() => void navigate('/budgets')} /> : null}
            {hasAnyData && budgetMonth?.overall ? (
              <div className={styles.block}>
                <SectionHeader title="Budget" actionLabel="Manage" actionTo="/budgets" />
                <BudgetCard progress={budgetMonth.overall} currency={currency} showAvatar={false} onClick={() => void navigate('/budgets')} />
              </div>
            ) : null}
            {hasAnyData && hasAccounts ? (
              <div className={styles.block}>
                <SectionHeader title="Accounts" actionLabel="View" actionTo="/accounts" />
                <AccountCarousel balances={balances} currency={currency} masked={settings.balancesHidden} onOpen={() => void navigate('/accounts')} />
              </div>
            ) : null}
            {hasAnyData && cardsShown.length ? (
              <div className={styles.block}>
                <SectionHeader title="Credit cards" actionLabel="View" actionTo="/cards" />
                <CardList>
                  {cardsShown.map(({ card, summary }) => (
                    <ListRow
                      key={card.id}
                      leading={<CardAvatar />}
                      title={card.cardName}
                      subtitle={dueSummaryText(summary, currency)}
                      trailing={<Money amount={summary.outstanding} currency={currency} obscured={settings.balancesHidden} className={styles.balance} />}
                      to={`/cards/${card.id}`}
                    />
                  ))}
                </CardList>
              </div>
            ) : null}
          </div>
          {hasAnyData ? (
            <div className={styles.colSide}>
              {chartPages.length ? (
                <div className={styles.charts}>
                  <CardCarousel pages={chartPages} height={CARD_HEIGHT} />
                </div>
              ) : null}
              <div className={`${styles.block} ${styles.recent}`}>
                {recent.length ? (
                  <>
                    <SectionHeader title="Recent" caption={monthYear(data.month)} actionLabel="All" actionTo="/expenses" />
                    <CardList>
                      {recent.map((expense) => (
                        <ExpenseRow key={expense.id} expense={expense} currency={currency} onClick={() => void navigate(`/expenses/${expense.id}`)} />
                      ))}
                    </CardList>
                  </>
                ) : (
                  <>
                    <SectionHeader title="Recent" />
                    <Card>
                      <EmptyState
                        compact
                        icon="expenses"
                        title="Nothing this month"
                        message="Expenses you add will show up here."
                        actionLabel="Add expense"
                        onAction={() => void navigate('/expenses/new')}
                      />
                    </Card>
                  </>
                )}
              </div>
            </div>
          ) : null}
        </div>
      </div>
      <Fab label="Add" railed onClick={() => void navigate('/expenses/new')} />
    </>,
  );
}

function DashboardSkeleton() {
  return (
    <div className={styles.layout} aria-busy="true" aria-label="Loading">
      <Card>
        <div className="stack gap-md">
          <Skeleton width={90} height={11} />
          <Skeleton width={170} height={30} />
          <Skeleton height={54} radius={14} />
        </div>
      </Card>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 8 }}>
        {[0, 1, 2, 3].map((i) => (
          <Skeleton key={i} height={62} radius={14} />
        ))}
      </div>
      <Skeleton width={70} height={11} />
      <Skeleton height={148} radius={20} />
    </div>
  );
}

function AccountCarousel({
  balances,
  currency,
  masked,
  onOpen,
}: {
  balances: BankAccountBalance[];
  currency: string;
  masked: boolean;
  onOpen: () => void;
}) {
  const track = useRef<HTMLDivElement>(null);
  const [index, setIndex] = useState(0);
  useEffect(() => {
    const node = track.current;
    if (!node) return;
    const onScroll = () => setIndex(Math.round(node.scrollLeft / (node.clientWidth || 1)));
    node.addEventListener('scroll', onScroll, { passive: true });
    return () => node.removeEventListener('scroll', onScroll);
  }, []);
  return (
    <div>
      <div ref={track} className={styles.accountTrack}>
        {balances.map((balance) => {
          const value = currentBalance(balance);
          return (
            <div key={balance.account.id} className={styles.accountSlide}>
              <Card padding="flush" onClick={onOpen} ariaLabel={`${balance.account.nickname} account`}>
                <ListRow
                  leading={<BankAvatar initial={accountInitial(balance.account)} />}
                  title={balance.account.nickname}
                  subtitle={accountBankLine(balance.account)}
                  trailing={
                    <Money amount={value} currency={currency} obscured={masked} tone={value < 0 ? 'negative' : 'neutral'} className={styles.balance} />
                  }
                />
              </Card>
            </div>
          );
        })}
      </div>
      {balances.length > 1 ? (
        <div className={styles.dots} aria-hidden>
          {balances.map((b, i) => (
            <span key={b.account.id} className={[styles.dot, i === index && styles.dotOn].filter(Boolean).join(' ')} />
          ))}
        </div>
      ) : null}
    </div>
  );
}
