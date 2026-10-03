import { useState, type CSSProperties } from 'react';
import { useNavigate } from 'react-router';

import { CategoryBreakdownList, CategoryDonut } from '@/components/charts/CategoryCharts';
import { segmentColor } from '@/components/charts/palette';
import { ChartLegend, MonthlyTrendChart } from '@/components/charts/TrendCharts';
import { Page } from '@/components/layout/Page';
import { Money } from '@/components/finance/Money';
import { MonthStepper, StatTile } from '@/components/finance/Stats';
import { Button, IconButton } from '@/components/ui/Button';
import { Centered, EmptyState, ErrorView, ListSkeleton } from '@/components/ui/Feedback';
import { Card, CardHeader, IconWell, ListRow } from '@/components/ui/Surface';
import type { IconName } from '@/components/ui/Icon';
import { averagePerExpense, isMonthInProgress, monthStanding, shareOf, sumBy, type MonthStanding } from '@/domain/analytics';
import { totalBalance } from '@/domain/models';
import { useAccounts, useCapabilities, useReport } from '@/hooks/data';
import { addMonths, firstOfMonth, today } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { formatCurrency, formatPercent, monthYear, shortMonth } from '@/lib/format';
import { useSettings } from '@/state/settings';

import styles from './Reports.module.css';

/** Categories listed before the rest fold behind "Show all" — the same count the ring names. */
const LIST_LIMIT = 6;
const DONUT_SIZE = 156;

export function ReportsPage() {
  const navigate = useNavigate();
  const { currency, balancesHidden, toggleBalancesHidden } = useSettings();
  const [month, setMonth] = useState(firstOfMonth(today()));
  const [showAll, setShowAll] = useState(false);
  const report = useReport(month);
  const caps = useCapabilities();
  const accounts = useAccounts();
  const canGoForward = month < firstOfMonth(today());
  const data = report.data;
  const changeMonth = (delta: number) => {
    setMonth((m) => addMonths(m, delta));
    setShowAll(false);
  };

  // The month on screen — while stepping, the previous month's figures stay up until the next arrive.
  const shownMonth = data?.month ?? month;
  const inProgress = isMonthInProgress(shownMonth, today());
  const balances = accounts.data ?? [];
  // Today's balance belongs only beside the month that is still running.
  const available = inProgress && balances.length ? totalBalance(balances) : null;
  const balancePending = inProgress && caps.bankAccounts && accounts.isPending;

  let body;
  if (report.isPending || balancePending) body = <ListSkeleton rows={5} />;
  else if (report.isError && !data) {
    body = (
      <Centered>
        <ErrorView message={errorMessage(report.error)} onRetry={() => void report.refetch()} />
      </Centered>
    );
  } else if (!data || (data.totalExpense === 0 && data.totalIncome === 0 && available == null)) {
    body = (
      <Centered>
        <EmptyState icon="insights" title="Nothing to report" message={`No income or expenses recorded in ${monthYear(month)}.`} />
      </Centered>
    );
  } else {
    const count = data.expenses.length;
    const top = data.breakdown[0];
    const hasBreakdown = data.breakdown.length > 0;
    const folded = data.breakdown.length > LIST_LIMIT;
    const topTone = segmentColor(0, data.breakdown.length);
    const topShare = top ? shareOf(top, sumBy(data.breakdown, (c) => c.total)) : 0;
    const head = monthHead(
      monthStanding({ inProgress, available, income: data.totalIncome, expense: data.totalExpense }),
      balances.length,
      shownMonth,
    );

    body = (
      <div className={styles.frame}>
        <div
          className={styles.grid}
          data-layout={hasBreakdown ? 'full' : 'summary'}
          style={{ opacity: report.isPlaceholderData ? 0.6 : 1 }}
        >
          <Card className={`${styles.cell} ${styles.saved}`} style={{ '--tone': head.tone } as CSSProperties}>
            <div className={styles.savedHead}>
              <div className="grow stack gap-xs" style={{ minWidth: 0 }}>
                <span className={styles.eyebrowRow}>
                  <span className="t-eyebrow">{head.label}</span>
                  {head.isBalance ? (
                    <IconButton
                      icon={balancesHidden ? 'eye' : 'eyeOff'}
                      label={balancesHidden ? 'Show balance' : 'Hide balance'}
                      small
                      color="var(--muted)"
                      iconSize={16}
                      onClick={toggleBalancesHidden}
                    />
                  ) : null}
                </span>
                <Money
                  amount={head.amount}
                  currency={currency}
                  signed={head.signed}
                  tone={head.signed ? 'auto' : head.amount < 0 ? 'negative' : 'neutral'}
                  obscured={head.isBalance && balancesHidden}
                  className={styles.net}
                  animate
                />
                {head.caption ? <span className="t-label-sm">{head.caption}</span> : null}
              </div>
              <IconWell icon={head.icon} tone={head.tone} size={46} />
            </div>
            <div className={styles.stats}>
              <div className={styles.statTile} style={{ '--tone': 'var(--income)' } as CSSProperties}>
                <StatTile
                  label={inProgress ? 'Income received' : 'Income'}
                  amount={data.totalIncome}
                  currency={currency}
                  icon="moneyIn"
                  tone="var(--income)"
                  coloured
                />
              </div>
              {head.isBalance || !inProgress ? (
                <div className={styles.statTile} style={{ '--tone': 'var(--expense)' } as CSSProperties}>
                  <StatTile
                    label={inProgress ? 'Spent this month' : 'Expenses'}
                    amount={data.totalExpense}
                    currency={currency}
                    icon="moneyOut"
                    tone="var(--expense)"
                    coloured
                  />
                </div>
              ) : null}
            </div>
          </Card>

          <Card className={`${styles.cell} ${styles.trend}`}>
            <CardHeader
              title="Income vs expenses"
              caption={inProgress ? `${data.trend.length} months · ${shortMonth(shownMonth)} so far` : `${data.trend.length} months`}
            />
            <MonthlyTrendChart points={data.trend} currency={currency} showIncome height="fill" />
            <ChartLegend
              entries={[
                { label: 'Expenses', color: 'var(--chart-expense)' },
                { label: 'Income', color: 'var(--chart-income)' },
              ]}
            />
          </Card>

          {hasBreakdown ? (
            <Card className={`${styles.cell} ${styles.spend}`}>
              <CardHeader title="Spending by category" caption={spendCaption(count, data.totalExpense, currency)} />
              <div className={styles.spendBody}>
                <div className={styles.donut}>
                  <CategoryDonut breakdown={data.breakdown} currency={currency} size={DONUT_SIZE} />
                </div>
                <div className={styles.breakdown}>
                  <CategoryBreakdownList breakdown={data.breakdown} currency={currency} limit={showAll ? undefined : LIST_LIMIT} />
                  {folded ? (
                    <Button
                      label={showAll ? 'Show fewer' : `Show all ${data.breakdown.length} categories`}
                      variant="ghost"
                      size="sm"
                      onClick={() => setShowAll((v) => !v)}
                    />
                  ) : null}
                </div>
              </div>
            </Card>
          ) : null}

          {top ? (
            <Card padding="flush" className={`${styles.cell} ${styles.top}`}>
              <ListRow
                leading={<IconWell icon="trophy" tone={topTone} size={38} />}
                title={top.name}
                subtitle={`Biggest category · ${formatPercent(topShare)} of spending`}
                trailing={<Money amount={top.total} currency={currency} compact className={styles.topAmount} />}
              />
            </Card>
          ) : null}
        </div>
      </div>
    );
  }

  return (
    <Page
      title="Reports"
      actions={
        <IconButton icon="export" label="Export report" glass onClick={() => void navigate(`/export?type=spendingReport&month=${month}`)} />
      }
      below={<MonthStepper month={month} onPrevious={() => changeMonth(-1)} onNext={canGoForward ? () => changeMonth(1) : null} />}
    >
      {body}
    </Page>
  );
}

