import { useId, useState } from 'react';
import { useNavigate } from 'react-router';

import { CategoryChips } from '@/components/finance/Pickers';
import { TagField } from '@/components/finance/TagField';
import { byPersonFirst, claimOptions, purchaseOptions } from '@/components/finance/settleOptions';
import {
  LoanDetails,
  PaidForToggle,
  PersonField,
  SettlementPicker,
  TransferMatchChoice,
  TransferTargetField,
  TreatmentPicker,
} from '@/components/finance/TreatmentFields';
import { Button } from '@/components/ui/Button';
import { InlineError, ListSkeleton, Notice } from '@/components/ui/Feedback';
import { AmountField, DateField, FieldLabel, TextField } from '@/components/ui/Fields';
import { Sheet } from '@/components/ui/Sheet';
import { accountLabel, type BankAccount, type CreditCard, type Expense, type Income, type LedgerEntry } from '@/domain/models';
import { knownPeople, type ClaimSummary } from '@/domain/receivables';
import { addTag } from '@/domain/tags';
import type { TransactionKind } from '@/domain/statementImport/model';
import { transferDescription } from '@/domain/transfer';
import {
  availableKinds,
  sameTransferTarget,
  treatmentOfEntry,
  treatmentProblem,
  treatmentProblemMessage,
  type ResolvedSettlement,
  type SettlementTarget,
  type TransferTarget,
  type TreatmentRequest,
} from '@/domain/treatment';
import {
  useCapabilities,
  useCategories,
  useClaims,
  useExpense,
  useIncomeItem,
  usePurchasesBefore,
  useTags,
  useTransactionTags,
  useTransferMatches,
} from '@/hooks/data';
import { useApplyTreatment } from '@/hooks/mutations';
import { useTagInput } from '@/hooks/useTagInput';
import { errorMessage } from '@/lib/errors';
import { formatCurrency } from '@/lib/format';
import { amountToInput, MAX_AMOUNT, parseAmount } from '@/lib/validators';
import { useFeedback } from '@/state/feedback';
import { useSettings } from '@/state/settings';

/**
 * Change how a saved bank movement is recorded: expense, income, transfer,
 * money lent, repayment or reimbursement. Everything a change involves — an
 * expense removed, the other transfer leg added or linked, a claim created —
 * is saved in one database transaction, so balances, income, spending and
 * what is owed always agree.
 */
export function EditMovementSheet({
  open,
  entry,
  account,
  accounts,
  cards,
  onClose,
  onDelete,
}: {
  open: boolean;
  entry: LedgerEntry;
  account: BankAccount;
  accounts: readonly BankAccount[];
  cards: readonly CreditCard[];
  onClose: () => void;
  onDelete: (entry: LedgerEntry) => void;
}) {
  const navigate = useNavigate();
  const { currency } = useSettings();
  const formId = useId();
  const apply = useApplyTreatment();
  const claims = useClaims();
  const expense = useExpense(entry.expenseId ?? undefined);
  const income = useIncomeItem(entry.incomeId ?? undefined);
  const expenseTags = useTransactionTags('expense', entry.expenseId ?? undefined);
  const incomeTags = useTransactionTags('income', entry.incomeId ?? undefined);
  const loading =
    claims.isPending ||
    (entry.expenseId != null && expense.isPending) ||
    (entry.incomeId != null && income.isPending) ||
    expenseTags.isPending ||
    incomeTags.isPending;
  // The tags the movement has now: none for a movement that is neither; null when they could not be read.
  const initialTags = entry.expenseId != null ? expenseTags.names : entry.incomeId != null ? incomeTags.names : [];
  const busy = apply.isPending;
  return (
    <Sheet
      open={open}
      onClose={onClose}
      busy={busy}
      title="Edit transaction"
      subtitle={`${accountLabel(account)} · ${formatCurrency(entry.amount, currency)} ${entry.direction === 'debit' ? 'out' : 'in'}`}
      footer={
        <div className="row gap-sm" style={{ width: '100%' }}>
          <Button label="Delete" icon="delete" variant="dangerGhost" disabled={busy} onClick={() => onDelete(entry)} />
          {entry.expenseId ? (
            <Button label="Expense" icon="expenses" variant="ghost" disabled={busy} onClick={() => void navigate(`/expenses/${entry.expenseId ?? ''}`)} />
          ) : null}
          <span className="grow" />
          <Button label="Cancel" variant="secondary" disabled={busy} onClick={onClose} />
          <Button label="Save" type="submit" form={formId} busy={busy} busyLabel="Saving…" disabled={loading} />
        </div>
      }
    >
      {loading ? (
        <ListSkeleton rows={3} />
      ) : (
        <EditMovementForm
          formId={formId}
          apply={apply}
          entry={entry}
          account={account}
          accounts={accounts}
          cards={cards}
          claims={claims.data ?? []}
          expense={expense.data ?? null}
          income={income.data ?? null}
          initialTags={initialTags}
          onClose={onClose}
        />
      )}
    </Sheet>
  );
}

