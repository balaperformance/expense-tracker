import { useState } from 'react';
import { useLocation, useNavigate, useParams } from 'react-router';

import { Page } from '@/components/layout/Page';
import { CategoryAvatar } from '@/components/finance/Avatars';
import { AvailableCredit, CardChips, FundingToggle, type FundingMode } from '@/components/finance/CardPickers';
import { AccountChips, CategoryChips, PaymentMethodChips } from '@/components/finance/Pickers';
import { TagField } from '@/components/finance/TagField';
import { PaidForToggle } from '@/components/finance/TreatmentFields';
import { Button, IconButton } from '@/components/ui/Button';
import { Chip, ChipGroup } from '@/components/ui/Chip';
import { Centered, EmptyState, InlineError, ListSkeleton, Notice } from '@/components/ui/Feedback';
import { AmountField, DateField, FieldLabel, TextArea, TextField } from '@/components/ui/Fields';
import { Card, IconWell } from '@/components/ui/Surface';
import type { FrequentExpense } from '@/domain/frequentExpenses';
import type { Expense, ExpenseCategory } from '@/domain/models';
import type { ExpensePrefill } from '@/domain/prefill';
import type { ReceiptResult } from '@/domain/receipt/result';
import { CLAIM_STATUS_LABELS, knownPeople, type ClaimSummary } from '@/domain/receivables';
import { addTag } from '@/domain/tags';
import {
  useAccounts,
  useCapabilities,
  useCategories,
  useClaims,
  useCreditCards,
  useExpense,
  useFrequentExpenses,
  usePaymentMethods,
  useTags,
  useTransactionTags,
} from '@/hooks/data';
import { useGoBack } from '@/hooks/useGoBack';
import { useIsDark } from '@/hooks/useIsDark';
import { useTagInput } from '@/hooks/useTagInput';
import { useDeleteExpense, useSaveExpense } from '@/hooks/mutations';
import { phase2Ready } from '@/services/capabilities';
import { readableOn } from '@/lib/color';
import { errorMessage } from '@/lib/errors';
import { dayMonthYear, formatCurrency } from '@/lib/format';
import { today } from '@/lib/dates';
import { amountToInput, parseAmount, validateAmount } from '@/lib/validators';
import { useFeedback } from '@/state/feedback';
import { useSettings } from '@/state/settings';

import { ReceiptReview } from '../receipt/ReceiptReview';
import { ScanSheet } from '../receipt/ScanSheet';

import styles from './Expenses.module.css';

/** `/expenses/new` (optionally with a prefill in the route state) and `/expenses/:id`. */
export function ExpenseFormPage() {
  const { id } = useParams();
  const location = useLocation();
  const routeState = location.state as { prefill?: ExpensePrefill; creditCardId?: string } | null;
  const prefill = routeState?.prefill;
  const existing = useExpense(id);
  const caps = useCapabilities();
  const claims = useClaims();
  const tagsOf = useTransactionTags('expense', id);

  if (id) {
    // Wait for the claims and tags too: saving before knowing them would unmark the purchase or clear its tags.
    if (existing.isPending || (caps.treatments && claims.isPending) || tagsOf.isPending) {
      return (
        <Page title="Edit expense" back="/expenses" narrow>
          <ListSkeleton rows={4} />
        </Page>
      );
    }
    if (!existing.data) {
      return (
        <Page title="Edit expense" back="/expenses" narrow>
          <Centered>
            <EmptyState icon="searchOff" title="Expense not found" message="It may have been deleted on another device." />
          </Centered>
        </Page>
      );
    }
    const expenseId = existing.data.id;
    const claim = (claims.data ?? []).find((c) => c.receivable.expenseId === expenseId) ?? null;
    return <ExpenseForm key={expenseId} expense={existing.data} claim={claim} people={knownPeople(claims.data ?? [])} initialTags={tagsOf.names} />;
  }
  return (
    <ExpenseForm key={location.key} prefill={prefill} presetCardId={routeState?.creditCardId ?? null} people={knownPeople(claims.data ?? [])} initialTags={[]} />
  );
}

