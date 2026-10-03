import { describe, expect, it } from 'vitest';

import { ordinal } from '@/lib/format';
import { MAX_AMOUNT } from '@/lib/validators';

import {
  buildCardStatement,
  cardPaymentDescription,
  checkCardPayment,
  cycleContaining,
  dayInMonth,
  directionForKind,
  dueDateAfter,
  dueStatusText,
  entryFromCardTransaction,
  entryFromExpense,
  entryFromPayment,
  findLinkableDebits,
  isLinkableDebit,
  matchSmsCard,
  orderEntries,
  outstandingOf,
  summariseCard,
  type CardEntry,
  type CardEntryKind,
  type CardPaymentDraft,
} from './creditCards';
import { ExportContext, expensesDataset } from './export/builder';
import {
  CARD_PAYMENT_LABEL,
  cardIssuerLine,
  cardLabel,
  cardTransactionFromRow,
  creditCardFromRow,
  expenseFromRow,
  ledgerCategoryLabel,
  ledgerTitle,
  type BankAccount,
  type CreditCard,
  type Expense,
  type LedgerEntry,
} from './models';

const card = (extra: Partial<CreditCard> = {}): CreditCard => ({
  id: 'c1',
  userId: 'u1',
  cardName: 'Regalia',
  issuer: 'HDFC Bank',
  network: 'visa',
  last4: '4821',
  creditLimit: 100_000,
  openingOutstanding: 0,
  statementDay: 15,
  paymentDueDay: 5,
  paymentAccountId: null,
  isActive: true,
  notes: null,
  createdAt: null,
  ...extra,
});

let seq = 0;
const entry = (kind: CardEntryKind, amount: number, date: string, extra: Partial<CardEntry> = {}): CardEntry => {
  seq += 1;
  const direction = kind === 'purchase' || kind === 'fee' || kind === 'interest' ? 'debit' : 'credit';
  return {
    key: `t:${String(seq).padStart(4, '0')}`,
    source: kind === 'purchase' ? 'expense' : 'card',
    id: `e${seq}`,
    cardId: 'c1',
    kind,
    direction,
    amount,
    date,
    description: null,
    category: null,
    accountId: null,
    originalExpenseId: null,
    reference: null,
    createdAt: null,
    ...extra,
  };
};
const purchase = (amount: number, date: string, extra?: Partial<CardEntry>) => entry('purchase', amount, date, extra);
const payment = (amount: number, date: string, extra?: Partial<CardEntry>) => entry('payment', amount, date, extra);

const ledger = (id: string, extra: Partial<LedgerEntry> = {}): LedgerEntry => ({
  id,
  userId: 'u1',
  accountId: 'a1',
  direction: 'debit',
  amount: 5000,
  txnDate: '2026-10-03',
  description: 'HDFC CC PAYMENT',
  categoryId: null,
  expenseId: null,
  incomeId: null,
  transferGroupId: null,
  counterpartyAccountId: null,
  creditCardId: null,
  receivableId: null,
  claim: null,
  createdAt: null,
  category: null,
  ...extra,
});

const expense = (extra: Partial<Expense> = {}): Expense => ({
  id: 'x1',
  userId: 'u1',
  amount: 1200,
  expenseDate: '2026-09-20',
  categoryId: null,
  paymentMethodId: null,
  bankAccountId: null,
  creditCardId: 'c1',
  merchant: 'Amazon',
  description: null,
  notes: null,
  createdAt: '2026-09-20T10:00:00Z',
  updatedAt: null,
  category: null,
  paymentMethod: null,
  ...extra,
});