function EditMovementForm({
  formId,
  apply,
  entry,
  account,
  accounts,
  cards,
  claims,
  expense,
  income,
  initialTags,
  onClose,
}: {
  formId: string;
  apply: ReturnType<typeof useApplyTreatment>;
  entry: LedgerEntry;
  account: BankAccount;
  accounts: readonly BankAccount[];
  cards: readonly CreditCard[];
  claims: readonly ClaimSummary[];
  expense: Expense | null;
  income: Income | null;
  /** The tags it has now; null when they could not be read, so they are neither shown nor changed. */
  initialTags: readonly string[] | null;
  onClose: () => void;
}) {
  const { currency, symbol } = useSettings();
  const { toast } = useFeedback();
  const caps = useCapabilities();
  const categories = useCategories().data ?? [];
  const knownTags = useTags().data ?? [];
  const tagInput = useTagInput(initialTags ?? []);
  const type = entry.direction;
  const initial = treatmentOfEntry(entry);
  const claim = entry.claim ? (claims.find((c) => c.receivable.id === entry.claim?.receivableId) ?? null) : null;
  const ownClaim = entry.claim?.role === 'source' ? claim : null;

  const [kind, setKind] = useState<TransactionKind>(initial.kind);
  const [categoryId, setCategoryId] = useState<string | null>(initial.categoryId ?? expense?.categoryId ?? null);
  const [target, setTarget] = useState<TransferTarget | null>(initial.transferTarget);
  /** The other account's row chosen as the other leg, 'new' to add one, null for the closest match. */
  const [matchId, setMatchId] = useState<{ entryId: string } | 'new' | null>(null);
  const [person, setPerson] = useState(initial.person);
  const [dueDate, setDueDate] = useState<string | null>(ownClaim?.receivable.dueDate ?? null);
  const [note, setNote] = useState(ownClaim?.receivable.note ?? '');
  const [reimbursable, setReimbursable] = useState(initial.reimbursable);
  const [settles, setSettles] = useState<SettlementTarget | null>(initial.settles);
  const [amount, setAmount] = useState(amountToInput(entry.amount));
  const [date, setDate] = useState(entry.txnDate);
  const [description, setDescription] = useState(entry.description ?? '');
  const [source, setSource] = useState(income?.source ?? '');
  const [keepCounterpart, setKeepCounterpart] = useState(false);
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const value = parseAmount(amount);
  const people = knownPeople(claims);
  const state = { kind, categoryId, transferTarget: target, person, dueDate, note, reimbursable, settles };
  const problem = submitted ? treatmentProblem(state, type) : null;
  const busy = apply.isPending;
  const showTags = caps.tags && initialTags != null && (kind === 'expense' || kind === 'income');

  // The transfer as it is now, and whether this edit keeps it.
  const wasAccountTransfer = entry.transferGroupId != null && entry.counterpartyAccountId != null;
  const keepsTransfer = kind === 'transfer' && sameTransferTarget(target, initial.transferTarget) && wasAccountTransfer;
  const oldOther = wasAccountTransfer ? accounts.find((a) => a.id === entry.counterpartyAccountId) : undefined;

  // A new other account may already hold the other side (its statement was imported).
  const newTargetId = kind === 'transfer' && target?.type === 'account' && !keepsTransfer ? target.accountId : null;
  const matches = useTransferMatches({ accountId: newTargetId, direction: type, amount: value, date });
  const matchList = matches.data ?? [];
  const selectedMatch = matchId === 'new' ? null : (matchList.find((m) => m.id === matchId?.entryId) ?? matchList[0] ?? null);
  const newTarget = accounts.find((a) => a.id === newTargetId);

  const purchases = usePurchasesBefore(date, kind === 'reimbursement');
  const loanOptions = claimOptions({ claims, kind: 'loan', current: settles, excludeEntryId: entry.id, currency });
  const reimbursementOptions = byPersonFirst(
    [
      ...claimOptions({ claims, kind: 'reimbursable', current: settles, excludeEntryId: entry.id, currency }),
      ...purchaseOptions({ purchases: purchases.data ?? [], claims, cards, currency }),
    ],
    person,
  );

  // What happens to money already received against this row's own claim.
  const stopsClaim = ownClaim != null && (ownClaim.receivable.kind === 'loan' ? kind !== 'loan' : kind !== 'expense' || !reimbursable);

  const changeKind = (next: TransactionKind) => {
    setKind(next);
    setError(null);
  };

  const resolveSettlement = (): ResolvedSettlement | null => {
    if (!settles) return null;
    if (settles.type === 'claim') return { receivableId: settles.receivableId };
    if (settles.type === 'expense') return { expenseId: settles.expenseId, person: person.trim() };
    return null;
  };

  const save = async () => {
    setSubmitted(true);
    if (value == null || value <= 0 || value > MAX_AMOUNT) {
      setError('Enter an amount greater than 0.');
      return;
    }
    const missing = treatmentProblem(state, type);
    if (missing) {
      setError(treatmentProblemMessage(missing, type));
      return;
    }
    const request: TreatmentRequest = {
      kind,
      direction: type,
      amount: value,
      date,
      description,
      keepPreviousCounterpart: wasAccountTransfer && !keepsTransfer && keepCounterpart,
    };
    if (kind === 'expense') {
      request.categoryId = categoryId;
      // A movement that becomes an expense keeps its text as the expense's description.
      if (entry.expenseId == null) request.expenseDescription = description;
      request.reimbursablePerson = reimbursable ? person.trim() : null;
      if (reimbursable && ownClaim) {
        request.dueDate = ownClaim.receivable.dueDate;
        request.note = ownClaim.receivable.note;
      }
    } else if (kind === 'income') {
      request.source = source;
      if (entry.incomeId == null) request.incomeDescription = description;
    } else if (kind === 'transfer') {
      request.transferTarget = target;
      if (newTargetId) {
        request.matchEntryId = selectedMatch?.id ?? null;
        request.counterpartDescription = transferDescription({ note: null, isOutgoing: type === 'credit', counterpartyLabel: account.nickname });
      }
    } else if (kind === 'loan' && type === 'debit') {
      request.person = person;
      request.dueDate = dueDate;
      request.note = note;
    } else {
      request.settles = resolveSettlement();
    }
    setError(null);
    try {
      const result = await apply.mutateAsync({
        entryId: entry.id,
        request,
        // Typed but not confirmed with Enter counts too. Only an expense or income has tags.
        tags: showTags ? { kind, names: addTag(tagInput.tags, tagInput.draft, knownTags) } : undefined,
      });
      toast('success', 'Transaction updated');
      if (result.tagError) toast('error', `The transaction was saved, but its tags were not: ${result.tagError}`);
      onClose();
    } catch (failure) {
      setError(errorMessage(failure, 'Could not update the transaction.'));
    }
  };

  const amountText = value != null && value > 0 ? formatCurrency(value, currency) : 'this amount';
  const out = type === 'debit';

  return (
    <form
      id={formId}
      className="stack gap-lg"
      noValidate
      onSubmit={(event) => {
        event.preventDefault();
        void save();
      }}
    >
      <TreatmentPicker type={type} value={kind} onChange={changeKind} kinds={availableKinds(type, caps.treatments)} disabled={busy} />

      {kind === 'transfer' ? (
        <div className="stack gap-sm">
          <TransferTargetField
            type={type}
            source={account}
            accounts={accounts}
            cards={cards}
            value={target}
            onChange={(next) => {
              setTarget(next);
              setMatchId(null);
              setError(null);
            }}
            missing={problem === 'transferTarget'}
            disabled={busy}
          />
          {newTarget ? (
            <TransferMatchChoice
              matches={matchList}
              loading={matches.isLoading}
              selectedId={selectedMatch?.id ?? null}
              onSelect={(match) => setMatchId(match ? { entryId: match.id } : 'new')}
              accountName={newTarget.nickname}
              amountText={amountText}
              disabled={busy}
            />
          ) : null}
        </div>
      ) : null}

      {kind === 'loan' ? (
        out ? (
          <LoanDetails
            person={person}
            onPerson={setPerson}
            dueDate={dueDate}
            onDueDate={setDueDate}
            note={note}
            onNote={setNote}
            people={people}
            missing={problem === 'loanPerson'}
            disabled={busy}
          />
        ) : (
          <SettlementPicker
            label="Repays"
            options={loanOptions}
            value={settles}
            onChange={(option) => {
              setSettles(option?.target ?? null);
              if (option?.person) setPerson(option.person);
            }}
            amount={value}
            currency={currency}
            missing={problem === 'loan'}
            emptyText="No money lent is waiting to be repaid. Record the loan first — on its money-out row, Record as Loan."
            disabled={busy}
          />
        )
      ) : null}

      {kind === 'reimbursement' ? (
        <div className="stack gap-md">
          <PersonField label="From" value={person} onChange={setPerson} people={people} missing={problem === 'settlePerson'} disabled={busy} />
          <SettlementPicker
            label="Pays back"
            options={reimbursementOptions}
            value={settles}
            onChange={(option) => {
              setSettles(option?.target ?? null);
              if (option?.person) setPerson(option.person);
            }}
            amount={value}
            currency={currency}
            missing={problem === 'settles'}
            emptyText={purchases.isLoading ? 'Loading recent purchases…' : 'No purchases in the last few months to match.'}
            disabled={busy}
          />
        </div>
      ) : null}

      {wasAccountTransfer && !keepsTransfer && oldOther ? (
        <label className="row gap-sm" style={{ alignItems: 'flex-start', cursor: 'pointer' }}>
          <input
            type="checkbox"
            checked={keepCounterpart}
            onChange={(e) => setKeepCounterpart(e.target.checked)}
            disabled={busy}
            style={{ marginTop: 3, accentColor: 'var(--primary)' }}
          />
          <span className="t-body-sm">
            Keep the other side on {oldOther.nickname} as plain money {out ? 'in' : 'out'}. Leave this off unless that entry came from{' '}
            {oldOther.nickname}'s own statement — otherwise it is removed, so its balance stays right.
          </span>
        </label>
      ) : null}

      {stopsClaim && ownClaim.received > 0 ? (
        <Notice
          icon="info"
          message={`${formatCurrency(ownClaim.received, currency)} already paid back stays as plain money in on its account. It will no longer reduce anything owed.`}
        />
      ) : null}

      <div>
        <FieldLabel text="Amount" required />
        <AmountField
          value={amount}
          onChange={setAmount}
          symbol={symbol}
          tone={kind === 'transfer' || kind === 'loan' || kind === 'reimbursement' ? 'var(--transfer)' : out ? 'var(--expense)' : 'var(--income)'}
          disabled={busy}
        />
        {keepsTransfer && oldOther && value !== entry.amount ? (
          <p className="t-label-sm" style={{ paddingTop: 6 }}>
            The other side on {oldOther.nickname} changes to the same amount.
          </p>
        ) : null}
      </div>

      {kind === 'income' ? (
        <div>
          <FieldLabel text="Source" hint="Optional" />
          <TextField value={source} onChange={setSource} placeholder="Salary, interest, client…" aria-label="Source" icon="work" disabled={busy} />
        </div>
      ) : null}
      <div>
        <FieldLabel text="Description" hint="Optional" />
        <TextField value={description} onChange={setDescription} aria-label="Description" icon="text" disabled={busy} />
      </div>
      {showTags ? (
        <div>
          <FieldLabel text="Tags" hint="Optional" />
          <TagField input={tagInput} known={knownTags} disabled={busy} />
        </div>
      ) : null}
      <div>
        <FieldLabel text="Date" required />
        <DateField value={date} onChange={setDate} disabled={busy} />
      </div>
      {kind === 'expense' ? (
        <>
          <div>
            <FieldLabel text="Category" required hint={problem === 'category' ? 'Pick one' : null} hintIsError={problem === 'category'} />
            <CategoryChips categories={categories} isSelected={(id) => id === categoryId} onToggle={setCategoryId} disabled={busy} />
          </div>
          {caps.treatments ? (
            <PaidForToggle
              value={reimbursable}
              onChange={setReimbursable}
              person={person}
              onPerson={setPerson}
              people={people}
              missing={problem === 'paidForPerson'}
              disabled={busy}
              progress={
                ownClaim && ownClaim.receivable.kind === 'reimbursable'
                  ? `${formatCurrency(ownClaim.received, currency)} of ${formatCurrency(ownClaim.principal, currency)} paid back`
                  : null
              }
            />
          ) : null}
        </>
      ) : null}

      {error ? <InlineError message={error} /> : null}
    </form>
  );
}
