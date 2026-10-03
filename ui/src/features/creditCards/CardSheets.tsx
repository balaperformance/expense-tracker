import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';

import { Money } from '@/components/finance/Money';
import { Button, IconButton } from '@/components/ui/Button';
import { Chip, ChipGroup, Segmented } from '@/components/ui/Chip';
import { InlineError, Notice } from '@/components/ui/Feedback';
import { AmountField, DateField, FieldLabel, SelectField, TextArea, TextField } from '@/components/ui/Fields';
import { Icon } from '@/components/ui/Icon';
import { Sheet } from '@/components/ui/Sheet';
import { Card, CardList, ListRow } from '@/components/ui/Surface';
import {
  CARD_TRANSACTION_KINDS,
  cardCycleContaining,
  cardEntryTitle,
  directionForKind,
  findExpenseDebits,
  findLinkableDebits,
  type CardEntry,
  type CardSummary,
  type PaymentSource,
} from '@/domain/creditCards';
import {
  accountLabel,
  CARD_NETWORKS,
  CARD_PAYMENT_LABEL,
  cardLabel,
  currentBalance,
  ledgerTitle,
  type CardNetwork,
  type CardTransactionKind,
  type CreditCard,
  type LedgerDirection,
} from '@/domain/models';
import { useAccounts } from '@/hooks/data';
import { useCardPayment, useDeleteCard, useLinkToCard, useRecordCardTransaction, useSaveCard } from '@/hooks/mutations';
import { addDays, today } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { dayMonth, dayMonthYear, formatCurrency, ordinal } from '@/lib/format';
import { amountToInput, MAX_AMOUNT, parseAmount, sanitiseAmountInput, validateAmount, validateRequired } from '@/lib/validators';
import { cardActivity } from '@/services/creditCards';
import { fetchForAccount } from '@/services/ledger';
import { useUserId } from '@/state/auth';
import { useFeedback } from '@/state/feedback';
import { useSettings } from '@/state/settings';

import styles from './CreditCards.module.css';

const DAY_OPTIONS = Array.from({ length: 31 }, (_, i) => ({ value: String(i + 1), label: ordinal(i + 1) }));

// ---------------------------------------------------------------------------
// Add / edit card
// ---------------------------------------------------------------------------

type CardField = 'name' | 'issuer' | 'last4' | 'limit' | 'opening' | 'statementDay' | 'dueDay';

