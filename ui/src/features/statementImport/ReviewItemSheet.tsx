import { useState } from 'react';

import { CategoryChips } from '@/components/finance/Pickers';
import { byPersonFirst, claimOptions, pendingOptions, purchaseOptions } from '@/components/finance/settleOptions';
import { TagField } from '@/components/finance/TagField';
import {
  LoanDetails,
  LoanTypePicker,
  PaidForToggle,
  PersonField,
  SettlementPicker,
  TransferMatchChoice,
  TransferTargetField,
  TreatmentPicker,
} from '@/components/finance/TreatmentFields';
import { Button } from '@/components/ui/Button';
import { Chip, ChipGroup, Segmented } from '@/components/ui/Chip';
import { InlineError, Notice } from '@/components/ui/Feedback';
import { AmountField, DateField, FieldLabel, TextArea, TextField } from '@/components/ui/Fields';
import { Sheet } from '@/components/ui/Sheet';
import { accountLabel, ledgerTitle, type BankAccount, type CreditCard, type ExpenseCategory } from '@/domain/models';
import { knownPeople, type ClaimSummary } from '@/domain/receivables';
import type { TransactionKind, TransactionType } from '@/domain/statementImport/model';
import { addTag } from '@/domain/tags';
import {
  kindsFor,
  pendingRepayments,
  similarItems,
  type ReviewEdit,
  type ReviewItem,
  type TransferMatch,
} from '@/domain/statementImport/review';
import { availableKinds, treatmentProblem, treatmentProblemMessage, type SettlementTarget, type TransferTarget } from '@/domain/treatment';
import { useCapabilities, usePurchasesBefore, useTags, useTransferMatches } from '@/hooks/data';
import { useTagInput } from '@/hooks/useTagInput';
import { formatCurrency, formatTime } from '@/lib/format';
import { amountToInput, parseAmount, MAX_AMOUNT } from '@/lib/validators';

import { duplicateText } from './labels';
import styles from './ImportStatement.module.css';

const DIRECTIONS: ReadonlyArray<{ value: TransactionType; label: string }> = [
  { value: 'debit', label: 'Money out' },
  { value: 'credit', label: 'Money in' },
];

export type ReviewSave = {
  patch: ReviewEdit;
  /** The same treatment for other rows from the same payee, when the user asked for it. */
  similar: { ids: string[]; patch: ReviewEdit } | null;
};