/** The number of expenses and what one cost on average — the average is per expense, not per month. */
function spendCaption(count: number, total: number, currency: string): string {
  const expenses = `${count} ${count === 1 ? 'expense' : 'expenses'}`;
  if (count < 2) return expenses;
  return `${expenses} · avg ${formatCurrency(averagePerExpense(total, count), currency, { compact: true })} each`;
}

type MonthHead = {
  label: string;
  amount: number;
  /** A net result carries its sign; a balance or a total does not. */
  signed: boolean;
  isBalance: boolean;
  caption: string | null;
  icon: IconName;
  tone: string;
};

/**
 * How the summary card presents the month's standing. A running month is
 * never called overspent: its salary may simply not have arrived.
 */
function monthHead(standing: MonthStanding, accountCount: number, month: string): MonthHead {
  switch (standing.kind) {
    case 'balance':
      return {
        label: 'Available balance',
        amount: standing.available,
        signed: false,
        isBalance: true,
        caption: `Across ${accountCount} ${accountCount === 1 ? 'account' : 'accounts'} today · credit cards not included`,
        icon: 'bankSolid',
        tone: 'var(--primary)',
      };
    case 'spent':
      return {
        label: 'Spent this month',
        amount: standing.spent,
        signed: false,
        isBalance: false,
        caption: `${monthYear(month)} so far`,
        icon: 'moneyOut',
        tone: 'var(--primary)',
      };
    case 'net':
      return {
        label: `${standing.saved ? 'Saved' : 'Overspent'} in ${monthYear(month)}`,
        amount: standing.net,
        signed: standing.net !== 0,
        isBalance: false,
        caption: null,
        icon: standing.saved ? 'income' : 'warning',
        tone: standing.saved ? 'var(--income)' : 'var(--expense)',
      };
  }
}