export function CardFormSheet({ open, card, onClose }: { open: boolean; card: CreditCard | null; onClose: () => void }) {
  const userId = useUserId();
  const { symbol } = useSettings();
  const { toast, confirm } = useFeedback();
  const accounts = (useAccounts().data ?? []).map((b) => b.account);
  const save = useSaveCard();
  const remove = useDeleteCard();
  const editing = card != null;

  const [cardName, setCardName] = useState(card?.cardName ?? '');
  const [issuer, setIssuer] = useState(card?.issuer ?? '');
  const [network, setNetwork] = useState<CardNetwork | null>(card?.network ?? null);
  const [last4, setLast4] = useState(card?.last4 ?? '');
  const [limit, setLimit] = useState(card ? amountToInput(card.creditLimit) : '');
  const [opening, setOpening] = useState(card && card.openingOutstanding !== 0 ? amountToInput(card.openingOutstanding) : '');
  const [statementDay, setStatementDay] = useState(card ? String(card.statementDay) : '');
  const [dueDay, setDueDay] = useState(card ? String(card.paymentDueDay) : '');
  const [paymentAccountId, setPaymentAccountId] = useState(card?.paymentAccountId ?? '');
  const [notes, setNotes] = useState(card?.notes ?? '');
  const [active, setActive] = useState(card?.isActive ?? true);
  const [errors, setErrors] = useState<Partial<Record<CardField, string | null>>>({});
  const [error, setError] = useState<string | null>(null);
  const busy = save.isPending || remove.isPending;

  const validateLimit = (value: string) => {
    if (!value.trim()) return 'Credit limit is required';
    const parsed = parseAmount(value);
    if (parsed == null) return 'Enter a valid number';
    if (parsed <= 0) return 'Enter the card’s credit limit';
    if (parsed > MAX_AMOUNT) return 'Amount is too large';
    return null;
  };
  const validateOpening = (value: string) => {
    if (!value.trim()) return null;
    const parsed = parseAmount(value);
    if (parsed == null) return 'Enter a valid number';
    if (Math.abs(parsed) > MAX_AMOUNT) return 'Amount is too large';
    return null;
  };

  // A preview of the cycle, so the two days are easy to check.
  const cycle =
    statementDay && dueDay ? cardCycleContaining({ statementDay: Number(statementDay), paymentDueDay: Number(dueDay) }, today()) : null;

  const submit = async () => {
    const next: Partial<Record<CardField, string | null>> = {
      name: validateRequired(cardName, 'Card name'),
      issuer: validateRequired(issuer, 'Bank or issuer'),
      last4: last4 && last4.length !== 4 ? 'Enter all 4 digits' : null,
      limit: validateLimit(limit),
      opening: validateOpening(opening),
      statementDay: statementDay ? null : 'Pick the statement day',
      dueDay: dueDay ? null : 'Pick the due day',
    };
    setErrors(next);
    if (Object.values(next).some(Boolean)) return;
    setError(null);
    try {
      await save.mutateAsync({
        id: card?.id,
        draft: {
          cardName,
          issuer,
          network,
          last4: last4 || null,
          creditLimit: parseAmount(limit) ?? 0,
          openingOutstanding: parseAmount(opening) ?? 0,
          statementDay: Number(statementDay),
          paymentDueDay: Number(dueDay),
          paymentAccountId: paymentAccountId || null,
          notes,
          isActive: active,
        },
      });
      toast('success', editing ? 'Card updated' : 'Card added');
      onClose();
    } catch (failure) {
      setError(errorMessage(failure, 'Could not save the card.'));
    }
  };

  const confirmDelete = async () => {
    if (!card) return;
    const activity = await cardActivity(userId, card.id).catch(() => null);
    const parts = activity == null ? ['Its purchases stay as expenses (recorded as Cash), its bill payments stay on their bank accounts as plain debits, and its other card transactions are deleted.'] : [
      activity.purchases
        ? `${activity.purchases} ${activity.purchases === 1 ? 'purchase stays as an expense' : 'purchases stay as expenses'} but ${activity.purchases === 1 ? 'is' : 'are'} recorded as Cash.`
        : null,
      activity.payments
        ? `${activity.payments} bill ${activity.payments === 1 ? 'payment stays' : 'payments stay'} on ${activity.payments === 1 ? 'its' : 'their'} bank account as a plain debit.`
        : null,
      activity.others ? `${activity.others} other card ${activity.others === 1 ? 'transaction is' : 'transactions are'} deleted.` : null,
    ].filter(Boolean);
    const ok = await confirm({
      title: `Delete "${card.cardName}"?`,
      message: `${parts.length ? parts.join(' ') : 'This card has no transactions.'} To keep its history, mark it inactive instead. This cannot be undone.`,
    });
    if (!ok) return;
    try {
      await remove.mutateAsync(card.id);
      toast('success', 'Card deleted');
      onClose();
    } catch (failure) {
      setError(errorMessage(failure, 'Could not delete the card.'));
    }
  };

  return (
    <Sheet
      open={open}
      onClose={onClose}
      busy={busy}
      title={editing ? 'Edit card' : 'New credit card'}
      subtitle={editing ? card.issuer : 'Track its outstanding, bills and statement'}
      action={editing ? <IconButton icon="delete" label="Delete card" color="var(--error)" disabled={busy} onClick={() => void confirmDelete()} /> : null}
      footer={<Button label={editing ? 'Save changes' : 'Add card'} size="lg" block busy={save.isPending} busyLabel="Saving…" onClick={() => void submit()} />}
    >
      <div>
        <FieldLabel text="Card name" required />
        <TextField value={cardName} onChange={setCardName} placeholder="Regalia, Millennia, Amazon Pay…" aria-label="Card name" icon="card" autoCapitalize="words" disabled={busy} error={errors.name} />
      </div>
      <div>
        <FieldLabel text="Bank or issuer" required />
        <TextField value={issuer} onChange={setIssuer} placeholder="HDFC Bank, SBI Card, ICICI Bank…" aria-label="Bank or issuer" icon="bank" autoCapitalize="words" disabled={busy} error={errors.issuer} />
      </div>
      <div>
        <FieldLabel text="Network" hint="Optional" />
        <ChipGroup label="Network">
          {CARD_NETWORKS.map((n) => (
            <Chip key={n.value} label={n.label} selected={network === n.value} disabled={busy} onClick={() => setNetwork(network === n.value ? null : n.value)} />
          ))}
        </ChipGroup>
      </div>
      <div>
        <FieldLabel text="Last 4 digits" hint="Optional" />
        <TextField
          value={last4}
          onChange={(v) => setLast4(v.replace(/\D/g, '').slice(0, 4))}
          placeholder="4821"
          aria-label="Last 4 digits"
          icon="tag"
          inputMode="numeric"
          maxLength={4}
          disabled={busy}
          error={errors.last4}
          helper="Lets a bank SMS for this card pick it automatically. Never enter the full card number."
        />
      </div>
      <div>
        <FieldLabel text="Credit limit" required />
        <TextField
          value={limit}
          onChange={(v) => setLimit(sanitiseAmountInput(v))}
          prefix={symbol}
          placeholder="0"
          aria-label="Credit limit"
          inputMode="decimal"
          disabled={busy}
          error={errors.limit}
        />
      </div>
      <div>
        <FieldLabel text="Opening outstanding" hint="Optional" />
        <TextField
          value={opening}
          onChange={(v) => setOpening(sanitiseAmountInput(v, true))}
          prefix={symbol}
          placeholder="0"
          aria-label="Opening outstanding"
          inputMode="decimal"
          disabled={busy}
          error={errors.opening}
          helper="What you owed on the card before the transactions you track here. Negative for a credit balance."
        />
      </div>
      <div>
        <FieldLabel text="Billing cycle" required />
        <div className={styles.twoUp}>
          <div className="stack gap-xs">
            <span className="t-label-sm">Statement day</span>
            <SelectField value={statementDay} onChange={setStatementDay} options={DAY_OPTIONS} label="Statement day" icon="calendar" placeholder="Day" disabled={busy} />
            {errors.statementDay ? <span className={styles.fieldError}>{errors.statementDay}</span> : null}
          </div>
          <div className="stack gap-xs">
            <span className="t-label-sm">Payment due day</span>
            <SelectField value={dueDay} onChange={setDueDay} options={DAY_OPTIONS} label="Payment due day" icon="calendar" placeholder="Day" disabled={busy} />
            {errors.dueDay ? <span className={styles.fieldError}>{errors.dueDay}</span> : null}
          </div>
        </div>
        <p className="t-label-sm" style={{ paddingTop: 'var(--sp-xs)' }}>
          {cycle
            ? `Next statement ${dayMonthYear(cycle.end)}, due ${dayMonthYear(cycle.dueDate)}.`
            : 'The day the statement is generated, and the day the bill is due after it.'}
        </p>
      </div>
      <div>
        <FieldLabel text="Usually paid from" hint="Optional" />
        <SelectField
          value={paymentAccountId}
          onChange={setPaymentAccountId}
          options={accounts.map((a) => ({ value: a.id, label: accountLabel(a) }))}
          label="Usually paid from"
          icon="bank"
          placeholder="No account set"
          disabled={busy || !accounts.length}
        />
        <p className="t-label-sm" style={{ paddingTop: 'var(--sp-xs)' }}>
          Pre-selected when you pay the bill. Purchases on the card never touch this account.
        </p>
      </div>
      <div>
        <FieldLabel text="Notes" hint="Optional" />
        <TextArea value={notes} onChange={setNotes} placeholder="Annual fee waiver, reward rules…" aria-label="Notes" icon="notes" disabled={busy} />
      </div>
      {editing ? (
        <div>
          <FieldLabel text="Status" />
          <Segmented
            label="Status"
            value={active ? 'active' : 'inactive'}
            onChange={(v) => setActive(v === 'active')}
            options={[
              { value: 'active', label: 'Active', icon: 'checkCircle' },
              { value: 'inactive', label: 'Inactive', icon: 'close' },
            ]}
            disabled={busy}
          />
          <p className="t-label-sm" style={{ paddingTop: 'var(--sp-xs)' }}>
            An inactive card keeps its statement and can still be paid off, but is not offered for new purchases.
          </p>
        </div>
      ) : null}
      {error ? <InlineError message={error} /> : null}
    </Sheet>
  );
}

