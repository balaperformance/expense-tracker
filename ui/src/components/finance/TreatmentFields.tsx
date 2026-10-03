/**
 * The fields behind "Record as", shared by the statement import's edit sheet
 * and the account statement's. Each treatment shows only what it needs:
 *
 *   Transfer       → Transfer to / from [account ▼], and the row to link if
 *                    the other account already has it
 *   Loan (out)     → Lent to [person], due back, note
 *   Loan (in)      → Repays [loan ▼]
 *   Reimbursement  → From [person], for [purchase ▼]
 *   Expense        → "Paid for someone else" → [person]
 */
import { useId } from 'react';

import { Chip, ChipGroup, Segmented } from '@/components/ui/Chip';
import { DatePickerField, FieldLabel, SelectField, TextField } from '@/components/ui/Fields';
import { Icon, type IconName } from '@/components/ui/Icon';
import { accountLabel, cardLabel, ledgerTitle, type BankAccount, type CreditCard, type LedgerEntry } from '@/domain/models';
import { personKey } from '@/domain/receivables';
import type { TransactionKind, TransactionType } from '@/domain/statementImport/model';
import {
  kindsFor,
  matchRecordedAs,
  TREATMENT_LABELS,
  treatmentHint,
  type SettlementTarget,
  type TransferTarget,
} from '@/domain/treatment';
import { dayMonth, formatCurrency } from '@/lib/format';

import { settleKey, type SettleOption } from './settleOptions';
import styles from './Treatment.module.css';

const ICONS: Partial<Record<TransactionKind, IconName>> = {
  transfer: 'transfer',
  loan: 'lend',
  reimbursement: 'lend',
};

/** "Record as": a segmented control for money out (three choices), wrapping chips for money in (five). */
export function TreatmentPicker({
  type,
  value,
  onChange,
  kinds = kindsFor(type),
  disabled,
}: {
  type: TransactionType;
  value: TransactionKind;
  onChange: (kind: TransactionKind) => void;
  /** The choices offered; every kind valid for the direction by default. */
  kinds?: readonly TransactionKind[];
  disabled?: boolean;
}) {
  const options = kinds.map((kind) => ({ value: kind, label: TREATMENT_LABELS[kind] }));
  const hint = treatmentHint(value, type);
  return (
    <div>
      <FieldLabel text="Record as" hint={hint} />
      {options.length <= 3 ? (
        <Segmented label="Record as" value={value} options={options} onChange={onChange} disabled={disabled} />
      ) : (
        <ChipGroup label="Record as">
          {options.map((option) => (
            <Chip
              key={option.value}
              label={option.label}
              icon={ICONS[option.value]}
              selected={option.value === value}
              disabled={disabled}
              onClick={() => onChange(option.value)}
            />
          ))}
        </ChipGroup>
      )}
    </div>
  );
}

/** "Money lent" / "Repayment received": the loan's direction is the movement's. */
export function LoanTypePicker({ type, onChange, disabled }: { type: TransactionType; onChange: (type: TransactionType) => void; disabled?: boolean }) {
  return (
    <div>
      <FieldLabel text="Loan type" />
      <Segmented
        label="Loan type"
        value={type}
        options={[
          { value: 'debit', label: 'Money lent' },
          { value: 'credit', label: 'Repayment received' },
        ]}
        onChange={onChange}
        disabled={disabled}
      />
    </div>
  );
}

// ---------------------------------------------------------------------------
// Transfer
// ---------------------------------------------------------------------------

const encodeTarget = (target: TransferTarget | null) =>
  target == null ? '' : target.type === 'account' ? `account:${target.accountId}` : target.type === 'card' ? `card:${target.cardId}` : 'cash';

function decodeTarget(value: string): TransferTarget | null {
  if (value === 'cash') return { type: 'cash' };
  if (value.startsWith('account:')) return { type: 'account', accountId: value.slice(8) };
  if (value.startsWith('card:')) return { type: 'card', cardId: value.slice(5) };
  return null;
}

