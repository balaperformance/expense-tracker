import { useMemo, useState, type ReactNode } from 'react';
import { useNavigate, useParams } from 'react-router';

import { Page } from '@/components/layout/Page';
import { CardAvatar, CardMovementAvatar, CategoryAvatar } from '@/components/finance/Avatars';
import { Money } from '@/components/finance/Money';
import { MonthStepper, StatTile } from '@/components/finance/Stats';
import { DayHeader, TransactionRow } from '@/components/finance/TransactionRow';
import { Button, IconButton } from '@/components/ui/Button';
import { Segmented } from '@/components/ui/Chip';
import { Centered, EmptyState, ErrorView, ListSkeleton, Notice } from '@/components/ui/Feedback';
import { Sheet } from '@/components/ui/Sheet';
import { Card, CardHeader, CardList, Hero, IconWell, ListRow } from '@/components/ui/Surface';
import {
  buildCardStatement,
  CARD_KIND_LABELS,
  CARD_STATEMENT_FILTERS,
  cardCycleContaining,
  cardEntryTitle,
  outstandingDelta,
  summariseCard,
  type CardEntry,
  type CardStatementFilter,
  type CardStatementRow,
} from '@/domain/creditCards';
import { groupByDay } from '@/domain/expenseFilter';
import { accountLabel, cardIssuerLine, type BankAccount } from '@/domain/models';
import { useAccounts, useCapabilities, useCardEntries, useCreditCards } from '@/hooks/data';
import { useDeleteCardEntry, useLinkToCard } from '@/hooks/mutations';
import { useSheet } from '@/hooks/useSheet';
import { addDays, today } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { dayMonth, dayMonthYear, formatCurrency, relativeDay } from '@/lib/format';
import { useFeedback } from '@/state/feedback';
import { useSettings } from '@/state/settings';

import { DueLine, UtilisationTrack } from './CardParts';
import { CardFormSheet, CardPaymentSheet, CardTransactionSheet, PurchaseActions } from './CardSheets';
import styles from './CreditCards.module.css';

type SheetState =
  | { kind: 'edit' }
  | { kind: 'pay' }
  | { kind: 'transaction'; refundOf: CardEntry | null }
  | { kind: 'purchase'; entry: CardEntry }
  | { kind: 'payment'; entry: CardEntry };

