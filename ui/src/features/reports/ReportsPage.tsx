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
import { shareOf, sumBy } from '@/domain/analytics';
import { useReport } from '@/hooks/data';
import { addMonths, firstOfMonth, today } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { formatPercent, monthYear } from '@/lib/format';
import { useSettings } from '@/state/settings';

import styles from './Reports.module.css';

/** Categories listed before the rest fold behind "Show all" — the same count the ring names. */
const LIST_LIMIT = 6;
const DONUT_SIZE = 156;

export function ReportsPage() {
  const navigate = useNavigate();
  const { currency } = useSettings();
  const [month, setMonth] = useState(firstOfMonth(today()));
  const [showAll, setShowAll] = useState(false);
  const report = useReport(month);
  const canGoForward = month < firstOfMonth(today());
  const data = report.data;
  const changeMonth = (delta: number) => {
    setMonth((m) => addMonths(m, delta));
    setShowAll(false);
  };

  let body;
  if (report.isPending) body = <ListSkeleton rows={5} />;
  else if (report.isError && !data) {
    body = (
      <Centered>
        <ErrorView message={errorMessage(report.error)} onRetry={() => void report.refetch()} />
      </Centered>
    );
  } else if (!data || (data.totalExpense === 0 && data.totalIncome === 0)) {
    body = (
      <Centered>
        <EmptyState icon="insights" title="Nothing to report" message={`No income or expenses recorded in ${monthYear(month)}.`} />
      </Centered>
    );
  } else {
    const net = data.totalIncome - data.totalExpense;
    const saved = net >= 0;
    const count = data.expenses.length;
    const top = data.breakdown[0];
    const hasBreakdown = data.breakdown.length > 0;
    const folded = data.breakdown.length > LIST_LIMIT;
    const tone = saved ? 'var(--income)' : 'var(--expense)';
    const topTone = segmentColor(0, data.breakdown.length);
    const topShare = top ? shareOf(top, sumBy(data.breakdown, (c) => c.total)) : 0;

    body = (
      <div className={styles.frame}>
        <div
          className={styles.grid}
          data-layout={hasBreakdown ? 'full' : 'summary'}
          style={{ opacity: report.isPlaceholderData ? 0.6 : 1 }}
        >
          <Card className={`${styles.cell} ${styles.saved}`} style={{ '--tone': tone } as CSSProperties}>
            <div className={styles.savedHead}>
              <div className="grow stack gap-xs" style={{ minWidth: 0 }}>
                <span className="t-eyebrow">{saved ? 'Saved this month' : 'Overspent this month'}</span>
                <Money amount={net} currency={currency} signed={net !== 0} tone="auto" className={styles.net} animate />
              </div>
              <IconWell icon={saved ? 'income' : 'warning'} tone={tone} size={46} />
            </div>
            <div className={styles.stats}>
              <div className={styles.statTile} style={{ '--tone': 'var(--income)' } as CSSProperties}>
                <StatTile label="Income" amount={data.totalIncome} currency={currency} icon="moneyIn" tone="var(--income)" coloured />
              </div>
              <div className={styles.statTile} style={{ '--tone': 'var(--expense)' } as CSSProperties}>
                <StatTile label="Expenses" amount={data.totalExpense} currency={currency} icon="moneyOut" tone="var(--expense)" coloured />
              </div>
              <div className={styles.statTile} style={{ '--tone': 'var(--primary)' } as CSSProperties}>
                <StatTile label="Avg spend" amount={count ? data.totalExpense / count : 0} currency={currency} icon="tag" tone="var(--primary)" />
              </div>
            </div>
          </Card>

          <Card className={`${styles.cell} ${styles.trend}`}>
            <CardHeader title="Income vs expenses" caption={`${data.trend.length} months`} />
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
              <CardHeader title="Spending by category" caption={`${count} ${count === 1 ? 'expense' : 'expenses'}`} />
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