describe('billing cycle dates', () => {
  it('clamps a day to the month', () => {
    expect(dayInMonth('2026-02-10', 31)).toBe('2026-02-28');
    expect(dayInMonth('2028-02-10', 30)).toBe('2028-02-29');
    expect(dayInMonth('2026-04-01', 31)).toBe('2026-04-30');
    expect(dayInMonth('2026-09-01', 15)).toBe('2026-09-15');
  });

  it('puts the due date on the first due day after the statement', () => {
    expect(dueDateAfter('2026-09-15', 5)).toBe('2026-10-05');
    expect(dueDateAfter('2026-09-01', 20)).toBe('2026-09-20');
    // Due on the statement day itself means the following month.
    expect(dueDateAfter('2026-09-20', 20)).toBe('2026-10-20');
    expect(dueDateAfter('2026-01-31', 31)).toBe('2026-02-28');
  });

  it('finds the cycle a date falls in, statement day inclusive', () => {
    expect(cycleContaining('2026-10-02', 15, 5)).toEqual({ start: '2026-09-16', end: '2026-10-15', dueDate: '2026-11-05' });
    expect(cycleContaining('2026-10-15', 15, 5)).toEqual({ start: '2026-09-16', end: '2026-10-15', dueDate: '2026-11-05' });
    expect(cycleContaining('2026-10-16', 15, 5)).toEqual({ start: '2026-10-16', end: '2026-11-15', dueDate: '2026-12-05' });
  });

  it('handles month-end statement days without gaps or overlaps', () => {
    expect(cycleContaining('2026-02-10', 31, 20)).toEqual({ start: '2026-02-01', end: '2026-02-28', dueDate: '2026-03-20' });
    expect(cycleContaining('2026-03-01', 31, 20)).toEqual({ start: '2026-03-01', end: '2026-03-31', dueDate: '2026-04-20' });
    expect(cycleContaining('2026-03-31', 30, 20)).toEqual({ start: '2026-03-31', end: '2026-04-30', dueDate: '2026-05-20' });
    expect(cycleContaining('2026-01-05', 1, 20)).toEqual({ start: '2026-01-02', end: '2026-02-01', dueDate: '2026-02-20' });
  });
});

describe('card entries', () => {
  it('maps a card purchase, and nothing for an expense that is not on a card', () => {
    const mapped = entryFromExpense(expense());
    expect(mapped).toMatchObject({ key: 'expense:x1', kind: 'purchase', direction: 'debit', amount: 1200, cardId: 'c1', description: 'Amazon' });
    expect(entryFromExpense(expense({ creditCardId: null, bankAccountId: 'a1' }))).toBeNull();
  });

  it('maps a bank debit that paid the card as a credit on the card', () => {
    const mapped = entryFromPayment(ledger('l1', { creditCardId: 'c1' }));
    expect(mapped).toMatchObject({ key: 'account:l1', source: 'account', kind: 'payment', direction: 'credit', accountId: 'a1' });
    expect(entryFromPayment(ledger('l2'))).toBeNull();
  });

  it('maps card-only transactions as stored', () => {
    const mapped = entryFromCardTransaction({
      id: 't1',
      userId: 'u1',
      cardId: 'c1',
      kind: 'fee',
      direction: 'debit',
      amount: 590,
      txnDate: '2026-09-16',
      description: 'Annual fee',
      reference: 'REF1',
      originalExpenseId: null,
      createdAt: null,
    });
    expect(mapped).toMatchObject({ key: 'card:t1', source: 'card', kind: 'fee', direction: 'debit', reference: 'REF1' });
  });

  it('pairs each kind with the direction the database requires', () => {
    expect(directionForKind('refund')).toBe('credit');
    expect(directionForKind('cashback')).toBe('credit');
    expect(directionForKind('payment')).toBe('credit');
    expect(directionForKind('fee')).toBe('debit');
    expect(directionForKind('interest')).toBe('debit');
    expect(directionForKind('adjustment', 'credit')).toBe('credit');
    expect(directionForKind('adjustment', 'debit')).toBe('debit');
  });

  it('orders by date, then creation time, then key', () => {
    const a = purchase(1, '2026-09-20', { key: 'b', createdAt: '2026-09-20T09:00:00Z' });
    const b = payment(1, '2026-09-20', { key: 'a', createdAt: '2026-09-20T18:00:00Z' });
    const c = purchase(1, '2026-09-19', { key: 'z' });
    expect(orderEntries([b, a, c]).map((e) => e.key)).toEqual(['z', 'b', 'a']);
  });

  it('derives the outstanding in whole cents', () => {
    expect(outstandingOf(0, [purchase(0.1, '2026-09-01'), purchase(0.2, '2026-09-02')])).toBe(0.3);
    expect(outstandingOf(1000, [purchase(500, '2026-09-01'), payment(1200, '2026-09-02')])).toBe(300);
  });
});

