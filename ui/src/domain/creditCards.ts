/**
 * Credit cards: billing cycles, the card statement and its summary figures.
 * Pure, so every rule here is unit-tested.
 *
 * A card's movements live where the rest of the app already keeps them, each
 * stored exactly once:
 *   purchase      an expense with creditCardId — spending, like any expense
 *   bill payment  a bank ledger debit with creditCardId (from an account), or
 *                 a card transaction of kind 'payment' (cash)
 *   refund, cashback, fee, interest, adjustment — a card transaction
 * They are merged here into one list of CardEntry, seen from the card's
 * side: 'debit' raises the outstanding, 'credit' lowers it.
 */
import { addDays, addMonths, daysBetween, fromParts, parts, type IsoDate } from '@/lib/dates';
import { dayMonth, formatCurrency } from '@/lib/format';
import { MAX_AMOUNT } from '@/lib/validators';

import {
  cardLabel,
  expenseTitle,
  type BankAccount,
  type CardTransaction,
  type CardTransactionKind,
  type CreditCard,
  type Expense,
  type ExpenseCategory,
  type LedgerDirection,
  type LedgerEntry,
} from './models';

// ---------------------------------------------------------------------------
// Entries
// ---------------------------------------------------------------------------

export type CardEntryKind = 'purchase' | CardTransactionKind;

/** Which table the movement lives in — and therefore where it is edited. */
export type CardEntrySource = 'expense' | 'card' | 'account';

export type CardEntry = {
  /** Unique across the three sources. */
  key: string;
  source: CardEntrySource;
  /** The row's id in its own table. */
  id: string;
  cardId: string;
  kind: CardEntryKind;
  direction: LedgerDirection;
  amount: number;
  date: IsoDate;
  description: string | null;
  category: ExpenseCategory | null;
  /** The bank account a bill payment came from; null for cash and everything else. */
  accountId: string | null;
  originalExpenseId: string | null;
  reference: string | null;
  createdAt: string | null;
};

export const CARD_KIND_LABELS: Record<CardEntryKind, string> = {
  purchase: 'Purchase',
  refund: 'Refund',
  cashback: 'Cashback',
  payment: 'Bill payment',
  fee: 'Fee',
  interest: 'Interest',
  adjustment: 'Adjustment',
};

/** What the "add a card transaction" sheet offers. Payments have their own sheet. */
export const CARD_TRANSACTION_KINDS: ReadonlyArray<{
  kind: Exclude<CardTransactionKind, 'payment'>;
  label: string;
  /** Fixed by the kind; null lets the user choose (adjustment). */
  direction: LedgerDirection | null;
  hint: string;
}> = [
  { kind: 'refund', label: 'Refund', direction: 'credit', hint: 'Money returned for a purchase' },
  { kind: 'cashback', label: 'Cashback', direction: 'credit', hint: 'Rewards or cashback credited to the card' },
  { kind: 'fee', label: 'Fee', direction: 'debit', hint: 'Annual fee, late fee, GST on charges' },
  { kind: 'interest', label: 'Interest', direction: 'debit', hint: 'Finance charges on a carried balance' },
  { kind: 'adjustment', label: 'Adjustment', direction: null, hint: 'Correct the outstanding either way' },
];

/** The direction a card transaction must have; the database enforces the same pairs. */
export function directionForKind(kind: CardTransactionKind, adjustment: LedgerDirection = 'debit'): LedgerDirection {
  switch (kind) {
    case 'refund':
    case 'cashback':
    case 'payment':
      return 'credit';
    case 'fee':
    case 'interest':
      return 'debit';
    case 'adjustment':
      return adjustment;
  }
}

export function entryFromExpense(expense: Expense): CardEntry | null {
  if (expense.creditCardId == null) return null;
  return {
    key: `expense:${expense.id}`,
    source: 'expense',
    id: expense.id,
    cardId: expense.creditCardId,
    kind: 'purchase',
    direction: 'debit',
    amount: expense.amount,
    date: expense.expenseDate,
    description: expenseTitle(expense),
    category: expense.category,
    accountId: null,
    originalExpenseId: null,
    reference: null,
    createdAt: expense.createdAt,
  };
}