/** "Transfer to" (money out) or "Transfer from" (money in): your other accounts, cash, and — money out — your cards. */
export function TransferTargetField({
  type,
  source,
  accounts,
  cards,
  value,
  onChange,
  missing,
  disabled,
}: {
  type: TransactionType;
  /** The account this movement is on; never offered as its own other side. */
  source: BankAccount | null;
  accounts: readonly BankAccount[];
  cards: readonly CreditCard[];
  value: TransferTarget | null;
  onChange: (target: TransferTarget | null) => void;
  missing?: boolean;
  disabled?: boolean;
}) {
  const out = type === 'debit';
  // Inactive accounts and cards stay listed only when already chosen.
  const options = [
    ...accounts
      .filter((a) => a.id !== source?.id && (a.isActive || (value?.type === 'account' && value.accountId === a.id)))
      .map((a) => ({ value: `account:${a.id}`, label: accountLabel(a) })),
    { value: 'cash', label: out ? 'Cash, or an account not tracked here' : 'Cash, or an account not tracked here' },
    ...(out
      ? cards
          .filter((c) => c.isActive || (value?.type === 'card' && value.cardId === c.id))
          .map((c) => ({ value: `card:${c.id}`, label: `${cardLabel(c)} — card bill` }))
      : []),
  ];
  const account = value?.type === 'account' ? accounts.find((a) => a.id === value.accountId) : undefined;
  const card = value?.type === 'card' ? cards.find((c) => c.id === value.cardId) : undefined;
  const here = source?.nickname ?? 'This account';
  const there = account ? account.nickname : card ? cardLabel(card) : value?.type === 'cash' ? 'Cash' : null;
  const note =
    value?.type === 'account'
      ? 'Your own money moving: both balances change. Not income or spending.'
      : value?.type === 'card'
        ? "Pays the card's bill: its outstanding goes down. Not spending — the purchases already are."
        : value?.type === 'cash'
          ? 'Only this balance changes. Not income or spending.'
          : null;
  return (
    <div>
      <FieldLabel text={out ? 'Transfer to' : 'Transfer from'} required hint={missing ? 'Choose one' : null} hintIsError={missing} />
      <SelectField
        value={encodeTarget(value)}
        onChange={(v) => onChange(decodeTarget(v))}
        options={options}
        label={out ? 'Transfer to' : 'Transfer from'}
        icon="transfer"
        placeholder="Select account"
        disabled={disabled}
      />
      {there ? (
        <div className={styles.route}>
          <span className={styles.routeEnd}>
            <Icon name="bank" size={15} />
            <span>{out ? here : there}</span>
          </span>
          <Icon name="arrowForward" size={15} className={styles.routeArrow} />
          <span className={styles.routeEnd}>
            <Icon name={card ? 'card' : value?.type === 'cash' ? 'cash' : 'bank'} size={15} />
            <span>{out ? there : here}</span>
          </span>
          {note ? <span className={styles.routeNote}>{note}</span> : null}
        </div>
      ) : null}
    </div>
  );
}

/**
 * Whether the other account already has this movement (both statements
 * imported): pick it to link the two, or add a new entry there.
 */
