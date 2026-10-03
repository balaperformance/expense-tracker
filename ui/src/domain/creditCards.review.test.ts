/**
 * Production-readiness checks: exact money, no double counting at import,
 * bill payments that never become expenses, and full reads of long histories.
 */
import { describe, expect, it } from 'vitest';

import { allRowsOf, monthlyTotals } from '@/services/db';
import { netOfRows } from '@/services/ledger';

import {
  buildCardStatement,
  findExpenseDebits,
  looksLikeCardBillPayment,
  outstandingOf,
  summariseCard,
  type CardEntry,
} from './creditCards';
import type { CreditCard, LedgerEntry } from './models';
import { classifyTransaction } from './statementImport/classify';
import { fingerprintOf } from './statementImport/duplicates';
import { buildImportPlan } from './statementImport/importPlan';
import type { NormalizedTransaction } from './statementImport/model';
import { toReviewItems } from './statementImport/review';

const card: CreditCard = {
  id: 'c1',
  userId: 'u1',
  cardName: 'Regalia',
  issuer: 'HDFC Bank',
  network: null,
  last4: '4821',
  creditLimit: 100_000,
  openingOutstanding: 0.1,
  statementDay: 15,
  paymentDueDay: 5,
  paymentAccountId: null,
  isActive: true,
  notes: null,
  createdAt: null,
};

const entry = (i: number, direction: 'debit' | 'credit', amount: number, date: string): CardEntry => ({
  key: `k${String(i).padStart(5, '0')}`,
  source: 'card',
  id: `e${i}`,
  cardId: 'c1',
  kind: direction === 'debit' ? 'fee' : 'refund',
  direction,
  amount,
  date,
  description: null,
  category: null,
  accountId: null,
  originalExpenseId: null,
  reference: null,
  createdAt: null,
});

describe('exact money over long histories', () => {
  it('sums thousands of decimal amounts without drifting', () => {
    const entries = Array.from({ length: 3000 }, (_, i) => entry(i, 'debit', 0.1, '2026-09-01'));
    expect(outstandingOf(0.1, entries)).toBe(300.1);
    const statement = buildCardStatement({ openingOutstanding: 0.1, entries });
    expect(statement.closing).toBe(300.1);
    expect(statement.charges).toBe(300);
    expect(statement.rows[0]?.outstandingAfter).toBe(300.1);
  });

  it('settles a bill paid in many small parts exactly', () => {
    const entries = [entry(0, 'debit', 1000, '2026-09-01'), ...Array.from({ length: 10 }, (_, i) => entry(i + 1, 'credit', 100.01, '2026-09-20'))];
    const summary = summariseCard({ ...card, openingOutstanding: 0.1 }, entries, '2026-10-02');
    // 1000.10 billed, 1000.10 credited after the statement → paid, not "₹0.00 due".
    expect(summary.lastStatement).toMatchObject({ balance: 1000.1, credited: 1000.1, remaining: 0, status: 'paid' });
    expect(summary.outstanding).toBe(0);
  });

  it('nets a bank ledger in whole cents', () => {
    const rows = Array.from({ length: 1000 }, () => ({ direction: 'debit', amount: '0.10' }));
    expect(netOfRows([...rows, { direction: 'credit', amount: 100.2 }])).toBe(0.2);
  });

  it('totals months in whole cents', () => {
    const rows = Array.from({ length: 10 }, () => ({ amount: 0.1, expense_date: '2026-09-03' }));
    expect(monthlyTotals(rows, 'expense_date').get('2026-09')).toBe(1);
  });
});

describe('allRowsOf — every row, whatever the server page size', () => {
  const table = Array.from({ length: 2345 }, (_, i) => ({ id: i }));
  /** A server that caps every response at [cap] rows, like PostgREST's max-rows. */
  const server = (cap: number, withCountHeader = true) => (from: number, to: number, withCount: boolean) =>
    Promise.resolve({
      data: table.slice(from, Math.min(to + 1, from + cap)),
      error: null,
      count: withCount && withCountHeader ? table.length : null,
    });

  it('keeps reading past a 1000-row cap', async () => {
    expect(await allRowsOf(server(1000))).toHaveLength(2345);
  });

  it('keeps reading past a smaller cap than it asked for', async () => {
    const rows = await allRowsOf(server(300));
    expect(rows).toHaveLength(2345);
    expect(rows.map((r) => r.id)).toEqual(table.map((r) => r.id));
  });

  it('reads to the end without a count, and stops at a deliberate maximum', async () => {
    expect(await allRowsOf(server(1000, false))).toHaveLength(2345);
    expect(await allRowsOf(server(1000), 1500)).toHaveLength(1500);
  });

  it('surfaces an error instead of a short total', async () => {
    let calls = 0;
    const failing = () => {
      calls += 1;
      return Promise.resolve(calls === 1 ? { data: table.slice(0, 1000), error: null, count: 2345 } : { data: null, error: new Error('network'), count: null });
    };
    await expect(allRowsOf(failing)).rejects.toThrow();
  });
});

