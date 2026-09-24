/**
 * Parity tests: ported from `mobile/test/ledger_test.dart` and
 * `mobile/test/transfer_test.dart`.
 */
import { describe, expect, it } from 'vitest';

import { MAX_AMOUNT } from '@/lib/validators';

import { buildBudgetProgress, budgetAlerts, buildCategoryBreakdown } from './analytics';
import { ledgerCategoryLabel, MONEY_TRANSFER_LABEL, signedAmount, type Expense, type LedgerEntry } from './models';
import { buildStatement, closingBalance } from './statement';
import { checkTransfer, transferDescription, transferProblemMessage, type TransferDraft, type TransferProblem } from './transfer';

const entry = (id: string, direction: 'debit' | 'credit', amount: number, date: string, created?: string): LedgerEntry => ({
  id,
  userId: 'u1',
  accountId: 'a1',
  direction,
  amount,
  txnDate: date,
  description: null,
  categoryId: null,
  expenseId: null,
  incomeId: null,
  transferGroupId: null,
  counterpartyAccountId: null,
  createdAt: created ?? null,
  category: null,
});
const credit = (id: string, amount: number, date: string, created?: string) => entry(id, 'credit', amount, date, created);
const debit = (id: string, amount: number, date: string, created?: string) => entry(id, 'debit', amount, date, created);

describe('buildStatement running balance', () => {
  it('walks oldest-first and returns newest-first', () => {
    const statement = buildStatement({
      openingBalance: 1000,
      entries: [debit('d1', 200, '2025-03-05'), credit('c1', 500, '2025-03-10'), debit('d2', 100, '2025-03-15')],
    });
    expect(statement.rows.map((r) => r.entry.id)).toEqual(['d2', 'c1', 'd1']);
    expect(statement.rows.map((r) => r.balanceAfter)).toEqual([1200, 1300, 800]);
  });

  it('unsorted input still produces a correct walk', () => {
    const statement = buildStatement({
      openingBalance: 0,
      entries: [debit('d2', 100, '2025-03-15'), debit('d1', 200, '2025-03-05'), credit('c1', 500, '2025-03-10')],
    });
    expect(statement.rows.at(-1)?.balanceAfter).toBe(-200);
    expect(statement.rows[0]?.balanceAfter).toBe(200);
  });

  it('same-day entries order by creation time, not id', () => {
    const statement = buildStatement({
      openingBalance: 100,
      entries: [
        credit('zzz', 50, '2025-03-07', '2025-03-07T09:00:00Z'),
        debit('aaa', 30, '2025-03-07', '2025-03-07T18:00:00Z'),
      ],
    });
    expect(statement.rows.at(-1)?.entry.id).toBe('zzz');
    expect(statement.rows.at(-1)?.balanceAfter).toBe(150);
    expect(statement.rows[0]?.balanceAfter).toBe(120);
  });

  it('handles an empty period', () => {
    const statement = buildStatement({ openingBalance: 750, entries: [] });
    expect(statement.rows).toHaveLength(0);
    expect(closingBalance(statement)).toBe(750);
  });

  it('totals and closing balance reconcile; negatives are kept', () => {
    const statement = buildStatement({
      openingBalance: 1000,
      entries: [credit('c1', 2000, '2025-03-01'), debit('d1', 300, '2025-03-02'), debit('d2', 700, '2025-03-03')],
    });
    expect(statement.totalCredits).toBe(2000);
    expect(statement.totalDebits).toBe(1000);
    expect(closingBalance(statement)).toBe(2000);
    expect(closingBalance(statement)).toBe(statement.rows[0]?.balanceAfter);
    expect(closingBalance(buildStatement({ openingBalance: 100, entries: [debit('d1', 400, '2025-03-01')] }))).toBe(-300);
  });
});

describe('buildStatement type filter', () => {
  const entries = [debit('d1', 200, '2025-03-05'), credit('c1', 500, '2025-03-10'), debit('d2', 100, '2025-03-15')];

  it('filtering to debits keeps balances from the full walk', () => {
    const statement = buildStatement({ openingBalance: 1000, entries, typeFilter: 'debits' });
    expect(statement.rows.map((r) => [r.entry.id, r.balanceAfter])).toEqual([
      ['d2', 1200],
      ['d1', 800],
    ]);
    expect(statement.totalDebits).toBe(300);
    expect(statement.totalCredits).toBe(0);
  });

  it('credits-only filter', () => {
    const statement = buildStatement({ openingBalance: 1000, entries, typeFilter: 'credits' });
    expect(statement.rows.map((r) => [r.entry.id, r.balanceAfter])).toEqual([['c1', 1300]]);
    expect(statement.totalCredits).toBe(500);
  });
});