describe('buildCardStatement', () => {
  const history = [
    purchase(2000, '2026-08-20'),
    purchase(1000, '2026-09-01'),
    payment(2000, '2026-09-05'),
    entry('fee', 500, '2026-09-10'),
    purchase(300, '2026-09-20'),
    entry('refund', 100, '2026-09-25'),
  ];

  it('walks the whole history from the opening outstanding', () => {
    const statement = buildCardStatement({ openingOutstanding: 500, entries: history });
    expect(statement.opening).toBe(500);
    expect(statement.closing).toBe(2200);
    expect(statement.rows.map((r) => r.outstandingAfter)).toEqual([2200, 2300, 2000, 1500, 3500, 2500]);
  });

  it('carries earlier history into a cycle and stops at its end', () => {
    const statement = buildCardStatement({ openingOutstanding: 500, entries: history, from: '2026-08-16', to: '2026-09-15' });
    expect(statement.opening).toBe(500);
    expect(statement.rows).toHaveLength(4);
    expect(statement.closing).toBe(2000);
    expect(statement).toMatchObject({ purchases: 3000, payments: 2000, charges: 500, credits: 0 });

    const next = buildCardStatement({ openingOutstanding: 500, entries: history, from: '2026-09-16', to: '2026-10-15' });
    expect(next.opening).toBe(2000);
    expect(next.closing).toBe(2200);
    expect(next).toMatchObject({ purchases: 300, credits: 100, payments: 0, charges: 0 });
  });

  it('filters after the walk, so running figures stay right', () => {
    const charges = buildCardStatement({ openingOutstanding: 0, entries: history, filter: 'charges' });
    expect(charges.rows.map((r) => r.entry.kind)).toEqual(['purchase', 'fee', 'purchase', 'purchase']);
    expect(charges.rows[0]?.outstandingAfter).toBe(1800);
    expect(charges.closing).toBe(1700);
    expect(charges.payments).toBe(0);
    const credits = buildCardStatement({ openingOutstanding: 0, entries: history, filter: 'credits' });
    expect(credits.rows.map((r) => r.entry.kind)).toEqual(['refund', 'payment']);
  });
});

describe('summariseCard', () => {
  const c = card({ openingOutstanding: 0 });

  it('reports the bill on the last statement and what is left to pay', () => {
    const entries = [purchase(4000, '2026-09-01'), purchase(1000, '2026-09-20'), payment(1500, '2026-09-25')];
    const summary = summariseCard(c, entries, '2026-10-02');
    expect(summary.outstanding).toBe(3500);
    expect(summary.available).toBe(96_500);
    expect(summary.utilisation).toBeCloseTo(0.035);
    expect(summary.currentCycle).toEqual({ start: '2026-09-16', end: '2026-10-15', dueDate: '2026-11-05' });
    expect(summary.unbilled).toBe(1000);
    expect(summary.lastStatement).toMatchObject({ balance: 4000, credited: 1500, remaining: 2500, status: 'due', daysToDue: 3 });
    expect(summary.lastStatement.cycle).toEqual({ start: '2026-08-16', end: '2026-09-15', dueDate: '2026-10-05' });
    expect(dueStatusText(summary.lastStatement)).toBe('Due in 3 days');
  });

  it('is paid once credits after the statement cover it, and overdue after the due date otherwise', () => {
    const entries = [purchase(4000, '2026-09-01')];
    expect(summariseCard(c, [...entries, payment(4000, '2026-10-01')], '2026-10-02').lastStatement.status).toBe('paid');
    const late = summariseCard(c, [...entries, payment(1000, '2026-10-01')], '2026-10-07');
    expect(late.lastStatement).toMatchObject({ remaining: 3000, status: 'overdue', daysToDue: -2 });
    expect(dueStatusText(late.lastStatement)).toBe('Overdue by 2 days');
    expect(dueStatusText(summariseCard(c, entries, '2026-10-05').lastStatement)).toBe('Due today');
  });

  it('counts the opening outstanding as already billed', () => {
    const summary = summariseCard(card({ openingOutstanding: 12_000 }), [], '2026-10-02');
    expect(summary.lastStatement).toMatchObject({ balance: 12_000, remaining: 12_000, status: 'due' });
    expect(summary.outstanding).toBe(12_000);
  });

  it('has nothing due without a billed balance, including a credit balance', () => {
    expect(summariseCard(c, [purchase(900, '2026-09-20')], '2026-10-02').lastStatement.status).toBe('nothingDue');
    const credit = summariseCard(c, [purchase(100, '2026-09-01'), payment(300, '2026-09-02')], '2026-10-02');
    expect(credit.outstanding).toBe(-200);
    expect(credit.lastStatement.status).toBe('nothingDue');
    expect(credit.utilisation).toBe(0);
    expect(credit.available).toBe(100_200);
  });

  it('reports how far a card is over its limit', () => {
    const summary = summariseCard(card({ creditLimit: 1000 }), [purchase(1250, '2026-09-20')], '2026-10-02');
    expect(summary.available).toBe(0);
    expect(summary.overLimit).toBe(250);
    expect(summary.utilisation).toBe(1.25);
  });

  it('ignores other cards’ entries', () => {
    const summary = summariseCard(c, [purchase(500, '2026-09-20', { cardId: 'other' })], '2026-10-02');
    expect(summary.outstanding).toBe(0);
  });
});