/** `/cards/:id` — one card's figures, latest bill and statement by billing cycle. */
export function CardStatementPage() {
  const { id = '' } = useParams();
  const navigate = useNavigate();
  const { currency } = useSettings();
  const { toast, confirm } = useFeedback();
  const caps = useCapabilities();
  const cards = useCreditCards();
  const accounts = (useAccounts().data ?? []).map((b) => b.account);
  const overview = cards.data?.find((o) => o.card.id === id);
  // Only read a history for a card that exists in this user's list.
  const history = useCardEntries(id, overview != null);
  const card = overview?.card;
  const [anchor, setAnchor] = useState(today());
  const [wholeHistory, setWholeHistory] = useState(false);
  const [filter, setFilter] = useState<CardStatementFilter>('all');
  const sheet = useSheet<SheetState>();
  const remove = useDeleteCardEntry();
  const link = useLinkToCard();

  const day = today();
  const entries = useMemo(() => history.data ?? [], [history.data]);
  // This card's own history is the freshest read; the list figure is the fallback while it loads.
  const summary = useMemo(() => (card && history.data ? summariseCard(card, entries, day) : overview?.summary), [card, history.data, entries, day, overview]);
  const cycle = useMemo(() => (card ? cardCycleContaining(card, anchor) : null), [card, anchor]);
  const statement = useMemo(
    () =>
      card && cycle
        ? buildCardStatement({
            openingOutstanding: card.openingOutstanding,
            entries,
            from: wholeHistory ? null : cycle.start,
            to: wholeHistory ? null : cycle.end,
            filter,
          })
        : null,
    [card, cycle, entries, wholeHistory, filter],
  );
  const groups = useMemo(
    () => groupByDay(statement?.rows ?? [], (r) => r.entry.date, (r) => -outstandingDelta(r.entry)),
    [statement],
  );
  const purchases = useMemo(
    () => entries.filter((e) => e.kind === 'purchase').sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : 0)),
    [entries],
  );

  if (!caps.creditCards) {
    return (
      <Page title="Card" back="/cards">
        <Centered>
          <EmptyState
            icon="database"
            title="Credit cards are not set up yet"
            message="Run ui/supabase/004_credit_cards.sql in the Supabase SQL editor, then open Credit cards again."
            actionLabel="Credit cards"
            onAction={() => void navigate('/cards')}
          />
        </Centered>
      </Page>
    );
  }
  if (cards.isPending) {
    return (
      <Page title="Card" back="/cards">
        <ListSkeleton rows={5} />
      </Page>
    );
  }
  // A failed read is not "deleted": offer a retry instead of a wrong message.
  if (cards.isError && !card) {
    return (
      <Page title="Card" back="/cards">
        <Centered>
          <ErrorView message={errorMessage(cards.error)} onRetry={() => void cards.refetch()} />
        </Centered>
      </Page>
    );
  }
  if (!card || !cycle || !summary) {
    return (
      <Page title="Card" back="/cards">
        <Centered>
          <EmptyState icon="card" title="Card not found" message="It may have been deleted." actionLabel="All cards" onAction={() => void navigate('/cards')} />
        </Centered>
      </Page>
    );
  }

  const currentCycle = summary.currentCycle;
  const isOpenCycle = !wholeHistory && cycle.end >= currentCycle.end;
  const accountName = (accountId: string | null) => accounts.find((a) => a.id === accountId)?.nickname ?? null;
  const bill = summary.lastStatement;
  const credit = summary.outstanding < 0;
  const paymentEntry = sheet.data?.kind === 'payment' ? sheet.data.entry : null;
  const paymentAccount = paymentEntry ? (accounts.find((a) => a.id === paymentEntry.accountId) ?? null) : null;

  const confirmDelete = async (entry: CardEntry) => {
    const amountText = formatCurrency(entry.amount, currency);
    const fromAccount = entry.source === 'account' ? (accountName(entry.accountId) ?? 'its account') : null;
    const ok = await confirm({
      title: entry.kind === 'payment' ? 'Delete payment?' : `Delete ${CARD_KIND_LABELS[entry.kind].toLowerCase()}?`,
      message: fromAccount
        ? `The ${amountText} payment on ${dayMonthYear(entry.date)} is one record: deleting it removes it from this card and from ${fromAccount}, and both are recalculated. To keep the debit on ${fromAccount}, unlink it instead.`
        : `${CARD_KIND_LABELS[entry.kind]} of ${amountText} on ${dayMonthYear(entry.date)}. The outstanding will be recalculated.`,
    });
    if (!ok) return;
    try {
      await remove.mutateAsync(entry);
      toast('success', 'Deleted');
    } catch (error) {
      toast('error', errorMessage(error, 'Could not delete the transaction.'));
    }
  };

  const unlink = async (entry: CardEntry) => {
    sheet.close();
    try {
      await link.mutateAsync({ entryId: entry.id, cardId: null });
      toast('success', 'Unlinked — the debit stays on the account');
    } catch (error) {
      toast('error', errorMessage(error, 'Could not unlink the payment.'));
    }
  };

  const onLongPress = (entry: CardEntry) => {
    if (entry.source === 'expense') sheet.open({ kind: 'purchase', entry });
    else if (entry.source === 'account') sheet.open({ kind: 'payment', entry });
    else void confirmDelete(entry);
  };

  const addPurchase = () => void navigate('/expenses/new', { state: { creditCardId: card.id } });
  const periodLabel = wholeHistory ? 'All transactions' : `${dayMonth(cycle.start)} – ${dayMonth(cycle.end)}`;

  return (
    <Page
      title={
        <span className={styles.statementTitle}>
          <CardAvatar size={32} />
          <span className="stack" style={{ minWidth: 0 }}>
            <span className="t-title-md t-ellipsis">{card.cardName}</span>
            <span className="t-label-sm t-ellipsis">{cardIssuerLine(card)}</span>
          </span>
        </span>
      }
      titleClassName=""
      documentTitle={`${card.cardName} statement`}
      back="/cards"
      actions={
        <>
          {card.isActive ? <IconButton icon="add" label="Add purchase" onClick={addPurchase} /> : null}
          <IconButton icon="edit" label="Edit card" onClick={() => sheet.open({ kind: 'edit' })} />
        </>
      }
      below={
        wholeHistory ? (
          <div className={styles.periodBar}>
            <span className="grow t-title-md">All transactions</span>
            <Button label="By cycle" variant="ghost" size="sm" onClick={() => setWholeHistory(false)} />
          </div>
        ) : (
          <MonthStepper
            month={cycle.start}
            label={periodLabel}
            onPrevious={() => setAnchor(addDays(cycle.start, -1))}
            onNext={isOpenCycle ? null : () => setAnchor(addDays(cycle.end, 1))}
            trailing={<Button label="All" variant="ghost" size="sm" onClick={() => setWholeHistory(true)} />}
          />
        )
      }
    >
      <Hero>
        <div className={styles.totalRow}>
          <div className="grow stack gap-xs">
            <span className="t-eyebrow" style={{ color: 'var(--hero-accent)' }}>
              {credit ? 'Credit balance' : 'Outstanding'}
            </span>
            <Money amount={credit ? -summary.outstanding : summary.outstanding} currency={currency} className={styles.total} animate />
            <span className="t-body-sm">
              {summary.unbilled > 0
                ? `${formatCurrency(summary.unbilled, currency)} spent since the last statement`
                : `Next statement ${dayMonthYear(currentCycle.end)}`}
            </span>
          </div>
          <IconWell icon="cardSolid" tone="var(--hero-accent)" size={44} />
        </div>
        {card.creditLimit > 0 ? (
          <div className={styles.heroFoot}>
            <UtilisationTrack ratio={summary.utilisation} />
            <div className={styles.heroLegs}>
              <span className={styles.heroLeg}>
                <span className="t-label-sm">{summary.overLimit > 0 ? 'Over the limit' : 'Available credit'}</span>
                <Money amount={summary.overLimit > 0 ? summary.overLimit : summary.available} currency={currency} className={styles.heroLegValue} />
              </span>
              <span className={styles.heroLeg}>
                <span className="t-label-sm">Credit limit</span>
                <Money amount={card.creditLimit} currency={currency} className={styles.heroLegValue} />
              </span>
            </div>
          </div>
        ) : null}
      </Hero>

      <div className={styles.actionsRow}>
        <Button label="Pay bill" icon="transfer" onClick={() => sheet.open({ kind: 'pay' })} />
        {card.isActive ? <Button label="Add purchase" icon="expense" variant="tonal" onClick={addPurchase} /> : null}
        <Button label="Refund, fee…" icon="add" variant="tonal" onClick={() => sheet.open({ kind: 'transaction', refundOf: null })} />
      </div>
      {!card.isActive ? <Notice icon="info" message="This card is inactive: it keeps its history and can be paid off, but is not offered for new purchases." /> : null}

      <Card>
        <CardHeader title="Latest bill" caption={`Statement ${dayMonth(bill.cycle.end)}`} />
        <div className="stack gap-md">
          <div className={styles.facts}>
            <Fact label="Statement balance" value={<Money amount={Math.max(bill.balance, 0)} currency={currency} />} />
            <Fact label="Due date" value={dayMonthYear(bill.cycle.dueDate)} />
            <Fact label="Paid & credited since" value={<Money amount={bill.credited} currency={currency} />} />
            <Fact label="Still to pay" value={<Money amount={bill.remaining} currency={currency} tone={bill.status === 'overdue' ? 'negative' : 'neutral'} />} />
          </div>
          <DueLine summary={summary} currency={currency} />
          <p className="t-label-sm">
            Cycle {dayMonth(currentCycle.start)} – {dayMonth(currentCycle.end)} is open: {formatCurrency(summary.unbilled, currency)} charged so far,
            billed on {dayMonthYear(currentCycle.end)} and due {dayMonthYear(currentCycle.dueDate)}.
          </p>
        </div>
      </Card>

      {history.isPending ? (
        <ListSkeleton rows={5} />
      ) : history.isError || !statement ? (
        <Centered>
          <ErrorView message={errorMessage(history.error)} onRetry={() => void history.refetch()} />
        </Centered>
      ) : (
        <div className="stack gap-section">
          <Card>
            <div className={styles.summaryLine}>
              <span className="t-body-sm">{wholeHistory ? 'Opening outstanding' : `Outstanding on ${dayMonth(addDays(cycle.start, -1))}`}</span>
              <Money amount={statement.opening} currency={currency} className="t-title-sm" />
            </div>
            <div className={styles.divider} />
            <div className={styles.facts}>
              <StatTile label="Purchases" amount={statement.purchases} currency={currency} icon="moneyOut" tone="var(--expense)" coloured />
              <StatTile label="Fees & interest" amount={statement.charges} currency={currency} icon="moneyOut" tone="var(--warning)" coloured />
              <StatTile label="Payments" amount={statement.payments} currency={currency} icon="transfer" tone="var(--transfer)" coloured />
              <StatTile label="Refunds & credits" amount={statement.credits} currency={currency} icon="moneyIn" tone="var(--income)" coloured />
            </div>
            <div className={styles.divider} />
            <div className="row gap-sm">
              <div className="grow stack gap-xs">
                <span className="t-label-md">{wholeHistory || isOpenCycle ? 'Outstanding now' : `Outstanding on ${dayMonth(cycle.end)}`}</span>
                <span className="t-label-sm">
                  {statement.rows.length} {statement.rows.length === 1 ? 'transaction' : 'transactions'}
                </span>
              </div>
              <Money amount={statement.closing} currency={currency} tone={statement.closing < 0 ? 'positive' : 'neutral'} className={styles.closing} />
            </div>
          </Card>

          <Segmented label="Show" value={filter} options={CARD_STATEMENT_FILTERS} onChange={setFilter} />

          {!statement.rows.length ? (
            <EmptyState
              compact
              icon="card"
              title="No transactions"
              message={filter === 'all' ? `Nothing recorded for ${wholeHistory ? 'this card' : periodLabel}.` : 'None of this type in this period.'}
              actionLabel={card.isActive ? 'Add purchase' : undefined}
              onAction={card.isActive ? addPurchase : undefined}
            />
          ) : (
            <div>
              {groups.map((group, i) => (
                <section key={group.day}>
                  <DayHeader label={relativeDay(group.day)} total={group.total} currency={currency} tone="auto" first={i === 0} />
                  <CardList>
                    {group.items.map((row) => (
                      <CardStatementLine
                        key={row.entry.key}
                        row={row}
                        currency={currency}
                        accountName={accountName(row.entry.accountId)}
                        onOpen={row.entry.source === 'expense' ? () => void navigate(`/expenses/${row.entry.id}`) : undefined}
                        onLongPress={() => onLongPress(row.entry)}
                      />
                    ))}
                  </CardList>
                </section>
              ))}
              <p className="t-label-sm t-center" style={{ paddingTop: 'var(--sp-lg)' }}>
                Outstanding is calculated oldest first from the opening outstanding. Tap a purchase to edit it; long-press (or right-click) any line for
                more.
              </p>
            </div>
          )}
        </div>
      )}

      {sheet.data?.kind === 'edit' ? <CardFormSheet key={sheet.key} open={sheet.isOpen} card={card} onClose={sheet.close} /> : null}
      {sheet.data?.kind === 'pay' ? <CardPaymentSheet key={sheet.key} open={sheet.isOpen} card={card} summary={summary} onClose={sheet.close} /> : null}
      {sheet.data?.kind === 'transaction' ? (
        <CardTransactionSheet key={sheet.key} open={sheet.isOpen} card={card} purchases={purchases} refundOf={sheet.data.refundOf} onClose={sheet.close} />
      ) : null}
      {sheet.data?.kind === 'purchase' ? (
        <Sheet key={sheet.key} open={sheet.isOpen} onClose={sheet.close} title="Purchase" subtitle={dayMonthYear(sheet.data.entry.date)}>
          <PurchaseActions
            entry={sheet.data.entry}
            onOpen={() => {
              const entry = sheet.data?.kind === 'purchase' ? sheet.data.entry : null;
              sheet.close();
              if (entry) void navigate(`/expenses/${entry.id}`);
            }}
            onRefund={() => {
              if (sheet.data?.kind === 'purchase') sheet.open({ kind: 'transaction', refundOf: sheet.data.entry });
            }}
          />
        </Sheet>
      ) : null}
      {sheet.data?.kind === 'payment' ? (
        <PaymentActionsSheet
          key={sheet.key}
          open={sheet.isOpen}
          entry={sheet.data.entry}
          account={paymentAccount}
          onClose={sheet.close}
          onOpenAccount={(accountId) => {
            sheet.close();
            void navigate(`/accounts/${accountId}`);
          }}
          onUnlink={(entry) => void unlink(entry)}
          onDelete={(entry) => {
            sheet.close();
            void confirmDelete(entry);
          }}
        />
      ) : null}
    </Page>
  );
}