function ExpenseForm({
  expense,
  prefill,
  presetCardId = null,
  claim = null,
  people,
  initialTags,
}: {
  expense?: Expense;
  prefill?: ExpensePrefill;
  presetCardId?: string | null;
  /** The expense's claim when it was paid on someone else's behalf. */
  claim?: ClaimSummary | null;
  people: readonly string[];
  /** The expense's tags; null when they could not be read, so they are neither shown nor changed. */
  initialTags: readonly string[] | null;
}) {
  const navigate = useNavigate();
  const goBack = useGoBack('/expenses');
  const { symbol, currency } = useSettings();
  const { toast, confirm } = useFeedback();
  const caps = useCapabilities();
  const categories = useCategories().data ?? [];
  const methods = usePaymentMethods().data ?? [];
  const accounts = (useAccounts().data ?? []).map((b) => b.account);
  const cards = useCreditCards();
  const save = useSaveExpense();
  const remove = useDeleteExpense();
  const knownTags = useTags().data ?? [];
  const tagInput = useTagInput(initialTags ?? []);
  const showTags = caps.tags && initialTags != null;
  const editing = expense != null;
  const seed = expense ?? null;

  const [amount, setAmount] = useState(seed ? amountToInput(seed.amount) : prefill?.amount != null ? amountToInput(prefill.amount) : '');
  const [description, setDescription] = useState(seed?.description ?? prefill?.description ?? prefill?.merchant ?? '');
  const [notes, setNotes] = useState(seed?.notes ?? prefill?.notes ?? '');
  const [categoryId, setCategoryId] = useState<string | null>(seed?.categoryId ?? prefill?.categoryId ?? null);
  const [paymentMethodId, setPaymentMethodId] = useState<string | null>(seed?.paymentMethodId ?? prefill?.paymentMethodId ?? null);
  const [bankAccountId, setBankAccountId] = useState<string | null>(seed?.bankAccountId ?? null);
  const initialCardId = seed ? seed.creditCardId : presetCardId;
  const [funding, setFunding] = useState<FundingMode>(initialCardId ? 'card' : 'account');
  const [creditCardId, setCreditCardId] = useState<string | null>(initialCardId);
  const [date, setDate] = useState(seed?.expenseDate ?? prefill?.date ?? today());
  const [fromScan, setFromScan] = useState(prefill?.source === 'receiptScan');
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [scanOpen, setScanOpen] = useState(false);
  const [receipt, setReceipt] = useState<ReceiptResult | null>(null);
  const [paidFor, setPaidFor] = useState(claim != null);
  const [paidForPerson, setPaidForPerson] = useState(claim?.receivable.person ?? '');
  const paidForMissing = submitted && paidFor && !paidForPerson.trim();
  // Offered only on a blank new expense: a scan, an SMS or a card's "Add purchase" already says what this is.
  const quickAdd = useFrequentExpenses(!editing && !prefill && presetCardId == null);
  const [quickAdded, setQuickAdded] = useState<FrequentExpense | null>(null);

  const busy = save.isPending || remove.isPending;
  const amountError = submitted ? validateAmount(amount) : null;
  const categoryMissing = submitted && categoryId == null;
  // Inactive cards are offered only to the purchase already on them.
  const cardOptions = caps.creditCards ? (cards.data ?? []).filter((o) => o.card.isActive || o.card.id === seed?.creditCardId) : [];
  const payByCard = caps.creditCards && funding === 'card';
  const selectedCard = payByCard ? cardOptions.find((o) => o.card.id === creditCardId) : undefined;
  const cardMissing = submitted && payByCard && !selectedCard;

  const applyPrefill = (scanned: ExpensePrefill) => {
    if (scanned.amount != null) setAmount(amountToInput(scanned.amount));
    // There is no merchant field: a scanned merchant goes in the description when nothing else describes the purchase.
    if (scanned.description) setDescription(scanned.description);
    else if (scanned.merchant && !description.trim()) setDescription(scanned.merchant);
    if (scanned.date) setDate(scanned.date);
    if (scanned.categoryId) setCategoryId(scanned.categoryId);
    if (scanned.paymentMethodId) setPaymentMethodId(scanned.paymentMethodId);
    setFromScan(true);
    setQuickAdded(null);
    setSubmitted(false);
    setError(null);
  };

  /**
   * Starts the form from the habit's latest purchase. Every field the chip
   * covers is replaced, so switching chips never mixes two habits; nothing is
   * saved until the user saves.
   */
  const applyQuickAdd = (suggestion: FrequentExpense) => {
    // A varying amount is left blank for the user to type.
    setAmount(suggestion.amount != null ? amountToInput(suggestion.amount) : '');
    setCategoryId(suggestion.categoryId);
    // There is no merchant field: the description carries the name, so the next one joins the same habit.
    setDescription(suggestion.title ?? '');
    setPaymentMethodId(suggestion.paymentMethodId);
    // An account or card closed since falls back to cash, as on a blank form.
    const source = suggestion.source;
    setFunding(source?.kind === 'card' ? 'card' : 'account');
    if (source?.kind === 'card') setCreditCardId(source.id);
    else setBankAccountId(source?.kind === 'account' ? source.id : null);
    setQuickAdded(suggestion);
    setFromScan(false);
    setSubmitted(false);
    setError(null);
  };

  const submit = async () => {
    setSubmitted(true);
    // Never save while the card list is still loading: that would silently drop the card.
    const cardProblem = payByCard && !selectedCard;
    const personProblem = caps.treatments && paidFor && !paidForPerson.trim();
    setError(
      categoryId == null
        ? 'Choose a category for this expense.'
        : cardProblem
          ? cards.isPending || cards.isError
            ? 'Your cards could not be loaded yet, so this cannot be saved against a card. Try again in a moment.'
            : 'Choose the credit card this was paid with.'
          : personProblem
            ? 'Add who you paid for.'
            : null,
    );
    if (validateAmount(amount) || categoryId == null || cardProblem || personProblem) return;
    try {
      const result = await save.mutateAsync({
        // Marked, unmarked, or — when it never was and still is not — left alone.
        paidFor: !caps.treatments
          ? undefined
          : paidFor
            ? { person: paidForPerson.trim(), dueDate: claim?.receivable.dueDate ?? null, note: claim?.receivable.note ?? null }
            : claim
              ? null
              : undefined,
        id: expense?.id,
        draft: {
          amount: parseAmount(amount) ?? 0,
          expenseDate: date,
          categoryId,
          paymentMethodId,
          // One funding source: a card purchase never touches a bank balance.
          bankAccountId: selectedCard ? null : bankAccountId,
          creditCardId: selectedCard?.card.id ?? null,
          description,
          notes,
        },
        // Typed but not confirmed with Enter counts too. Left alone when the tags are unavailable.
        tags: showTags ? addTag(tagInput.tags, tagInput.draft, knownTags) : undefined,
      });
      toast('success', editing ? 'Expense updated' : 'Expense added');
      if (result.tagError) toast('error', `The expense was saved, but its tags were not: ${result.tagError}`);
      goBack();
    } catch (failure) {
      setError(errorMessage(failure, 'Could not save the expense.'));
    }
  };

  const confirmDelete = async () => {
    if (!expense) return;
    const ok = await confirm({
      title: 'Delete expense?',
      message: `This removes ${formatCurrency(expense.amount, currency)} from ${dayMonthYear(expense.expenseDate)}. This cannot be undone.`,
    });
    if (!ok) return;
    try {
      await remove.mutateAsync(expense.id);
      toast('success', 'Expense deleted');
      goBack();
    } catch (failure) {
      setError(errorMessage(failure, 'Could not delete the expense.'));
    }
  };

  if (receipt) {
    return (
      <ReceiptReview
        result={receipt}
        onCancel={() => setReceipt(null)}
        onContinue={(scanned) => {
          applyPrefill(scanned);
          setReceipt(null);
        }}
      />
    );
  }

  return (
    <Page
      title={editing ? 'Edit expense' : 'Add expense'}
      back="/expenses"
      narrow
      actions={editing ? <IconButton icon="delete" label="Delete" disabled={busy} onClick={() => void confirmDelete()} /> : null}
      bar={
        <Button
          label={editing ? 'Save changes' : 'Add expense'}
          size="lg"
          block
          busy={save.isPending}
          busyLabel="Saving…"
          disabled={busy}
          onClick={() => void submit()}
        />
      }
    >
      {!editing ? (
        <div className="stack gap-sm">
          <EntryCard
            icon="scan"
            title="Scan a receipt"
            subtitle="Fill this form from a photo"
            action="Scan"
            actionIcon="camera"
            disabled={busy}
            onClick={() => setScanOpen(true)}
          />
          <EntryCard
            icon="sms"
            title="Paste bank SMS"
            subtitle="Read an alert from your bank"
            action="Paste"
            actionIcon="paste"
            disabled={busy}
            onClick={() => void navigate('/expenses/sms')}
          />
        </div>
      ) : null}

      {quickAdd.length ? (
        <div>
          <FieldLabel text="Quick add" hint="Your frequent expenses" />
          <QuickAddChips
            suggestions={quickAdd}
            categories={categories}
            currency={currency}
            selectedKey={quickAdded?.key ?? null}
            onPick={applyQuickAdd}
            disabled={busy}
          />
        </div>
      ) : null}

      {fromScan ? (
        <Notice icon="assistant" tone="var(--primary)" message="Filled in from your receipt. Change anything that is not right before saving." />
      ) : null}

      {quickAdded ? (
        <Notice
          icon="assistant"
          tone="var(--primary)"
          message={`Filled in from your usual “${quickAddName(quickAdded, categories)}”. ${
            quickAdded.amount == null ? 'Enter the amount (it varies) and change' : 'Change'
          } anything that is not right before saving.`}
        />
      ) : null}

      <AmountField value={amount} onChange={setAmount} symbol={symbol} tone="var(--expense)" autoFocus={!editing && !prefill} disabled={busy} error={amountError} />

      <div>
        <FieldLabel text="Category" required hint={categoryMissing ? 'Pick one' : null} hintIsError={categoryMissing} />
        <CategoryChips
          categories={categories}
          isSelected={(cid) => cid === categoryId}
          onToggle={(cid) => {
            setCategoryId(cid);
            setError(null);
          }}
          disabled={busy}
          error={categoryMissing}
        />
      </div>

      <div>
        <FieldLabel text="Date" required />
        <DateField value={date} onChange={setDate} disabled={busy} />
      </div>

      {phase2Ready(caps) || cardOptions.length || payByCard ? (
        <div>
          <FieldLabel
            text="Paid from"
            required
            hint={payByCard ? (cardMissing ? 'Pick a card' : null) : bankAccountId == null ? 'No balance affected' : null}
            hintIsError={cardMissing}
          />
          <div className="stack gap-sm">
            {cardOptions.length || payByCard ? (
              <FundingToggle
                value={payByCard ? 'card' : 'account'}
                onChange={(mode) => {
                  setFunding(mode);
                  setError(null);
                }}
                disabled={busy}
              />
            ) : null}
            {payByCard && !cardOptions.length ? (
              cards.isPending ? (
                <ListSkeleton rows={1} />
              ) : cards.isError ? (
                <div className="stack gap-sm">
                  <Notice icon="error" tone="var(--error)" message={`Could not load your cards. ${errorMessage(cards.error)}`} />
                  <Button label="Try again" icon="refresh" variant="tonal" size="sm" onClick={() => void cards.refetch()} />
                </div>
              ) : (
                <Notice message="No active credit cards. Add one from Credit cards, or switch to cash or account." />
              )
            ) : payByCard ? (
              <>
                <CardChips
                  cards={cardOptions.map((o) => o.card)}
                  selectedId={creditCardId}
                  onSelect={(cid) => {
                    setCreditCardId(cid);
                    setError(null);
                  }}
                  disabled={busy}
                  error={cardMissing}
                />
                {selectedCard ? (
                  <AvailableCredit
                    card={selectedCard.card}
                    summary={selectedCard.summary}
                    amount={parseAmount(amount)}
                    alreadyCounted={seed?.creditCardId === selectedCard.card.id ? seed.amount : 0}
                    currency={currency}
                  />
                ) : null}
              </>
            ) : accounts.length ? (
              <AccountChips accounts={accounts} selectedId={bankAccountId} onSelect={setBankAccountId} disabled={busy} />
            ) : phase2Ready(caps) ? (
              <Notice message="Add a bank account to track expenses against a balance. Until then everything is recorded as cash." />
            ) : (
              <Notice message="Recorded as cash: no balance changes." />
            )}
          </div>
        </div>
      ) : null}

      {caps.treatments ? (
        <div className="stack gap-sm">
          <PaidForToggle
            value={paidFor}
            onChange={(on) => {
              setPaidFor(on);
              setError(null);
            }}
            person={paidForPerson}
            onPerson={setPaidForPerson}
            people={people}
            missing={paidForMissing}
            disabled={busy}
            progress={
              claim
                ? `${formatCurrency(claim.received, currency)} of ${formatCurrency(claim.principal, currency)} paid back · ${CLAIM_STATUS_LABELS[claim.status]}`
                : null
            }
          />
          {claim && !paidFor && claim.received > 0 ? (
            <Notice
              icon="info"
              message={`${formatCurrency(claim.received, currency)} already paid back stays as plain money in on its account, and this becomes your own spending again.`}
            />
          ) : null}
        </div>
      ) : null}

      <div>
        <FieldLabel text="Details" hint="Optional" />
        <Card>
          <div className="stack gap-sm">
            <TextField value={description} onChange={setDescription} placeholder="Description" aria-label="Description" icon="text" autoCapitalize="sentences" disabled={busy} />
            {showTags ? <TagField input={tagInput} known={knownTags} disabled={busy} /> : null}
            <TextArea value={notes} onChange={setNotes} placeholder="Notes" aria-label="Notes" icon="notes" disabled={busy} />
            {methods.length ? (
              <div className={styles.subField}>
                <span className="t-label-md">Payment method</span>
                <PaymentMethodChips methods={methods} selectedId={paymentMethodId} onSelect={setPaymentMethodId} disabled={busy} />
              </div>
            ) : null}
          </div>
        </Card>
      </div>

      {error ? <InlineError message={error} /> : null}

      <ScanSheet open={scanOpen} onClose={() => setScanOpen(false)} onScanned={setReceipt} />
    </Page>
  );
}