describe('transfer validation', () => {
  const draft = (overrides: Partial<TransferDraft> = {}): TransferDraft => ({
    fromAccountId: 'acc-a',
    toAccountId: 'acc-b',
    amount: 5000,
    date: '2025-03-10',
    ...overrides,
  });

  it('accepts a well-formed transfer and rejects the same account', () => {
    expect(checkTransfer(draft(), 25000)).toBeNull();
    expect(checkTransfer(draft({ toAccountId: 'acc-a' }), 999999)).toBe('sameAccount');
  });

  it('compares balances in whole cents', () => {
    expect(checkTransfer(draft({ amount: 10000 }), 9999.99)).toBe('insufficientFunds');
    expect(checkTransfer(draft({ amount: 10000.3 }), 10000.1 + 0.2)).toBeNull();
    expect(checkTransfer(draft({ amount: 10000.01 }), 10000)).toBe('insufficientFunds');
  });

  it('rejects zero, negative, missing and oversized amounts', () => {
    for (const amount of [null, 0, -1]) expect(checkTransfer(draft({ amount }), 50000)).toBe('invalidAmount');
    expect(checkTransfer(draft({ amount: MAX_AMOUNT + 1 }), null)).toBe('amountTooLarge');
  });

  it('a null or non-finite balance checks shape only', () => {
    expect(checkTransfer(draft(), null)).toBeNull();
    for (const balance of [Infinity, NaN]) expect(checkTransfer(draft({ amount: 250 }), balance)).toBeNull();
  });

  it('requires both accounts, and reports the clash before the balance', () => {
    expect(checkTransfer(draft({ fromAccountId: null }), 1000)).toBe('noSource');
    expect(checkTransfer(draft({ toAccountId: null }), 1000)).toBe('noDestination');
    expect(checkTransfer(draft({ toAccountId: 'acc-a', amount: 99999 }), 0)).toBe('sameAccount');
  });

  it('every problem produces a message', () => {
    const problems: TransferProblem[] = [
      'noSource',
      'noDestination',
      'sameAccount',
      'invalidAmount',
      'amountTooLarge',
      'insufficientFunds',
    ];
    for (const problem of problems) expect(transferProblemMessage(problem)).not.toBe('');
  });

  it('describes each leg, preferring the user note', () => {
    expect(transferDescription({ note: null, isOutgoing: true, counterpartyLabel: 'Savings' })).toBe(
      'Transfer to Savings',
    );
    expect(transferDescription({ note: '  ', isOutgoing: false, counterpartyLabel: 'Current' })).toBe(
      'Transfer from Current',
    );
    expect(transferDescription({ note: 'Rent set aside', isOutgoing: true, counterpartyLabel: 'x' })).toBe(
      'Rent set aside',
    );
  });

  it('transfer legs are labelled Money Transfer and net to zero', () => {
    const legs = [
      { ...debit('l1', 5000, '2025-03-10'), transferGroupId: 'g', counterpartyAccountId: 'b' },
      { ...credit('l2', 5000, '2025-03-10'), transferGroupId: 'g', counterpartyAccountId: 'a' },
    ];
    expect(legs.map(ledgerCategoryLabel)).toEqual([MONEY_TRANSFER_LABEL, MONEY_TRANSFER_LABEL]);
    expect(signedAmount(legs[0] as LedgerEntry) + signedAmount(legs[1] as LedgerEntry)).toBe(0);
  });
});

describe('analytics', () => {
  const expense = (id: string, amount: number, categoryId: string | null): Expense => ({
    id,
    userId: 'u1',
    amount,
    expenseDate: '2026-09-10',
    categoryId,
    paymentMethodId: null,
    bankAccountId: null,
    merchant: null,
    description: null,
    notes: null,
    createdAt: null,
    updatedAt: null,
    category: null,
    paymentMethod: null,
  });

  it('breaks spending down by category, largest first', () => {
    const breakdown = buildCategoryBreakdown(
      [expense('1', 100, 'food'), expense('2', 50, null), expense('3', 300, 'food')],
      [{ id: 'food', userId: 'u1', name: 'Food', icon: 'restaurant', color: '#FF7043', isDefault: true, createdAt: null }],
    );
    expect(breakdown.map((c) => [c.name, c.total, c.transactionCount])).toEqual([
      ['Food', 400, 2],
      ['Uncategorised', 50, 1],
    ]);
  });

  it('flags budgets at 80% and over', () => {
    const budget = (id: string, amount: number, categoryId: string | null) => ({
      id,
      userId: 'u1',
      amount,
      month: '2026-09-01',
      categoryId,
      createdAt: null,
      category: null,
    });
    const month = buildBudgetProgress(
      [budget('all', 1000, null), budget('f', 100, 'food'), budget('t', 1000, 'travel')],
      [expense('1', 85, 'food'), expense('2', 10, 'travel')],
    );
    expect(month.overall?.spent).toBe(95);
    expect(budgetAlerts(month).map((p) => p.budget.id)).toEqual(['f']);
  });
});