function Fact({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div className={styles.fact}>
      <span className="t-label-sm">{label}</span>
      <span className={styles.factValue}>{value}</span>
    </div>
  );
}

function CardStatementLine({
  row,
  currency,
  accountName,
  onOpen,
  onLongPress,
}: {
  row: CardStatementRow;
  currency: string;
  accountName: string | null;
  onOpen?: () => void;
  onLongPress: () => void;
}) {
  const { entry } = row;
  const leading =
    entry.kind === 'purchase' ? (
      <CategoryAvatar icon={entry.category?.icon} color={entry.category?.color} />
    ) : (
      <CardMovementAvatar kind={entry.kind} fromAccount={entry.source === 'account'} />
    );
  const tone = entry.kind === 'payment' ? 'transfer' : entry.direction === 'debit' ? 'negative' : 'positive';
  const source = entry.kind === 'payment' ? (entry.source === 'account' ? (accountName ? `from ${accountName}` : 'from a bank account') : 'in cash') : null;
  return (
    <TransactionRow
      leading={leading}
      title={cardEntryTitle(entry)}
      titleLines={2}
      amount={-outstandingDelta(entry)}
      currency={currency}
      tone={tone}
      meta={[entry.kind === 'purchase' ? (entry.category?.name ?? 'Purchase') : CARD_KIND_LABELS[entry.kind], source]}
      trailingBelow={`Owed ${formatCurrency(row.outstandingAfter, currency, { compact: true })}`}
      onClick={onOpen}
      onLongPress={onLongPress}
    />
  );
}

function PaymentActionsSheet({
  open,
  entry,
  account,
  onClose,
  onOpenAccount,
  onUnlink,
  onDelete,
}: {
  open: boolean;
  entry: CardEntry;
  account: BankAccount | null;
  onClose: () => void;
  onOpenAccount: (accountId: string) => void;
  onUnlink: (entry: CardEntry) => void;
  onDelete: (entry: CardEntry) => void;
}) {
  const { currency } = useSettings();
  return (
    <Sheet open={open} onClose={onClose} title={`Payment · ${formatCurrency(entry.amount, currency)}`} subtitle={dayMonthYear(entry.date)}>
      <CardList indent={12}>
        {account ? (
          <ListRow dense title={`Open ${accountLabel(account)}`} subtitle="The account this payment came from" chevron onClick={() => onOpenAccount(account.id)} />
        ) : null}
        <ListRow
          dense
          title="Unlink from this card"
          subtitle="Keeps the debit on the account; the card no longer counts it as paid"
          onClick={() => onUnlink(entry)}
        />
        <ListRow dense title="Delete payment" subtitle="Removes it from the card and the account" tone="var(--error)" onClick={() => onDelete(entry)} />
      </CardList>
    </Sheet>
  );
}