export function entryFromCardTransaction(transaction: CardTransaction): CardEntry {
  return {
    key: `card:${transaction.id}`,
    source: 'card',
    id: transaction.id,
    cardId: transaction.cardId,
    kind: transaction.kind,
    direction: transaction.direction,
    amount: transaction.amount,
    date: transaction.txnDate,
    description: transaction.description,
    category: null,
    accountId: null,
    originalExpenseId: transaction.originalExpenseId,
    reference: transaction.reference,
    createdAt: transaction.createdAt,
  };
}

/** A bank debit that paid the card: the same row that lowered the bank balance. */
export function entryFromPayment(entry: LedgerEntry): CardEntry | null {
  if (entry.creditCardId == null || entry.direction !== 'debit') return null;
  return {
    key: `account:${entry.id}`,
    source: 'account',
    id: entry.id,
    cardId: entry.creditCardId,
    kind: 'payment',
    direction: 'credit',
    amount: entry.amount,
    date: entry.txnDate,
    description: entry.description,
    category: null,
    accountId: entry.accountId,
    originalExpenseId: null,
    reference: null,
    createdAt: entry.createdAt,
  };
}

export function cardEntryTitle(entry: CardEntry): string {
  const text = entry.description?.trim();
  return text ? text : CARD_KIND_LABELS[entry.kind];
}

const cents = (value: number) => Math.round(value * 100);
const roundCents = (value: number) => cents(value) / 100;

/** What the entry does to the outstanding. */
export const outstandingDelta = (entry: Pick<CardEntry, 'direction' | 'amount'>) =>
  entry.direction === 'debit' ? entry.amount : -entry.amount;

/**
 * Oldest first. Same-day movements fall back to insertion order, then to the
 * key, so a running figure is stable across reloads (as `buildStatement`).
 */
export function orderEntries(entries: readonly CardEntry[]): CardEntry[] {
  return [...entries].sort((a, b) => {
    if (a.date !== b.date) return a.date < b.date ? -1 : 1;
    const byCreated = Date.parse(a.createdAt ?? '1970-01-01T00:00:00Z') - Date.parse(b.createdAt ?? '1970-01-01T00:00:00Z');
    if (byCreated !== 0 && Number.isFinite(byCreated)) return byCreated;
    return a.key < b.key ? -1 : a.key > b.key ? 1 : 0;
  });
}

/** Opening outstanding plus every entry, summed in whole cents so long histories cannot drift. */
export function outstandingOf(openingOutstanding: number, entries: readonly CardEntry[]): number {
  return entries.reduce((sum, entry) => sum + cents(outstandingDelta(entry)), cents(openingOutstanding)) / 100;
}

const sumCents = (entries: readonly CardEntry[]) => entries.reduce((sum, e) => sum + cents(e.amount), 0) / 100;

// ---------------------------------------------------------------------------
// Billing cycles
// ---------------------------------------------------------------------------

export type BillingCycle = {
  /** First day of the cycle. */
  start: IsoDate;
  /** The statement date: the cycle's last day. */
  end: IsoDate;
  dueDate: IsoDate;
};

const daysInMonth = (year: number, month: number) => new Date(year, month, 0).getDate();

/** Day [day] of [anchor]'s month, clamped to that month's length (31 → 28 Feb). */
export function dayInMonth(anchor: IsoDate, day: number): IsoDate {
  const { year, month } = parts(anchor);
  return fromParts(year, month, Math.min(Math.max(1, Math.trunc(day)), daysInMonth(year, month)));
}

/** The first [dueDay] strictly after the statement date. */
export function dueDateAfter(statementDate: IsoDate, dueDay: number): IsoDate {
  const sameMonth = dayInMonth(statementDate, dueDay);
  return sameMonth > statementDate ? sameMonth : dayInMonth(addMonths(statementDate, 1), dueDay);
}

/** The billing cycle that [date] falls in. */
export function cycleContaining(date: IsoDate, statementDay: number, dueDay: number): BillingCycle {
  const closesThisMonth = dayInMonth(date, statementDay);
  const end = date <= closesThisMonth ? closesThisMonth : dayInMonth(addMonths(date, 1), statementDay);
  const start = addDays(dayInMonth(addMonths(end, -1), statementDay), 1);
  return { start, end, dueDate: dueDateAfter(end, dueDay) };
}

export const cardCycleContaining = (card: Pick<CreditCard, 'statementDay' | 'paymentDueDay'>, date: IsoDate) =>
  cycleContaining(date, card.statementDay, card.paymentDueDay);