describe('bill payment', () => {
  const draft = (extra: Partial<CardPaymentDraft> = {}): CardPaymentDraft => ({
    cardId: 'c1',
    source: { kind: 'account', accountId: 'a1' },
    amount: 5000,
    date: '2026-10-03',
    ...extra,
  });

  it('checks shape first, then funds in whole cents', () => {
    expect(checkCardPayment(draft({ cardId: null }), null)).toBe('noCard');
    expect(checkCardPayment(draft({ source: null }), null)).toBe('noSource');
    expect(checkCardPayment(draft({ amount: 0 }), null)).toBe('invalidAmount');
    expect(checkCardPayment(draft({ amount: Number.NaN }), null)).toBe('invalidAmount');
    expect(checkCardPayment(draft({ amount: MAX_AMOUNT + 1 }), null)).toBe('amountTooLarge');
    expect(checkCardPayment(draft(), 4999.99)).toBe('insufficientFunds');
    expect(checkCardPayment(draft({ amount: 0.3 }), 0.1 + 0.2)).toBeNull();
    expect(checkCardPayment(draft(), null)).toBeNull();
  });

  it('never checks a balance for cash', () => {
    expect(checkCardPayment(draft({ source: { kind: 'cash' } }), 0)).toBeNull();
  });

  it('describes the payment by the note, else by the card', () => {
    expect(cardPaymentDescription(card(), '  October bill ')).toBe('October bill');
    expect(cardPaymentDescription(card(), null)).toBe('Regalia •••• 4821 bill payment');
  });
});

describe('reconciliation with the bank ledger', () => {
  it('only plain, unlinked debits can become a payment', () => {
    expect(isLinkableDebit(ledger('a'))).toBe(true);
    expect(isLinkableDebit(ledger('b', { direction: 'credit' }))).toBe(false);
    expect(isLinkableDebit(ledger('c', { expenseId: 'x' }))).toBe(false);
    expect(isLinkableDebit(ledger('d', { incomeId: 'i' }))).toBe(false);
    expect(isLinkableDebit(ledger('e', { transferGroupId: 'g' }))).toBe(false);
    expect(isLinkableDebit(ledger('f', { creditCardId: 'c1' }))).toBe(false);
  });

  it('finds same-amount debits nearby, closest first', () => {
    const entries = [
      ledger('far', { txnDate: '2026-10-08' }),
      ledger('two', { txnDate: '2026-10-05' }),
      ledger('same', { txnDate: '2026-10-03' }),
      ledger('other', { amount: 5000.01 }),
      ledger('linked', { creditCardId: 'c2' }),
    ];
    expect(findLinkableDebits(entries, 5000, '2026-10-03').map((e) => e.id)).toEqual(['same', 'two']);
  });

  it('labels a card payment on the bank statement', () => {
    const paid = ledger('p', { creditCardId: 'c1', description: null });
    expect(ledgerCategoryLabel(paid)).toBe(CARD_PAYMENT_LABEL);
    expect(ledgerTitle(paid)).toBe(CARD_PAYMENT_LABEL);
  });
});

