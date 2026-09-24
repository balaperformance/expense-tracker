import { useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router';

import { Page } from '@/components/layout/Page';
import { BankAvatar, CategoryAvatar, LedgerAvatar, TransferAvatar } from '@/components/finance/Avatars';
import { Money } from '@/components/finance/Money';
import { MonthStepper, StatTile } from '@/components/finance/Stats';
import { DayHeader, TransactionRow } from '@/components/finance/TransactionRow';
import { Button, IconButton } from '@/components/ui/Button';
import { Segmented } from '@/components/ui/Chip';
import { Centered, EmptyState, ErrorView, ListSkeleton } from '@/components/ui/Feedback';
import { Card, CardList } from '@/components/ui/Surface';
import { groupByDay } from '@/domain/expenseFilter';
import {
  accountBankLine,
  accountInitial,
  isDocumentBacked,
  isTransfer,
  ledgerCategoryLabel,
  ledgerTitle,
  signedAmount,
  type LedgerEntry,
} from '@/domain/models';
import { closingBalance, STATEMENT_FILTERS, type StatementRow, type StatementTypeFilter } from '@/domain/statement';
import { useAccounts, useCapabilities, useStatement } from '@/hooks/data';
import { useSheet } from '@/hooks/useSheet';
import { useDeleteLedgerEntry } from '@/hooks/mutations';
import { addMonths, firstOfMonth, today } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { dayMonthYear, formatCurrency, monthYear, relativeDay } from '@/lib/format';
import { useFeedback } from '@/state/feedback';
import { useSettings } from '@/state/settings';

import { MovementSheet, TransferSheet } from './AccountSheets';
import styles from './Accounts.module.css';

export function StatementPage() {
  const { id = '' } = useParams();
  const navigate = useNavigate();
  const { currency } = useSettings();
  const { toast, confirm } = useFeedback();
  const caps = useCapabilities();
  const accounts = useAccounts();
  const balances = accounts.data ?? [];
  const account = balances.find((b) => b.account.id === id)?.account;
  const [month, setMonth] = useState(firstOfMonth(today()));
  const [wholeHistory, setWholeHistory] = useState(false);
  const [typeFilter, setTypeFilter] = useState<StatementTypeFilter>('all');
  const sheet = useSheet<'movement' | 'transfer'>();
  const remove = useDeleteLedgerEntry();

  const statement = useStatement({
    accountId: id,
    openingBalance: account?.openingBalance ?? 0,
    month,
    wholeHistory,
    typeFilter,
  });
  const groups = useMemo(
    () => groupByDay(statement.data?.rows ?? [], (r) => r.entry.txnDate, (r) => signedAmount(r.entry)),
    [statement.data],
  );
  const canTransfer = caps.transfers && balances.length >= 2;
  const canGoForward = !wholeHistory && month < firstOfMonth(today());
  const periodLabel = wholeHistory ? 'All transactions' : monthYear(month);

  if (accounts.isPending) {
    return (
      <Page title="Statement" back="/accounts">
        <ListSkeleton rows={5} />
      </Page>
    );
  }
  if (!account) {
    return (
      <Page title="Statement" back="/accounts">
        <Centered>
          <EmptyState icon="bank" title="Account not found" message="It may have been deleted." actionLabel="All accounts" onAction={() => void navigate('/accounts')} />
        </Centered>
      </Page>
    );
  }

  const confirmDelete = async (entry: LedgerEntry) => {
    if (isDocumentBacked(entry)) {
      toast('info', `This came from ${entry.expenseId ? 'an expense' : 'an income'} entry. Delete it there instead.`);
      return;
    }
    const amountText = formatCurrency(entry.amount, currency);
    const debit = entry.direction === 'debit';
    const ok = await confirm({
      title: isTransfer(entry) ? 'Delete transfer?' : 'Delete transaction?',
      message: isTransfer(entry)
        ? `This removes both sides of the ${amountText} transfer on ${dayMonthYear(entry.txnDate)} — the ${debit ? 'debit' : 'credit'} here and the matching ${debit ? 'credit' : 'debit'} on the other account. Both balances will be recalculated.`
        : `${debit ? 'Debit' : 'Credit'} of ${amountText} on ${dayMonthYear(entry.txnDate)}. The balance will be recalculated.`,
    });
    if (!ok) return;
    try {
      await remove.mutateAsync({ id: entry.id, transferGroupId: entry.transferGroupId });
      toast('success', isTransfer(entry) ? 'Transfer deleted' : 'Transaction deleted');
    } catch (error) {
      toast('error', errorMessage(error, 'Could not delete the transaction.'));
    }
  };

  const exportUrl = `/export?type=bankStatement&account=${account.id}${wholeHistory ? '' : `&month=${month}`}`;
  const data = statement.data;

  return (
    <Page
      title={
        <span className={styles.statementTitle}>
          <BankAvatar initial={accountInitial(account)} size={32} />
          <span className="stack" style={{ minWidth: 0 }}>
            <span className="t-title-md t-ellipsis">{account.nickname}</span>
            <span className="t-label-sm t-ellipsis">{accountBankLine(account)}</span>
          </span>
        </span>
      }
      titleClassName=""
      documentTitle={`${account.nickname} statement`}
      back="/accounts"
      actions={
        <>
          <IconButton icon="export" label="Export statement" onClick={() => void navigate(exportUrl)} />
          {canTransfer ? <IconButton icon="transfer" label="Transfer" onClick={() => sheet.open('transfer')} /> : null}
          <IconButton icon="add" label="Add money" onClick={() => sheet.open('movement')} />
        </>
      }
      below={
        wholeHistory ? (
          <div className={styles.periodBar}>
            <span className="grow t-title-md">All transactions</span>
            <Button label="By month" variant="ghost" size="sm" onClick={() => setWholeHistory(false)} />
          </div>
        ) : (
          <MonthStepper
            month={month}
            onPrevious={() => setMonth((m) => addMonths(m, -1))}
            onNext={canGoForward ? () => setMonth((m) => addMonths(m, 1)) : null}
            trailing={<Button label="All" variant="ghost" size="sm" onClick={() => setWholeHistory(true)} />}
          />
        )
      }
    >
      {statement.isPending ? (
        <ListSkeleton rows={5} />
      ) : statement.isError || !data ? (
        <Centered>
          <ErrorView message={errorMessage(statement.error)} onRetry={() => void statement.refetch()} />
        </Centered>
      ) : (
        <div className="stack gap-section" style={{ opacity: statement.isPlaceholderData ? 0.6 : 1 }}>
          <Card>
            <div className={styles.summaryLine}>
              <span className="t-body-sm">Opening balance</span>
              <Money amount={data.openingBalance} currency={currency} className="t-title-sm" />
            </div>
            <div className={styles.divider} />
            <div className="row gap-sm">
              <div className="grow">
                <StatTile label="Credits" amount={data.totalCredits} currency={currency} icon="moneyIn" tone="var(--income)" coloured />
              </div>
              <div className="grow">
                <StatTile label="Debits" amount={data.totalDebits} currency={currency} icon="moneyOut" tone="var(--expense)" coloured />
              </div>
            </div>
            <div className={styles.divider} />
            <div className="row gap-sm">
              <div className="grow stack gap-xs">
                <span className="t-label-md">Closing balance</span>
                <span className="t-label-sm">
                  {data.rows.length} {data.rows.length === 1 ? 'transaction' : 'transactions'}
                </span>
              </div>
              <Money
                amount={closingBalance(data)}
                currency={currency}
                tone={closingBalance(data) < 0 ? 'negative' : 'neutral'}
                className={styles.closing}
              />
            </div>
          </Card>

          <Segmented label="Show" value={typeFilter} options={STATEMENT_FILTERS} onChange={setTypeFilter} />

          {!data.rows.length ? (
            <EmptyState
              compact
              icon="expenses"
              title="No transactions"
              message={
                typeFilter === 'all'
                  ? `Nothing recorded for ${periodLabel.toLowerCase()}.`
                  : `No ${typeFilter} in this period.`
              }
            />
          ) : (
            <div>
              {groups.map((group, i) => (
                <section key={group.day}>
                  <DayHeader label={relativeDay(group.day)} total={group.total} currency={currency} tone="auto" first={i === 0} />
                  <CardList>
                    {group.items.map((row) => (
                      <StatementLine
                        key={row.entry.id}
                        row={row}
                        currency={currency}
                        counterparty={balances.find((b) => b.account.id === row.entry.counterpartyAccountId)?.account.nickname ?? null}
                        onLongPress={() => void confirmDelete(row.entry)}
                      />
                    ))}
                  </CardList>
                </section>
              ))}
              <p className="t-label-sm t-center" style={{ paddingTop: 'var(--sp-lg)' }}>
                Balance is calculated from the ledger, oldest first. Long-press (or right-click) a manual entry to delete it.
              </p>
            </div>
          )}
        </div>
      )}
      {sheet.data === 'movement' ? <MovementSheet key={sheet.key} open={sheet.isOpen} account={account} onClose={sheet.close} /> : null}
      {sheet.data === 'transfer' ? (
        <TransferSheet key={sheet.key} open={sheet.isOpen} balances={balances} fromAccountId={account.id} onClose={sheet.close} />
      ) : null}
    </Page>
  );
}

function StatementLine({
  row,
  currency,
  counterparty,
  onLongPress,
}: {
  row: StatementRow;
  currency: string;
  counterparty: string | null;
  onLongPress: () => void;
}) {
  const { entry } = row;
  const title = ledgerTitle(entry);
  const namesCounterparty = counterparty != null && title.toLowerCase().includes(counterparty.toLowerCase());
  const leading = isTransfer(entry) ? (
    <TransferAvatar />
  ) : entry.category ? (
    <CategoryAvatar icon={entry.category.icon} color={entry.category.color} />
  ) : (
    <LedgerAvatar credit={entry.direction === 'credit'} />
  );
  return (
    <TransactionRow
      leading={leading}
      title={title}
      titleLines={2}
      amount={signedAmount(entry)}
      currency={currency}
      tone={isTransfer(entry) ? 'transfer' : entry.direction === 'credit' ? 'positive' : 'negative'}
      meta={[
        ledgerCategoryLabel(entry),
        isTransfer(entry) && counterparty && !namesCounterparty ? (entry.direction === 'debit' ? `to ${counterparty}` : `from ${counterparty}`) : null,
      ]}
      trailingBelow={formatCurrency(row.balanceAfter, currency, { compact: true })}
      onLongPress={onLongPress}
    />
  );
}