// ---------------------------------------------------------------------------
// Pay the bill
// ---------------------------------------------------------------------------

const CASH = 'cash';

export function CardPaymentSheet({
  open,
  card,
  summary,
  onClose,
}: {
  open: boolean;
  card: CreditCard;
  summary: CardSummary;
  onClose: () => void;
}) {
  const userId = useUserId();
  const { symbol, currency } = useSettings();
  const { toast, confirm } = useFeedback();
  const balances = useAccounts().data ?? [];
  const pay = useCardPayment();
  const link = useLinkToCard();
  const due = summary.lastStatement.remaining;

  // Until the user picks, follow the accounts as they load — never fall back to cash just because they had not arrived yet.
  const defaultSource = balances.find((b) => b.account.id === card.paymentAccountId)?.account.id ?? balances[0]?.account.id ?? CASH;
  const [chosenSource, setSourceId] = useState<string | null>(null);
  const sourceId = chosenSource ?? defaultSource;
  const [amount, setAmount] = useState(due > 0 ? amountToInput(due) : '');
  const [date, setDate] = useState(today());
  const [note, setNote] = useState('');
  const [linkId, setLinkId] = useState<string | null>(null);
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const busy = pay.isPending || link.isPending;

  const typed = parseAmount(amount);
  const source = balances.find((b) => b.account.id === sourceId);
  const paymentSource: PaymentSource = source ? { kind: 'account', accountId: source.account.id } : { kind: 'cash' };

  // The payment may already be on the account — typed in, or imported from a
  // bank statement. Linking that debit avoids taking the money out twice.
  const lookup = typed != null && typed > 0 && source != null;
  const nearby = useQuery({
    queryKey: ['cardPaymentMatch', userId, sourceId, date],
    queryFn: () => fetchForAccount({ userId, accountId: sourceId, from: addDays(date, -4), toExclusive: addDays(date, 5) }),
    enabled: lookup,
    staleTime: 0,
  });
  const matches = lookup ? findLinkableDebits(nearby.data ?? [], typed, date) : [];
  const linked = matches.find((m) => m.id === linkId) ?? null;
  // A bill imported (or typed) as an expense cannot be linked: it would stay spending. Say so.
  const asExpense = lookup ? findExpenseDebits(nearby.data ?? [], typed, date) : [];
  const expenseHit = asExpense[0] ?? null;

  const submit = async () => {
    setSubmitted(true);
    setError(null);
    try {
      if (linked) {
        await link.mutateAsync({ entryId: linked.id, cardId: card.id });
        toast('success', 'Payment linked to the card');
      } else {
        if (validateAmount(amount)) return;
        if (lookup && nearby.isFetching) {
          setError('Still checking the account for this payment. Try again in a moment.');
          return;
        }
        if (matches.length || asExpense.length) {
          const ok = await confirm({
            title: 'Record a separate payment?',
            message: `${source?.account.nickname ?? 'The account'} already has a debit of ${formatCurrency(typed ?? 0, currency)} near ${dayMonthYear(date)}. Recording another takes the money out of the account twice. Only continue if you really paid twice.`,
            confirmLabel: 'Record anyway',
            destructive: false,
          });
          if (!ok) return;
        }
        await pay.mutateAsync({
          draft: { cardId: card.id, source: paymentSource, amount: typed, date, note },
          card,
          accounts: balances.map((b) => b.account),
          currency,
        });
        toast('success', 'Payment recorded');
      }
      onClose();
    } catch (failure) {
      setError(errorMessage(failure, 'Could not record the payment.'));
    }
  };

  const paid = linked ? linked.amount : typed != null && typed > 0 ? typed : null;
  const outstandingAfter = paid != null ? summary.outstanding - paid : null;
  const sourceAfter = source && paid != null && !linked ? currentBalance(source) - paid : null;
  const shortcuts = [
    due > 0 ? { label: `Bill due ${formatCurrency(due, currency)}`, value: due } : null,
    summary.outstanding > 0 && Math.round(summary.outstanding * 100) !== Math.round(due * 100)
      ? { label: `Full outstanding ${formatCurrency(summary.outstanding, currency)}`, value: summary.outstanding }
      : null,
  ].filter((s): s is { label: string; value: number } => s != null);

  return (
    <Sheet
      open={open}
      onClose={onClose}
      busy={busy}
      title="Pay card bill"
      subtitle={`${cardLabel(card)} · not counted as spending`}
      footer={
        <Button
          label={linked ? 'Link payment' : 'Record payment'}
          icon={linked ? 'check' : 'transfer'}
          size="lg"
          block
          busy={busy}
          busyLabel="Saving…"
          onClick={() => void submit()}
        />
      }
    >
      <AmountField
        value={amount}
        onChange={(v) => {
          setAmount(v);
          setLinkId(null);
        }}
        symbol={symbol}
        tone="var(--transfer)"
        disabled={busy}
        error={submitted && !linked ? validateAmount(amount) : null}
      />
      {shortcuts.length ? (
        <ChipGroup label="Amount shortcuts">
          {shortcuts.map((s) => (
            <Chip
              key={s.label}
              label={s.label}
              selected={typed != null && Math.round(typed * 100) === Math.round(s.value * 100)}
              disabled={busy}
              onClick={() => {
                setAmount(amountToInput(s.value));
                setLinkId(null);
              }}
            />
          ))}
        </ChipGroup>
      ) : null}

      <div>
        <FieldLabel text="Pay from" required />
        <SelectField
          value={sourceId}
          onChange={(v) => {
            setSourceId(v || CASH);
            setLinkId(null);
          }}
          options={[
            ...balances.map((b) => ({ value: b.account.id, label: `${accountLabel(b.account)} · ${formatCurrency(currentBalance(b), currency)}` })),
            { value: CASH, label: 'Cash — no account balance changes' },
          ]}
          label="Pay from"
          icon={source ? 'bank' : 'cash'}
          disabled={busy}
        />
      </div>

      {matches.length ? (
        <div className="stack gap-sm">
          <Notice
            icon="copy"
            tone="var(--warning)"
            message={`${source ? source.account.nickname : 'This account'} already has ${matches.length === 1 ? 'a debit' : 'debits'} of this amount nearby. If ${matches.length === 1 ? 'it is' : 'one is'} this payment, link it instead of recording it again.`}
          />
          <CardList indent={12}>
            {matches.map((m) => (
              <ListRow
                key={m.id}
                dense
                title={ledgerTitle(m)}
                subtitle={`${dayMonthYear(m.txnDate)} · ${formatCurrency(m.amount, currency)}`}
                trailing={<Icon name={linkId === m.id ? 'checkCircle' : 'add'} size={20} color={linkId === m.id ? 'var(--primary)' : 'var(--muted)'} />}
                onClick={() => setLinkId(linkId === m.id ? null : m.id)}
                ariaLabel={linkId === m.id ? 'Record a new payment instead' : 'Use this debit as the payment'}
              />
            ))}
          </CardList>
        </div>
      ) : null}

      {expenseHit && !linked ? (
        <Notice
          icon="warning"
          tone="var(--expense)"
          message={`${source?.account.nickname ?? 'This account'} has an expense of this amount on ${dayMonthYear(expenseHit.txnDate)} (“${ledgerTitle(expenseHit)}”). If that was this bill, delete that expense first — otherwise the bill counts as spending on top of the card purchases.`}
        />
      ) : null}

      {!linked ? (
        <>
          <div>
            <FieldLabel text="Date" required />
            <DateField value={date} onChange={setDate} disabled={busy} />
          </div>
          <div>
            <FieldLabel text="Note" hint="Optional" />
            <TextField value={note} onChange={setNote} placeholder={`${cardLabel(card)} bill payment`} aria-label="Note" icon="text" disabled={busy} />
          </div>
        </>
      ) : (
        <Notice icon="info" message={`No new debit is added: the ${dayMonth(linked.txnDate)} debit becomes this card's payment.`} />
      )}

      {outstandingAfter != null ? (
        <div className={styles.preview}>
          <span className="t-label-sm t-center">After this payment</span>
          <div className="row gap-sm">
            <span className="grow t-body-sm t-ellipsis">{card.cardName} outstanding</span>
            <Money amount={outstandingAfter} currency={currency} className="t-title-sm" />
          </div>
          {source && sourceAfter != null ? (
            <div className="row gap-sm">
              <span className="grow t-body-sm t-ellipsis">{source.account.nickname}</span>
              <Money amount={sourceAfter} currency={currency} tone={sourceAfter < 0 ? 'negative' : 'neutral'} className="t-title-sm" />
            </div>
          ) : null}
          {outstandingAfter < 0 ? (
            <p className="t-body-sm t-center">That is more than you owe; the card will hold a {formatCurrency(-outstandingAfter, currency)} credit balance.</p>
          ) : null}
        </div>
      ) : null}

      {error ? <InlineError message={error} /> : null}
      <p className="t-label-sm t-center row gap-xs" style={{ justifyContent: 'center' }}>
        <Icon name="info" size={14} />
        {source ? `Shows as ${CARD_PAYMENT_LABEL} on ${source.account.nickname} and as a payment on the card.` : 'Lowers the card’s outstanding; no account balance changes.'}
      </p>
    </Sheet>
  );
}