/** Edit one statement row before import. Nothing is saved from here — only the review list changes. */
export function ReviewItemSheet({
  open,
  item,
  items,
  categories,
  account,
  accounts,
  cards,
  claims,
  currency,
  symbol,
  onClose,
  onSave,
  onRemove,
}: {
  open: boolean;
  item: ReviewItem;
  /** Every row of the import: for repayments of rows earlier in it, and "apply to similar". */
  items: readonly ReviewItem[];
  categories: readonly ExpenseCategory[];
  /** The account the statement belongs to. */
  account: BankAccount | null;
  accounts: readonly BankAccount[];
  cards: readonly CreditCard[];
  claims: readonly ClaimSummary[];
  currency: string;
  symbol: string;
  onClose: () => void;
  onSave: (save: ReviewSave) => void;
  onRemove: () => void;
}) {
  const [description, setDescription] = useState(item.description);
  const [amount, setAmount] = useState(amountToInput(item.amount));
  const [date, setDate] = useState(item.transactionDate);
  const [type, setType] = useState<TransactionType>(item.transactionType);
  const [kind, setKind] = useState<TransactionKind>(item.kind);
  const [categoryId, setCategoryId] = useState(item.categoryId);
  const [source, setSource] = useState(item.kind === 'income' ? (item.category ?? '') : '');
  const [payee, setPayee] = useState(item.counterparty ?? '');
  const [target, setTarget] = useState<TransferTarget | null>(item.transferTarget);
  const [match, setMatch] = useState<TransferMatch | 'new' | null>(item.transferMatch);
  // Switched to a loan from the row's own picker: start from the payee the bank printed.
  const [person, setPerson] = useState(item.person || (item.kind === 'loan' || item.kind === 'reimbursement' ? (item.counterparty ?? '') : ''));
  const [dueDate, setDueDate] = useState(item.dueDate);
  const [note, setNote] = useState(item.note);
  const [reimbursable, setReimbursable] = useState(item.reimbursable);
  const [settles, setSettles] = useState<SettlementTarget | null>(item.settles);
  const [applySimilar, setApplySimilar] = useState(false);
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // A multi-account statement's row can move to another account; any other row stays on the statement's.
  const [bankAccountId, setBankAccountId] = useState(item.bankAccountId);
  const [time, setTime] = useState(item.transactionTime ?? '');
  const [notes, setNotes] = useState(item.notes ?? '');
  const tagInput = useTagInput(item.tags ?? []);

  const caps = useCapabilities();
  const knownTags = useTags().data ?? [];
  const value = parseAmount(amount);
  const people = knownPeople(claims);
  const movable = item.sourceAccount != null;
  const rowAccount = accounts.find((a) => a.id === bankAccountId) ?? (movable ? null : account);
  // The statement's own columns: a time, a Notes field — shown only when the statement has them.
  const hasTime = item.transactionTime !== undefined;
  const hasNotes = item.notes !== undefined;
  const taggable = caps.tags && (kind === 'expense' || kind === 'income');
  // Both legs of a transfer need migration 003; linking a row already on the other account needs 005.
  const transferAccounts = caps.transfers ? accounts : [];
  const state = { kind, categoryId, transferTarget: target, person, dueDate, note, reimbursable, settles };
  const problem = submitted ? treatmentProblem(state, type) : null;

  // The other side of a transfer may already be on that account (both statements imported).
  const targetAccountId = kind === 'transfer' && target?.type === 'account' ? target.accountId : null;
  const chosenElsewhere = items.flatMap((i) => (i.id !== item.id && i.transferMatch && i.transferMatch !== 'new' ? [i.transferMatch.entryId] : []));
  const matches = useTransferMatches({ accountId: targetAccountId, direction: type, amount: value, date, excludeIds: chosenElsewhere });
  const matchList = matches.data ?? [];
  const validMatch = match && match !== 'new' && matchList.some((m) => m.id === match.entryId) ? match.entryId : null;
  // Undecided: the closest candidate, which the user can see and change.
  const selectedMatchId = match === 'new' ? null : (validMatch ?? matchList[0]?.id ?? null);
  const targetAccount = accounts.find((a) => a.id === targetAccountId);

  // What a repayment or reimbursement can pay back.
  const elsewhere = pendingRepayments(items, item.id);
  const purchases = usePurchasesBefore(date, kind === 'reimbursement');
  const loanOptions = [
    ...claimOptions({ claims, kind: 'loan', current: settles, pendingElsewhere: elsewhere, currency }),
    ...pendingOptions({ items, kind: 'loan', exceptId: item.id, pendingElsewhere: elsewhere, currency }),
  ];
  const reimbursementOptions = byPersonFirst(
    [
      ...claimOptions({ claims, kind: 'reimbursable', current: settles, pendingElsewhere: elsewhere, currency }),
      ...pendingOptions({ items, kind: 'reimbursable', exceptId: item.id, pendingElsewhere: elsewhere, currency }),
      ...purchaseOptions({ purchases: purchases.data ?? [], claims, cards, currency }),
    ],
    person,
  );

  const similar = similarItems(items, item);

  /** A name to start from: the payee the bank printed. */
  const suggestPerson = () => {
    if (!person.trim() && payee.trim()) setPerson(payee.trim());
  };

  const changeType = (next: TransactionType) => {
    setType(next);
    if (!kindsFor(next).includes(kind)) setKind(next === 'debit' ? 'expense' : 'income');
    if (next === 'credit' && target?.type === 'card') setTarget(null);
    setSettles(null);
    setReimbursable(false);
  };

  const changeKind = (next: TransactionKind) => {
    setKind(next);
    setError(null);
    if (next === 'loan' || next === 'reimbursement') suggestPerson();
  };

  const save = () => {
    setSubmitted(true);
    if (value == null || value <= 0 || value > MAX_AMOUNT) {
      setError('Enter the amount shown on the statement.');
      return;
    }
    if (!description.trim()) {
      setError('Add a description.');
      return;
    }
    if (movable && !bankAccountId) {
      setError(type === 'debit' ? 'Choose the account it was paid from.' : 'Choose the account it was received in.');
      return;
    }
    const missing = treatmentProblem(state, type);
    if (missing) {
      setError(treatmentProblemMessage(missing, type));
      return;
    }
    const treatment: ReviewEdit = {
      kind,
      transferTarget: kind === 'transfer' ? target : item.transferTarget,
      person: person.trim(),
      dueDate: kind === 'loan' && type === 'debit' ? dueDate : null,
      note: kind === 'loan' && type === 'debit' ? note.trim() : '',
      reimbursable: kind === 'expense' && reimbursable,
      settles: kind === 'loan' && type === 'credit' ? settles : kind === 'reimbursement' ? settles : null,
    };
    if (kind === 'expense') treatment.categoryId = categoryId;
    const patch: ReviewEdit = { ...treatment };
    if (description.trim() !== item.description) patch.description = description.trim();
    if (value !== item.amount) patch.amount = value;
    if (date !== item.transactionDate) patch.transactionDate = date;
    if (type !== item.transactionType) patch.transactionType = type;
    if (kind === 'income' && source.trim() !== (item.category ?? '')) patch.category = source.trim() || null;
    if (payee.trim() !== (item.counterparty ?? '')) patch.counterparty = payee.trim() || null;
    if (movable && bankAccountId !== item.bankAccountId) patch.bankAccountId = bankAccountId;
    if (hasTime && (time || null) !== (item.transactionTime ?? null)) patch.transactionTime = time || null;
    if (hasNotes && (notes.trim() || null) !== (item.notes ?? null)) patch.notes = notes.trim() || null;
    if (taggable) {
      // Typed but not confirmed with Enter counts too.
      const tags = addTag(tagInput.tags, tagInput.draft, knownTags);
      if (tags.join('\n') !== (item.tags ?? []).join('\n')) patch.tags = tags;
    }
    if (targetAccountId && matches.isSuccess) {
      const chosen = matchList.find((m) => m.id === selectedMatchId);
      patch.transferMatch = chosen ? { entryId: chosen.id, label: ledgerTitle(chosen) } : 'new';
    }
    // Rows from the same payee get the same treatment, never this row's amount, date or matched leg.
    const apply = applySimilar && similar.length && type === item.transactionType;
    onSave({ patch, similar: apply ? { ids: similar.map((s) => s.id), patch: treatment } : null });
  };

  const amountText = value != null && value > 0 ? formatCurrency(value, currency) : 'this amount';

  return (
    <Sheet
      open={open}
      onClose={onClose}
      title="Edit transaction"
      subtitle="Changes apply to this import only."
      footer={
        <div className="row gap-sm" style={{ width: '100%' }}>
          <Button label="Remove" icon="delete" variant="dangerGhost" onClick={onRemove} />
          <span className="grow" />
          <Button label="Cancel" variant="secondary" onClick={onClose} />
          <Button label="Done" onClick={save} />
        </div>
      }
    >
      <div className="stack gap-lg">
        {item.duplicate ? <Notice icon="copy" tone="var(--warning)" message={duplicateText(item.duplicate)} /> : null}
        {item.issues.length ? <Notice icon="factCheck" tone="var(--warning)" message={item.issues.join('. ') + '.'} /> : null}

        {movable ? (
          <div>
            <FieldLabel
              text={type === 'debit' ? 'Paid from' : 'Received in'}
              required
              hint={bankAccountId ? (item.accountStatus === 'matched' && bankAccountId === item.bankAccountId ? 'Matched' : null) : 'Choose one'}
              hintIsError={!bankAccountId}
            />
            <ChipGroup label="Account">
              {accounts
                .filter((a) => a.isActive || a.id === bankAccountId)
                .map((a) => (
                  <Chip key={a.id} label={accountLabel(a)} icon="bank" selected={a.id === bankAccountId} onClick={() => setBankAccountId(a.id)} />
                ))}
            </ChipGroup>
            <p className="t-label-sm" style={{ paddingTop: 6 }}>
              The statement says: {item.sourceAccount || 'no account'}
            </p>
          </div>
        ) : null}

        <div>
          <FieldLabel text="Direction" />
          <Segmented label="Direction" value={type} options={DIRECTIONS} onChange={changeType} />
        </div>
        <TreatmentPicker type={type} value={kind} onChange={changeKind} kinds={availableKinds(type, caps.treatments)} />

        {kind === 'transfer' ? (
          <div className="stack gap-sm">
            <TransferTargetField
              type={type}
              source={rowAccount}
              accounts={transferAccounts}
              cards={cards}
              value={target}
              onChange={(next) => {
                setTarget(next);
                setMatch(null);
                setError(null);
              }}
              missing={problem === 'transferTarget'}
            />
            {targetAccount ? (
              <TransferMatchChoice
                matches={matchList}
                loading={matches.isLoading}
                selectedId={selectedMatchId}
                onSelect={(entry) => setMatch(entry ? { entryId: entry.id, label: ledgerTitle(entry) } : 'new')}
                accountName={targetAccount.nickname}
                amountText={amountText}
              />
            ) : null}
          </div>
        ) : null}

        {kind === 'loan' ? (
          <div className="stack gap-md">
            <LoanTypePicker type={type} onChange={changeType} />
            {type === 'debit' ? (
              <LoanDetails
                person={person}
                onPerson={setPerson}
                dueDate={dueDate}
                onDueDate={setDueDate}
                note={note}
                onNote={setNote}
                people={people}
                missing={problem === 'loanPerson'}
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
                emptyText="No money lent is waiting to be repaid. Record the loan first — as money out, Record as Loan."
              />
            )}
          </div>
        ) : null}

        {kind === 'reimbursement' ? (
          <div className="stack gap-md">
            <PersonField label="From" value={person} onChange={setPerson} people={people} missing={problem === 'settlePerson'} />
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
            />
          </div>
        ) : null}

        <div>
          <FieldLabel text="Amount" required />
          <AmountField
            value={amount}
            onChange={setAmount}
            symbol={symbol}
            // Neither income nor spending: the neutral transfer tone.
            tone={kind === 'transfer' || kind === 'loan' || kind === 'reimbursement' ? 'var(--transfer)' : type === 'credit' ? 'var(--income)' : 'var(--expense)'}
          />
        </div>
        {kind === 'expense' || kind === 'income' ? (
          <div>
            <FieldLabel text={kind === 'expense' ? 'Paid to' : 'Received from'} hint="Optional" />
            <TextField value={payee} onChange={setPayee} placeholder="Payee or payer" aria-label="Payee" icon="store" />
          </div>
        ) : null}
        <div>
          <FieldLabel text="Description" required />
          <TextField value={description} onChange={setDescription} aria-label="Description" icon="text" />
        </div>
        <div>
          <FieldLabel text={hasTime ? 'Date & time' : 'Date'} required />
          <div className="stack gap-sm">
            <DateField value={date} onChange={setDate} />
            {hasTime ? (
              <TextField type="time" value={time} onChange={setTime} aria-label="Time" icon="time" helper={time ? formatTime(time) : 'No time on the statement'} />
            ) : null}
          </div>
        </div>
        {kind === 'expense' ? (
          <>
            <div>
              <FieldLabel text="Category" required />
              <CategoryChips categories={categories} isSelected={(id) => id === categoryId} onToggle={setCategoryId} />
            </div>
            <PaidForToggle
              value={reimbursable}
              onChange={(on) => {
                setReimbursable(on);
                if (on) suggestPerson();
              }}
              person={person}
              onPerson={setPerson}
              people={people}
              missing={problem === 'paidForPerson'}
            />
          </>
        ) : null}
        {kind === 'income' ? (
          <div>
            <FieldLabel text="Source" hint="Optional" />
            <TextField value={source} onChange={setSource} placeholder="Salary, interest, client…" aria-label="Source" icon="work" />
          </div>
        ) : null}
        {hasNotes && (kind === 'expense' || kind === 'income') ? (
          <div>
            <FieldLabel text="Notes" hint="Optional" />
            <TextArea value={notes} onChange={setNotes} placeholder="Notes" aria-label="Notes" icon="notes" />
          </div>
        ) : null}
        {taggable ? (
          <div>
            <FieldLabel text="Tags" hint="Optional" />
            <TagField input={tagInput} known={knownTags} />
          </div>
        ) : null}
        {similar.length && type === item.transactionType ? (
          <label className={styles.similar}>
            <input type="checkbox" checked={applySimilar} onChange={(e) => setApplySimilar(e.target.checked)} />
            <span>
              Also record {similar.length} other {similar.length === 1 ? 'row' : 'rows'} from {item.counterparty} this way
            </span>
          </label>
        ) : null}
        <div className={styles.raw}>
          <span className="t-label-sm">As printed on the statement</span>
          <span className={styles.rawText}>{item.rawDescription || '—'}</span>
          {item.upiId ? <span className={styles.rawText}>UPI ID: {item.upiId}</span> : null}
          {item.upiId && item.reference ? <span className={styles.rawText}>UPI Ref No: {item.reference}</span> : null}
        </div>
        {error ? <InlineError message={error} /> : null}
      </div>
    </Sheet>
  );
}