describe('matching a bank SMS to a card', () => {
  const account = (last4: string | null): BankAccount => ({
    id: 'a1',
    userId: 'u1',
    bankName: 'HDFC Bank',
    nickname: 'Salary',
    last4,
    openingBalance: 0,
    isActive: true,
    createdAt: null,
  });
  const cards = [card(), card({ id: 'c2', last4: '1111' })];

  it('matches the one active card ending in the digits', () => {
    expect(matchSmsCard({ text: 'Rs 500 spent on card xx4821', last4: '4821', cards, accounts: [account('6459')] })?.id).toBe('c1');
  });

  it('defers to a bank account with the same digits unless the message says credit card', () => {
    expect(matchSmsCard({ text: 'Rs 500 debited from a/c xx4821', last4: '4821', cards, accounts: [account('4821')] })).toBeNull();
    expect(matchSmsCard({ text: 'Rs 500 spent on HDFC Bank Credit Card xx4821', last4: '4821', cards, accounts: [account('4821')] })?.id).toBe('c1');
  });

  it('never guesses', () => {
    expect(matchSmsCard({ text: 'credit card', last4: null, cards, accounts: [] })).toBeNull();
    expect(matchSmsCard({ text: 'credit card', last4: '4821', cards: [card(), card({ id: 'c3' })], accounts: [] })).toBeNull();
    expect(matchSmsCard({ text: 'credit card', last4: '4821', cards: [card({ isActive: false })], accounts: [] })).toBeNull();
  });
});

describe('row mappers and labels', () => {
  it('reads a card defensively', () => {
    const parsed = creditCardFromRow({
      id: 'c1',
      user_id: 'u1',
      card_name: 'Millennia',
      issuer: 'HDFC Bank',
      network: 'unknown-network',
      last4: '0042',
      credit_limit: '150000.00',
      opening_outstanding: '-250.50',
      statement_day: 40,
      payment_due_day: 7,
      payment_account_id: 'a1',
      is_active: false,
    });
    expect(parsed).toMatchObject({
      network: null,
      creditLimit: 150_000,
      openingOutstanding: -250.5,
      statementDay: 1,
      paymentDueDay: 7,
      paymentAccountId: 'a1',
      isActive: false,
    });
  });

  it('reads a card transaction and an expense’s card', () => {
    expect(cardTransactionFromRow({ id: 't', card_id: 'c1', kind: 'interest', direction: 'debit', amount: 12.5, txn_date: '2026-09-15T00:00:00' })).toMatchObject({
      kind: 'interest',
      direction: 'debit',
      amount: 12.5,
      txnDate: '2026-09-15',
    });
    expect(expenseFromRow({ id: 'x', amount: 1, expense_date: '2026-09-01', credit_card_id: 'c1' }).creditCardId).toBe('c1');
    expect(expenseFromRow({ id: 'x', amount: 1, expense_date: '2026-09-01' }).creditCardId).toBeNull();
  });

  it('labels cards and ordinals', () => {
    expect(cardLabel(card())).toBe('Regalia •••• 4821');
    expect(cardLabel(card({ last4: null }))).toBe('Regalia');
    expect(cardIssuerLine(card())).toBe('HDFC Bank · Visa •••• 4821');
    expect(cardIssuerLine(card({ network: null, last4: null }))).toBe('HDFC Bank');
    expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 31].map(ordinal)).toEqual(['1st', '2nd', '3rd', '4th', '11th', '12th', '13th', '21st', '22nd', '23rd', '31st']);
  });
});

describe('export', () => {
  it('names the card a purchase was paid with, apart from cash and accounts', () => {
    const context = new ExportContext('INR', [], [], [], [card()]);
    const dataset = expensesDataset({
      expenses: [expense(), expense({ id: 'x2', creditCardId: null })],
      range: { start: '2026-09-01', endInclusive: '2026-09-30' },
      context,
    });
    const paidFrom = dataset.sections[0]?.rows.map((row) => row[4]?.text);
    expect(paidFrom).toEqual(['Regalia •••• 4821', 'Cash']);
  });
});