// ---------------------------------------------------------------------------
// Refund, cashback, fee, interest, adjustment
// ---------------------------------------------------------------------------

type ManualKind = Exclude<CardTransactionKind, 'payment'>;

const PRESETS: Record<ManualKind, string[]> = {
  refund: [],
  cashback: ['Cashback', 'Reward points redeemed'],
  fee: ['Annual fee', 'Late payment fee', 'GST on charges'],
  interest: ['Finance charges'],
  adjustment: [],
};

export function CardTransactionSheet({
  open,
  card,
  purchases,
  refundOf,
  onClose,
}: {
  open: boolean;
  card: CreditCard;
  /** This card's purchases, newest first, offered as what a refund reverses. */
  purchases: readonly CardEntry[];
  /** Opens as a refund of this purchase. */
  refundOf?: CardEntry | null;
  onClose: () => void;
}) {
  const { symbol, currency } = useSettings();
  const { toast } = useFeedback();
  const record = useRecordCardTransaction();
  const [kind, setKind] = useState<ManualKind>('refund');
  const [adjustment, setAdjustment] = useState<LedgerDirection>('credit');
  const [amount, setAmount] = useState(refundOf ? amountToInput(refundOf.amount) : '');
  const [date, setDate] = useState(today());
  const [description, setDescription] = useState(refundOf ? `Refund: ${cardEntryTitle(refundOf)}` : '');
  const [reference, setReference] = useState('');
  const [originalId, setOriginalId] = useState(refundOf?.id ?? '');
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const meta = CARD_TRANSACTION_KINDS.find((k) => k.kind === kind) ?? CARD_TRANSACTION_KINDS[0];
  const direction = directionForKind(kind, adjustment);
  const raises = direction === 'debit';

  const submit = async () => {
    setSubmitted(true);
    if (validateAmount(amount)) return;
    setError(null);
    try {
      await record.mutateAsync({
        cardId: card.id,
        kind,
        direction,
        amount: parseAmount(amount) ?? 0,
        date,
        description,
        reference,
        originalExpenseId: kind === 'refund' && originalId ? originalId : null,
      });
      toast('success', `${meta?.label ?? 'Transaction'} recorded`);
      onClose();
    } catch (failure) {
      setError(errorMessage(failure, 'Could not record the transaction.'));
    }
  };

  return (
    <Sheet
      open={open}
      onClose={onClose}
      busy={record.isPending}
      title="Card transaction"
      subtitle={cardLabel(card)}
      footer={<Button label={`Record ${meta?.label.toLowerCase() ?? 'transaction'}`} size="lg" block busy={record.isPending} busyLabel="Saving…" onClick={() => void submit()} />}
    >
      <div>
        <FieldLabel text="Type" required />
        <ChipGroup label="Type">
          {CARD_TRANSACTION_KINDS.map((k) => (
            <Chip key={k.kind} label={k.label} selected={kind === k.kind} disabled={record.isPending} onClick={() => setKind(k.kind)} />
          ))}
        </ChipGroup>
        <p className="t-label-sm" style={{ paddingTop: 'var(--sp-xs)' }}>
          {meta?.hint}. {raises ? 'Adds to' : 'Lowers'} the outstanding{kind === 'refund' || kind === 'cashback' ? '; not counted as income' : ''}
          {kind === 'fee' || kind === 'interest' ? '; not counted as an expense' : ''}.
        </p>
      </div>
      {kind === 'adjustment' ? (
        <Segmented
          label="Direction"
          value={adjustment}
          onChange={setAdjustment}
          options={[
            { value: 'credit', label: 'Lower owed', icon: 'moneyIn' },
            { value: 'debit', label: 'Raise owed', icon: 'moneyOut' },
          ]}
          disabled={record.isPending}
        />
      ) : null}
      <AmountField
        value={amount}
        onChange={setAmount}
        symbol={symbol}
        tone={raises ? 'var(--expense)' : 'var(--income)'}
        disabled={record.isPending}
        error={submitted ? validateAmount(amount) : null}
      />
      <div>
        <FieldLabel text="Date" required />
        <DateField value={date} onChange={setDate} disabled={record.isPending} />
      </div>
      {kind === 'refund' && purchases.length ? (
        <div>
          <FieldLabel text="For purchase" hint="Optional" />
          <SelectField
            value={originalId}
            onChange={setOriginalId}
            options={purchases.slice(0, 60).map((p) => ({
              value: p.id,
              label: `${dayMonth(p.date)} · ${cardEntryTitle(p)} · ${formatCurrency(p.amount, currency)}`,
            }))}
            label="For purchase"
            icon="expenses"
            placeholder="Not linked to a purchase"
            disabled={record.isPending}
          />
        </div>
      ) : null}
      <div className="stack gap-sm">
        <FieldLabel text="Description" hint="Optional" />
        <TextField value={description} onChange={setDescription} placeholder="What was this?" aria-label="Description" icon="text" disabled={record.isPending} />
        {PRESETS[kind].length ? (
          <ChipGroup label="Suggestions">
            {PRESETS[kind].map((preset) => (
              <Chip key={preset} label={preset} selected={description.trim() === preset} onClick={() => setDescription(preset)} disabled={record.isPending} />
            ))}
          </ChipGroup>
        ) : null}
      </div>
      <div>
        <FieldLabel text="Reference" hint="Optional" />
        <TextField value={reference} onChange={setReference} placeholder="Transaction ID on the card statement" aria-label="Reference" icon="tag" disabled={record.isPending} />
      </div>
      {error ? <InlineError message={error} /> : null}
    </Sheet>
  );
}

/** The card behind a purchase row, for the refund shortcut. Shown when a purchase is long-pressed. */
export function PurchaseActions({
  entry,
  onOpen,
  onRefund,
}: {
  entry: CardEntry;
  onOpen: () => void;
  onRefund: () => void;
}) {
  const { currency } = useSettings();
  return (
    <Card padding="flush">
      <CardList indent={12}>
        <ListRow dense title="Open the expense" subtitle={`${cardEntryTitle(entry)} · ${formatCurrency(entry.amount, currency)}`} chevron onClick={onOpen} />
        <ListRow dense title="Record a refund" subtitle="Money back on the card for this purchase" chevron onClick={onRefund} />
      </CardList>
    </Card>
  );
}