export function TransferMatchChoice({
  matches,
  loading,
  selectedId,
  onSelect,
  accountName,
  amountText,
  disabled,
}: {
  matches: readonly LedgerEntry[];
  loading: boolean;
  /** The chosen row, or null to add a new entry. */
  selectedId: string | null;
  onSelect: (entry: LedgerEntry | null) => void;
  accountName: string;
  amountText: string;
  disabled?: boolean;
}) {
  const name = useId();
  if (loading) return <p className={styles.status}>Checking {accountName} for the same transaction…</p>;
  if (!matches.length) return <p className={styles.status}>Adds {amountText} on {accountName} as the other side.</p>;
  return (
    <div>
      <FieldLabel text={`Already on ${accountName}?`} />
      <div className={styles.choices} role="radiogroup" aria-label={`Already on ${accountName}?`}>
        {matches.map((entry) => {
          const recorded = matchRecordedAs(entry);
          return (
            <label key={entry.id} className={styles.choice}>
              <input type="radio" name={name} checked={selectedId === entry.id} disabled={disabled} onChange={() => onSelect(entry)} />
              <span className={styles.choiceText}>
                <span>
                  Link {dayMonth(entry.txnDate)} · {ledgerTitle(entry)}
                </span>
                <small>{recorded ? `Was ${recorded}` : 'The same money, recorded once — no second entry'}</small>
              </span>
            </label>
          );
        })}
        <label className={styles.choice}>
          <input type="radio" name={name} checked={selectedId == null} disabled={disabled} onChange={() => onSelect(null)} />
          <span className={styles.choiceText}>
            <span>No — add {amountText} on {accountName}</span>
          </span>
        </label>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// People and claims
// ---------------------------------------------------------------------------

/** Free text with the people already used offered as suggestions, so "Arun" stays one person. */
export function PersonField({
  label,
  value,
  onChange,
  people,
  missing,
  disabled,
  placeholder = 'Name',
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  people: readonly string[];
  missing?: boolean;
  disabled?: boolean;
  placeholder?: string;
}) {
  const listId = useId();
  const typed = personKey(value);
  const suggestions = people.filter((p) => personKey(p) !== typed && (!typed || personKey(p).startsWith(typed))).slice(0, 4);
  return (
    <div>
      <FieldLabel text={label} required hint={missing ? 'Add a name' : null} hintIsError={missing} />
      <TextField
        value={value}
        onChange={onChange}
        placeholder={placeholder}
        aria-label={label}
        icon="person"
        autoCapitalize="words"
        autoComplete="off"
        list={listId}
        maxLength={80}
        disabled={disabled}
      />
      <datalist id={listId}>
        {people.map((p) => (
          <option key={p} value={p} />
        ))}
      </datalist>
      {suggestions.length ? (
        <div className={styles.suggestions}>
          <ChipGroup label="People you have used">
            {suggestions.map((p) => (
              <Chip key={p} label={p} icon="person" selected={false} disabled={disabled} onClick={() => onChange(p)} />
            ))}
          </ChipGroup>
        </div>
      ) : null}
    </div>
  );
}

/** Lent to [person], with an optional due date and note. */
export function LoanDetails({
  person,
  onPerson,
  dueDate,
  onDueDate,
  note,
  onNote,
  people,
  missing,
  disabled,
}: {
  person: string;
  onPerson: (value: string) => void;
  dueDate: string | null;
  onDueDate: (value: string | null) => void;
  note: string;
  onNote: (value: string) => void;
  people: readonly string[];
  missing?: boolean;
  disabled?: boolean;
}) {
  return (
    <div>
      <PersonField label="Lent to" value={person} onChange={onPerson} people={people} missing={missing} disabled={disabled} />
      <div className={styles.pair}>
        <DatePickerField value={dueDate} onChange={onDueDate} placeholder="Due back (optional)" icon="calendar" label="Due back" clearable disabled={disabled} />
        <TextField value={note} onChange={onNote} placeholder="Note (optional)" aria-label="Note" icon="notes" maxLength={200} disabled={disabled} />
      </div>
    </div>
  );
}

/** What this pays back, and what is left after it. */
export function SettlementPicker({
  label,
  options,
  value,
  onChange,
  amount,
  currency,
  missing,
  emptyText,
  disabled,
}: {
  label: string;
  options: readonly SettleOption[];
  value: SettlementTarget | null;
  onChange: (option: SettleOption | null) => void;
  amount: number | null;
  currency: string;
  missing?: boolean;
  emptyText: string;
  disabled?: boolean;
}) {
  const key = settleKey(value);
  const chosen = options.find((o) => o.key === key);
  let status: { text: string; className?: string } | null = null;
  if (chosen && amount != null && amount > 0) {
    const left = Math.round((chosen.principal - chosen.received - amount) * 100) / 100;
    status =
      left === 0
        ? { text: 'This settles it.', className: styles.statusDone }
        : left > 0
          ? { text: `${formatCurrency(left, currency)} still owed after this.` }
          : { text: `${formatCurrency(-left, currency)} more than is owed — it will show as overpaid.`, className: styles.statusOver };
  }
  return (
    <div>
      <FieldLabel text={label} required hint={missing ? 'Choose one' : null} hintIsError={missing} />
      {options.length ? (
        <SelectField
          value={key}
          onChange={(v) => onChange(options.find((o) => o.key === v) ?? null)}
          options={options.map((o) => ({ value: o.key, label: o.label }))}
          label={label}
          icon="lend"
          placeholder="Select"
          disabled={disabled}
        />
      ) : (
        <p className={styles.status}>{emptyText}</p>
      )}
      {status ? <p className={[styles.status, status.className].filter(Boolean).join(' ')}>{status.text}</p> : null}
    </div>
  );
}

/** "Paid for someone else": the expense is owed back, so it leaves your spending. */
export function PaidForToggle({
  value,
  onChange,
  person,
  onPerson,
  people,
  missing,
  disabled,
  progress,
}: {
  value: boolean;
  onChange: (value: boolean) => void;
  person: string;
  onPerson: (value: string) => void;
  people: readonly string[];
  missing?: boolean;
  disabled?: boolean;
  /** "₹2,000 of ₹3,000 paid back" — for a purchase already marked. */
  progress?: string | null;
}) {
  return (
    <div className={styles.block}>
      <ChipGroup label="Paid for someone else">
        <Chip label="Paid for someone else" icon="lend" selected={value} disabled={disabled} onClick={() => onChange(!value)} />
      </ChipGroup>
      {value ? (
        <>
          <PersonField label="Paid for" value={person} onChange={onPerson} people={people} missing={missing} disabled={disabled} />
          <p className={styles.status} style={{ marginTop: 0 }}>
            {progress ?? 'Owed back to you — not counted as your spending.'}
          </p>
        </>
      ) : null}
    </div>
  );
}