const tx = (description: string, type: 'debit' | 'credit' = 'debit'): NormalizedTransaction => {
  const base = { bankAccountId: 'acc-1', transactionDate: '2026-10-03', amount: 5000, transactionType: type, rawDescription: description };
  return {
    ...base,
    id: description,
    description,
    balance: null,
    kind: type === 'debit' ? 'expense' : 'income',
    category: null,
    categorySource: 'none',
    categoryReason: null,
    sourceStatementId: 's',
    reference: null,
    counterparty: null,
    channel: null,
    confidence: 1,
    issues: [],
    fingerprint: fingerprintOf(base),
    duplicate: null,
  };
};

describe('importing a bank statement never turns a card bill into spending', () => {
  const ctx = { categories: [], otherAccountLast4: [], cards: [{ id: 'c1', last4: '4821' }] };

  it('recognises a bill by card wording and the card’s digits, and links it', () => {
    const result = classifyTransaction(tx('BILLDESK HDFC CARD XX4821'), ctx);
    expect(result).toMatchObject({ kind: 'transfer', creditCardId: 'c1' });
  });

  it('needs both the wording and the digits, one card, and money out', () => {
    expect(classifyTransaction(tx('UPI AMAZON 4821'), ctx).creditCardId).toBeUndefined();
    expect(classifyTransaction(tx('CARD 1234 PAYMENT'), ctx).creditCardId).toBeUndefined();
    expect(classifyTransaction(tx('CC 4821 REVERSAL', 'credit'), ctx).creditCardId).toBeUndefined();
    const twoCards = { ...ctx, cards: [{ id: 'c1', last4: '4821' }, { id: 'c2', last4: '4821' }] };
    expect(classifyTransaction(tx('CC 4821 PAYMENT'), twoCards)).toMatchObject({ kind: 'transfer' });
    expect(classifyTransaction(tx('CC 4821 PAYMENT'), twoCards).creditCardId).toBeUndefined();
  });

  it('writes a recognised bill as a linked movement — never an expense', () => {
    const items = toReviewItems([{ ...tx('CC PAYMENT XX4821'), ...classifyTransaction(tx('CC PAYMENT XX4821'), ctx) }], []);
    const plan = buildImportPlan(items.map((i) => ({ ...i, selected: true })), { fallbackCategoryId: 'c-other' });
    expect(plan.operations).toEqual([expect.objectContaining({ type: 'movement', direction: 'debit', creditCardId: 'c1', amount: 5000 })]);
  });

  it('drops the card link if the user turns the row into an expense', () => {
    const [item] = toReviewItems([{ ...tx('CC PAYMENT XX4821'), ...classifyTransaction(tx('CC PAYMENT XX4821'), ctx) }], []);
    if (!item) throw new Error('no item');
    const plan = buildImportPlan([{ ...item, selected: true, kind: 'expense', categoryId: 'c-other' }], { fallbackCategoryId: 'c-other' });
    expect(plan.operations[0]).toMatchObject({ type: 'expense' });
    expect(plan.operations[0]).not.toHaveProperty('creditCardId');
  });
});

describe('guarding against recording a bill twice', () => {
  const ledger = (id: string, extra: Partial<LedgerEntry>): LedgerEntry => ({
    id,
    userId: 'u1',
    accountId: 'a1',
    direction: 'debit',
    amount: 5000,
    txnDate: '2026-10-03',
    description: null,
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

  it('finds a same-amount expense near the date (a bill imported as spending)', () => {
    const hits = findExpenseDebits(
      [ledger('x', { expenseId: 'e1' }), ledger('plain', {}), ledger('far', { expenseId: 'e2', txnDate: '2026-10-10' }), ledger('other', { expenseId: 'e3', amount: 4999 })],
      5000,
      '2026-10-02',
    );
    expect(hits.map((h) => h.id)).toEqual(['x']);
  });

  it('spots bill-payment wording in a bank alert, but not ordinary card spending', () => {
    expect(looksLikeCardBillPayment('Rs.5000 debited from a/c XX6459 towards HDFC Credit Card XX4821')).toBe(true);
    expect(looksLikeCardBillPayment('Payment of Rs 5000 to your credit card bill is successful')).toBe(true);
    expect(looksLikeCardBillPayment('CC payment of INR 5000 received')).toBe(true);
    expect(looksLikeCardBillPayment('Rs 500 spent on HDFC Bank Credit Card XX4821 at AMAZON on 03-10-26.')).toBe(false);
    expect(looksLikeCardBillPayment('Sent Rs.2900.00 From HDFC Bank A/C *6459 To CHENNAI KEY MAKERS')).toBe(false);
  });
});

describe('a hand-recorded bill posted later by the bank', () => {
  it('blocks the imported row instead of only flagging it', async () => {
    const { markDuplicates } = await import('./statementImport/duplicates');
    const incoming = { ...tx('NEFT HDFC CARDS'), transactionDate: '2026-10-04' };
    const recorded = { accountId: 'acc-1', date: '2026-10-03', amount: 5000, direction: 'debit' as const, description: 'Regalia bill payment' };
    const [asCardPayment] = markDuplicates([{ ...incoming, fingerprint: fingerprintOf(incoming) }], [{ ...recorded, creditCardId: 'c1' }]);
    expect(asCardPayment?.duplicate).toMatchObject({ type: 'existing', strength: 'likely' });
    const [asOrdinary] = markDuplicates([{ ...incoming, fingerprint: fingerprintOf(incoming) }], [recorded]);
    expect(asOrdinary?.duplicate).toMatchObject({ type: 'nearby' });
  });
});