/** "Scan a receipt" / "Paste bank SMS" entry points at the top of a new expense. */
function EntryCard({
  icon,
  title,
  subtitle,
  action,
  actionIcon,
  onClick,
  disabled,
}: {
  icon: 'scan' | 'sms';
  title: string;
  subtitle: string;
  action: string;
  actionIcon: 'camera' | 'paste';
  onClick: () => void;
  disabled?: boolean;
}) {
  return (
    <Card padding="flush">
      <div className={styles.entry}>
        <IconWell icon={icon} size={30} />
        <div className="grow stack">
          <span className="t-title-sm">{title}</span>
          <span className="t-body-sm t-ellipsis">{subtitle}</span>
        </div>
        <Button label={action} icon={actionIcon} size="sm" variant="tonal" onClick={onClick} disabled={disabled} />
      </div>
    </Card>
  );
}

/** "Coffee", or the category's name when the habit has neither merchant nor description. */
function quickAddName(suggestion: FrequentExpense, categories: readonly ExpenseCategory[]): string {
  return suggestion.title ?? categories.find((c) => c.id === suggestion.categoryId)?.name ?? 'Expense';
}

/** A long merchant is shortened on its chip, so the amount after it always shows. */
const chipName = (name: string) => (name.length > 22 ? `${name.slice(0, 21).trimEnd()}…` : name);

/** One chip per frequent expense: "Coffee · ₹120.00", or just "Groceries" when its amount varies. */
function QuickAddChips({
  suggestions,
  categories,
  currency,
  selectedKey,
  onPick,
  disabled,
}: {
  suggestions: readonly FrequentExpense[];
  categories: readonly ExpenseCategory[];
  currency: string;
  selectedKey: string | null;
  onPick: (suggestion: FrequentExpense) => void;
  disabled?: boolean;
}) {
  const dark = useIsDark();
  return (
    <ChipGroup label="Quick add">
      {suggestions.map((suggestion) => {
        const category = categories.find((c) => c.id === suggestion.categoryId);
        const name = chipName(quickAddName(suggestion, categories));
        return (
          <Chip
            key={suggestion.key}
            label={suggestion.amount == null ? name : `${name} · ${formatCurrency(suggestion.amount, currency)}`}
            selected={suggestion.key === selectedKey}
            disabled={disabled}
            tone={category ? readableOn(category.color, dark) : undefined}
            avatar={category ? <CategoryAvatar icon={category.icon} color={category.color} size={24} /> : undefined}
            onClick={() => onPick(suggestion)}
          />
        );
      })}
    </ChipGroup>
  );
}