// ---------------------------------------------------------------------------
// Statement
// ---------------------------------------------------------------------------

export type CardStatementFilter = 'all' | 'charges' | 'credits';

export const CARD_STATEMENT_FILTERS: ReadonlyArray<{ value: CardStatementFilter; label: string }> = [
  { value: 'all', label: 'All' },
  { value: 'charges', label: 'Charges' },
  { value: 'credits', label: 'Payments & credits' },
];

export type CardStatementRow = {
  entry: CardEntry;
  /** Outstanding immediately after [entry]. */
  outstandingAfter: number;
};

export type CardStatement = {
  /** Outstanding carried into the period. */
  opening: number;
  /** Outstanding at the end of the period, whatever the filter. */
  closing: number;
  /** Newest first. */
  rows: CardStatementRow[];
  purchases: number;
  /** Fees, interest and debit adjustments. */
  charges: number;
  payments: number;
  /** Refunds, cashback and credit adjustments. */
  credits: number;
};

/**
 * Walks every entry oldest-first from the opening outstanding, so a period's
 * opening figure includes all earlier history. [from]/[to] bound the rows
 * shown (inclusive); the filter is applied after the walk so it never
 * corrupts the running figure, and the totals describe the rows shown.
 */
export function buildCardStatement({
  openingOutstanding,
  entries,
  from = null,
  to = null,
  filter = 'all',
}: {
  openingOutstanding: number;
  entries: readonly CardEntry[];
  from?: IsoDate | null;
  to?: IsoDate | null;
  filter?: CardStatementFilter;
}): CardStatement {
  // Whole cents throughout: thousands of decimal amounts must not drift.
  let running = cents(openingOutstanding);
  let opening = running;
  const rows: CardStatementRow[] = [];
  for (const entry of orderEntries(entries)) {
    if (to != null && entry.date > to) break;
    running += cents(outstandingDelta(entry));
    if (from != null && entry.date < from) {
      opening = running;
      continue;
    }
    const shown = filter === 'all' || (filter === 'charges' ? entry.direction === 'debit' : entry.direction === 'credit');
    if (shown) rows.push({ entry, outstandingAfter: running / 100 });
  }

  const shownEntries = rows.map((r) => r.entry);
  return {
    opening: opening / 100,
    closing: running / 100,
    rows: rows.reverse(),
    purchases: sumCents(shownEntries.filter((e) => e.kind === 'purchase')),
    payments: sumCents(shownEntries.filter((e) => e.kind === 'payment')),
    charges: sumCents(shownEntries.filter((e) => e.kind !== 'purchase' && e.kind !== 'payment' && e.direction === 'debit')),
    credits: sumCents(shownEntries.filter((e) => e.kind !== 'purchase' && e.kind !== 'payment' && e.direction === 'credit')),
  };
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

export type DueStatus = 'nothingDue' | 'paid' | 'due' | 'overdue';

export type StatementDue = {
  /** The last closed cycle. */
  cycle: BillingCycle;
  /** Outstanding on the statement date — the bill. */
  balance: number;
  /** Payments and other credits dated after the statement date. */
  credited: number;
  /** What is still to pay for that bill. */
  remaining: number;
  status: DueStatus;
  /** Days from today to the due date; negative once it has passed. */
  daysToDue: number;
};

export type CardSummary = {
  outstanding: number;
  /** Limit minus outstanding, never below zero. */
  available: number;
  /** How far the outstanding is past the limit; 0 when within it. */
  overLimit: number;
  /** Outstanding as a share of the limit (0 with no limit or a credit balance). */
  utilisation: number;
  /** The open cycle, closing on the next statement date. */
  currentCycle: BillingCycle;
  /** Charges dated in the open cycle — not yet on a statement. */
  unbilled: number;
  lastStatement: StatementDue;
};

/**
 * The card's headline figures on [today]. The opening outstanding counts as
 * billed before tracking began, so a card added mid-cycle shows it as due on
 * the last statement until a payment covers it.
 */
export function summariseCard(card: CreditCard, entries: readonly CardEntry[], today: IsoDate): CardSummary {
  const own = entries.filter((e) => e.cardId === card.id);
  const outstanding = outstandingOf(card.openingOutstanding, own);
  const limit = card.creditLimit > 0 ? card.creditLimit : 0;

  const currentCycle = cardCycleContaining(card, today);
  const unbilled = sumCents(own.filter((e) => e.direction === 'debit' && e.date >= currentCycle.start && e.date <= currentCycle.end));

  const cycle = cardCycleContaining(card, addDays(currentCycle.start, -1));
  const balance = outstandingOf(card.openingOutstanding, own.filter((e) => e.date <= cycle.end));
  const credited = sumCents(own.filter((e) => e.direction === 'credit' && e.date > cycle.end));
  const remaining = balance > 0 ? Math.max(0, roundCents(balance - credited)) : 0;
  let status: DueStatus;
  if (cents(balance) <= 0) status = 'nothingDue';
  else if (cents(remaining) <= 0) status = 'paid';
  else status = today > cycle.dueDate ? 'overdue' : 'due';

  return {
    outstanding,
    available: limit ? Math.max(0, roundCents(limit - outstanding)) : 0,
    overLimit: limit ? Math.max(0, roundCents(outstanding - limit)) : 0,
    utilisation: limit && outstanding > 0 ? outstanding / limit : 0,
    currentCycle,
    unbilled,
    lastStatement: { cycle, balance, credited, remaining, status, daysToDue: daysBetween(today, cycle.dueDate) },
  };
}

/** "Due in 3 days", "Due today", "Overdue by 2 days", "Paid", "Nothing due". */
export function dueStatusText(due: StatementDue): string {
  switch (due.status) {
    case 'nothingDue':
      return 'Nothing due';
    case 'paid':
      return 'Paid';
    case 'overdue': {
      const days = -due.daysToDue;
      return `Overdue by ${days} ${days === 1 ? 'day' : 'days'}`;
    }
    case 'due':
      if (due.daysToDue === 0) return 'Due today';
      return `Due in ${due.daysToDue} ${due.daysToDue === 1 ? 'day' : 'days'}`;
  }
}

/** One line on the bill: what is due and when, or that it is paid. */
export function dueSummaryText(summary: CardSummary, currency: string): string {
  const due = summary.lastStatement;
  switch (due.status) {
    case 'due':
      return `${formatCurrency(due.remaining, currency)} due ${dayMonth(due.cycle.dueDate)}`;
    case 'overdue':
      return `${formatCurrency(due.remaining, currency)} was due ${dayMonth(due.cycle.dueDate)}`;
    case 'paid':
      return `${dayMonth(due.cycle.end)} statement paid`;
    case 'nothingDue':
      return `No bill due · next statement ${dayMonth(summary.currentCycle.end)}`;
  }
}

// ---------------------------------------------------------------------------
// Bill payment
// ---------------------------------------------------------------------------

/** Where a bill payment comes from: a tracked bank account, or cash (no account). */
export type PaymentSource = { kind: 'account'; accountId: string } | { kind: 'cash' };

export type CardPaymentDraft = {
  cardId: string | null;
  source: PaymentSource | null;
  amount: number | null;
  date: IsoDate;
  note?: string | null;
};

export type CardPaymentProblem = 'noCard' | 'noSource' | 'invalidAmount' | 'amountTooLarge' | 'insufficientFunds';

export function cardPaymentProblemMessage(
  problem: CardPaymentProblem,
  { sourceLabel, availableText }: { sourceLabel?: string; availableText?: string } = {},
): string {
  switch (problem) {
    case 'noCard':
      return 'Choose the card you are paying.';
    case 'noSource':
      return 'Choose where the payment comes from.';
    case 'invalidAmount':
      return 'Enter an amount greater than 0.';
    case 'amountTooLarge':
      return 'That amount is too large.';
    case 'insufficientFunds':
      return availableText == null
        ? `Not enough money in ${sourceLabel ?? 'that account'}.`
        : `${sourceLabel ?? 'That account'} only has ${availableText} available.`;
  }
}

/**
 * Validates a bill payment. [availableBalance] is the paying account's balance
 * (null for cash, or to check only the rules that need no balance), compared
 * in whole cents as transfers are. Paying more than the outstanding is allowed:
 * it leaves a credit balance on the card, as a real overpayment does.
 */
export function checkCardPayment(draft: CardPaymentDraft, availableBalance: number | null): CardPaymentProblem | null {
  if (!draft.cardId) return 'noCard';
  if (!draft.source) return 'noSource';
  const { amount } = draft;
  if (amount == null || Number.isNaN(amount) || amount <= 0) return 'invalidAmount';
  if (amount > MAX_AMOUNT) return 'amountTooLarge';
  if (draft.source.kind === 'account' && availableBalance != null && Number.isFinite(availableBalance) && cents(amount) > cents(availableBalance)) {
    return 'insufficientFunds';
  }
  return null;
}

/** The description stored on the payment: the user's note, else one that names the card. */
export function cardPaymentDescription(card: CreditCard, note: string | null | undefined): string {
  const text = note?.trim();
  return text ? text : `${cardLabel(card)} bill payment`;
}

// ---------------------------------------------------------------------------
// Reconciliation with the bank ledger
// ---------------------------------------------------------------------------

/**
 * A bank debit that can be recognised as a bill payment: entered by hand or
 * imported from a statement — not an expense, income or transfer leg, and
 * not already linked to a card.
 */
export function isLinkableDebit(entry: LedgerEntry): boolean {
  return (
    entry.direction === 'debit' &&
    entry.expenseId == null &&
    entry.incomeId == null &&
    entry.transferGroupId == null &&
    entry.creditCardId == null &&
    // Money lent stays money lent; change it from its edit sheet instead.
    entry.claim == null
  );
}

export const PAYMENT_MATCH_DAYS = 3;

/**
 * Unlinked debits of exactly [amount] within [nearbyDays] of [date], closest
 * first: the payment may already be on the account (imported from a
 * statement), in which case linking it avoids debiting the account twice.
 */
export function findLinkableDebits(
  entries: readonly LedgerEntry[],
  amount: number,
  date: IsoDate,
  nearbyDays = PAYMENT_MATCH_DAYS,
): LedgerEntry[] {
  const wanted = cents(amount);
  return entries
    .filter((e) => isLinkableDebit(e) && cents(e.amount) === wanted && Math.abs(daysBetween(e.txnDate, date)) <= nearbyDays)
    .sort((a, b) => Math.abs(daysBetween(a.txnDate, date)) - Math.abs(daysBetween(b.txnDate, date)) || (a.txnDate < b.txnDate ? -1 : 1));
}

/**
 * Expense-backed debits of exactly [amount] near [date]. If a bill payment was
 * imported or typed as an expense, recording the payment again would debit the
 * account twice and count the bill as spending — so the user is warned.
 */
export function findExpenseDebits(
  entries: readonly LedgerEntry[],
  amount: number,
  date: IsoDate,
  nearbyDays = PAYMENT_MATCH_DAYS,
): LedgerEntry[] {
  const wanted = cents(amount);
  return entries.filter(
    (e) => e.direction === 'debit' && e.expenseId != null && cents(e.amount) === wanted && Math.abs(daysBetween(e.txnDate, date)) <= nearbyDays,
  );
}

// ---------------------------------------------------------------------------
// Bank SMS
// ---------------------------------------------------------------------------

const lastDigits = (raw: string | null | undefined) => {
  const digits = (raw ?? '').replace(/\D/g, '');
  return digits.length < 4 ? null : digits.slice(-4);
};

const BILL_PAYMENT_WORDING =
  /\b(credit ?card|cc)\b[^.]*\b(payment|pymt|bill|dues?|repayment)\b|\bcard ?bill\b|\btowards\b[^.]*\b(credit ?card|cc)\b/i;

/**
 * A bank alert that reads like paying a card bill rather than spending. Such
 * a debit is not an expense — the card purchases already are — so the review
 * screen warns instead of quietly counting it twice.
 */
export function looksLikeCardBillPayment(text: string): boolean {
  return BILL_PAYMENT_WORDING.test(text);
}

/**
 * The card a spend alert is about. Only digits identify a card: the one
 * active card ending in them, when the message says "credit card" or no bank
 * account ends in the same digits. Never guesses between candidates.
 */
export function matchSmsCard({
  text,
  last4,
  cards,
  accounts,
}: {
  text: string;
  last4: string | null;
  cards: readonly CreditCard[];
  accounts: readonly BankAccount[];
}): CreditCard | null {
  if (last4 == null) return null;
  const hits = cards.filter((c) => c.isActive && lastDigits(c.last4) === last4);
  const [only] = hits;
  if (hits.length !== 1 || !only) return null;
  const saysCreditCard = /\bcredit\s*card\b/i.test(text);
  const bankHasDigits = accounts.some((a) => a.isActive && lastDigits(a.last4) === last4);
  return saysCreditCard || !bankHasDigits ? only : null;
}
