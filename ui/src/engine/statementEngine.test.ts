import { describe, expect, it } from 'vitest';

import type { BankAccount, ExpenseCategory, LedgerEntry } from '@/domain/models';
import { fingerprintOf } from '@/domain/statementImport/duplicates';
import type { NormalizedTransaction } from '@/domain/statementImport/model';

import { createEngine, EngineFailure } from './statementEngine';

// The phone app drives these calls over its WebView bridge with JSON. The
// parsers, review and plan are tested where they live; this pins the
// wrapper's contract: coded failures, the session range, and that a planned
// import is the same one the web screen would make.

const account: BankAccount = {
  id: 'acc-1',
  userId: 'u',
  bankName: 'Sample Bank',
  nickname: 'Main',
  last4: '1234',
  openingBalance: 0,
  isActive: true,
  createdAt: null,
};

const categories: ExpenseCategory[] = [
  { id: 'c-food', userId: 'u', name: 'Food', icon: 'restaurant', color: '#FF7043', isDefault: true, createdAt: null },
  { id: 'c-other', userId: 'u', name: 'Other', icon: 'category', color: '#999999', isDefault: true, createdAt: null },
];

function tx(id: string, date: string, amount: number, category: string | null, type: 'debit' | 'credit' = 'debit'): NormalizedTransaction {
  const base = { bankAccountId: 'acc-1', transactionDate: date, amount, transactionType: type, rawDescription: `Row ${id}` };
  return {
    ...base,
    id,
    description: `Row ${id}`,
    balance: null,
    kind: type === 'debit' ? 'expense' : 'income',
    category,
    categorySource: 'rule',
    categoryReason: null,
    sourceStatementId: 's1',
    reference: null,
    counterparty: null,
    channel: null,
    confidence: 1,
    issues: [],
    fingerprint: fingerprintOf(base),
    duplicate: null,
  };
}

const files = new Map<string, Uint8Array>([['notes', new TextEncoder().encode('just some text')]]);
const engine = createEngine((token) => {
  const bytes = files.get(token);
  return bytes
    ? Promise.resolve(bytes)
    : Promise.reject(new EngineFailure({ code: 'failed', message: 'That file is no longer available. Choose it again.' }));
});

const failureOf = async (run: () => Promise<unknown>) => {
  try {
    await run();
  } catch (error) {
    return error instanceof EngineFailure ? error.failure : { code: 'not-an-engine-failure', message: String(error) };
  }
  return null;
};

describe('statement engine (the phone app’s bridge)', () => {
  it('reports a file that is not a statement by code, for the app to word', async () => {
    const failure = await failureOf(() => engine.read({ token: 'notes', fileName: 'notes.txt', account, accounts: [account], categories }));
    expect(failure?.code).toBe('notPdf');
  });

  it('passes the host’s own file failure through unchanged', async () => {
    const failure = await failureOf(() => engine.read({ token: 'gone', fileName: 'x.pdf', account, accounts: [account], categories }));
    expect(failure).toEqual({ code: 'failed', message: 'That file is no longer available. Choose it again.' });
  });

  it('spans every statement in the session, earliest to latest', () => {
    expect(
      engine.sessionRange({
        statements: [
          { period: { from: '2026-09-08', to: '2026-09-14' } },
          { period: null },
          { period: { from: '2026-09-01', to: '2026-09-07' } },
        ],
      }),
    ).toEqual({ from: '2026-09-01', to: '2026-09-14' });
    expect(engine.sessionRange({ statements: [{ period: null }] })).toBeNull();
  });

  it('marks rows already recorded and leaves them out of the plan', () => {
    const items = engine.review({
      current: [],
      transactions: [tx('a', '2026-09-03', 450, 'Food'), tx('b', '2026-09-05', 5000, null, 'credit')],
      existing: [{ accountId: 'acc-1', date: '2026-09-03', amount: 450, direction: 'debit', description: 'Row a' }],
      categories,
    });
    expect(items.map((i) => i.selected)).toEqual([false, true]);
    const plan = engine.plan({ items, categories, paymentMethods: [] });
    expect(plan.operations.map((o) => o.type)).toEqual(['income']);
  });

  it('files an uncategorised expense under the same fallback category as the web import', () => {
    const items = engine.review({ current: [], transactions: [tx('c', '2026-09-04', 120, 'Something new')], existing: [], categories });
    const plan = engine.plan({ items, categories, paymentMethods: [] });
    expect(plan.operations).toHaveLength(1);
    expect(plan.operations[0]).toMatchObject({ type: 'expense', categoryId: 'c-other' });
  });

  it('drops a row recorded after review began', () => {
    const items = engine.review({ current: [], transactions: [tx('d', '2026-09-06', 75, 'Food')], existing: [], categories });
    const plan = engine.plan({ items, categories, paymentMethods: [] });
    const final = engine.finalPlan({
      plan,
      items,
      fresh: [{ accountId: 'acc-1', date: '2026-09-06', amount: 75, direction: 'debit', description: 'Row d' }],
    });
    expect(final.operations).toHaveLength(0);
    expect(final.skipped.length).toBeGreaterThan(0);
  });

  it('offers only the kinds valid for a direction', () => {
    expect(engine.kindsFor({ type: 'debit' })).toContain('expense');
    expect(engine.kindsFor({ type: 'credit' })).toContain('income');
    expect(engine.kindsFor({ type: 'credit' })).not.toContain('expense');
  });

  it('describes every row for the review screen', () => {
    const items = engine.review({ current: [], transactions: [tx('e', '2026-09-07', 10, 'Food')], existing: [], categories });
    const view = engine.view({ items });
    expect(view.summary.total).toBe(1);
    expect(view.rows[0]).toMatchObject({ id: 'e', blocking: false, kindLabel: 'Expense', problem: null, problemText: null });
  });
});

// ---------------------------------------------------------------------------
// A payment app's statement (Paytm): several accounts, notes, tags, UPI details
// ---------------------------------------------------------------------------

/** A Paytm-style row: its own account, a note, tags, a time and the UPI reference — all invented. */
function upiTx(id: string, overrides: Partial<NormalizedTransaction> = {}): NormalizedTransaction {
  return {
    ...tx(id, '2026-09-12', 249, 'Food'),
    description: 'Paid to Corner Cafe',
    counterparty: 'Corner Cafe',
    channel: 'upi',
    reference: '600012345678',
    upiId: 'cafe@upi',
    transactionTime: '13:05',
    notes: 'Lunch',
    tags: ['food', 'office'],
    sourceAccount: 'Sample Bank - 34',
    accountStatus: 'matched',
    ...overrides,
  };
}

describe('statement engine — a multi-account UPI statement', () => {
  it('flags a row whose account could not be matched until one is chosen', () => {
    const items = engine.review({
      current: [],
      transactions: [upiTx('u1', { bankAccountId: '', accountStatus: 'unmatched', sourceAccount: 'Unknown Bank - 99' })],
      existing: [],
      categories,
    });
    const view = engine.view({ items });
    expect(view.rows[0]).toMatchObject({ problem: 'account', problemText: 'Choose the account it was paid from.' });
    expect(view.summary.needsDetail).toBe(1);

    const chosen = engine.reduce({ items, action: { type: 'edit', id: 'u1', patch: { bankAccountId: 'acc-1' } } });
    expect(chosen[0]).toMatchObject({ bankAccountId: 'acc-1', accountStatus: 'chosen' });
    expect(engine.view({ items: chosen }).rows[0]?.problem).toBeNull();

    // Never imported into an account nobody chose.
    const plan = engine.plan({ items, categories, paymentMethods: [] });
    expect(plan.operations).toHaveLength(0);
    expect(plan.skipped[0]?.reason).toBe('Choose the account it was paid from');
  });

  it('writes the note, tags and UPI details where the database can keep them', () => {
    const items = engine.review({ current: [], transactions: [upiTx('u2')], existing: [], categories });
    const plan = engine.plan({ items, categories, paymentMethods: [], options: { storeDetails: true, storeTags: true } });
    expect(plan.operations[0]).toMatchObject({
      type: 'expense',
      merchant: 'Corner Cafe',
      notes: 'Lunch',
      tags: ['food', 'office'],
      details: { reference: '600012345678', upiId: 'cafe@upi', time: '13:05' },
    });
    expect(plan.counts).toMatchObject({ expenses: 1, transfers: 0 });
  });

  it('keeps everything the statement printed in the notes when the database cannot store it apart', () => {
    const items = engine.review({ current: [], transactions: [upiTx('u3')], existing: [], categories });
    const plan = engine.plan({ items, categories, paymentMethods: [] });
    const [op] = plan.operations;
    expect(op).toMatchObject({ type: 'expense' });
    expect(op && 'notes' in op ? op.notes : null).toBe('Lunch\nUPI ref 600012345678\nUPI ID cafe@upi\nTags: food, office');
    expect(op && 'tags' in op ? op.tags : undefined).toBeUndefined();
  });

  it('records a self transfer as one, linked or paired as the database allows', () => {
    const transfer = upiTx('u4', {
      kind: 'transfer',
      category: null,
      transferTarget: { type: 'account', accountId: 'acc-2' },
      notes: null,
      tags: [],
    });
    const items = engine.review({ current: [], transactions: [transfer], existing: [], categories });

    const linked = engine.plan({ items, categories, paymentMethods: [], options: { linkAccounts: true, accountNames: { 'acc-1': 'Main', 'acc-2': 'Salary' } } });
    expect(linked.operations[0]).toMatchObject({
      type: 'treatment',
      autoMatch: true,
      request: { kind: 'transfer', transferTarget: { type: 'account', accountId: 'acc-2' }, counterpartDescription: 'Transfer from Main' },
    });
    expect(linked.counts.transfers).toBe(1);

    const paired = engine.plan({ items, categories, paymentMethods: [], options: { linkAccounts: false, pairAccounts: true } });
    expect(paired.operations[0]).toMatchObject({ type: 'transfer', counterpartyAccountId: 'acc-2', direction: 'debit' });

    const balanceOnly = engine.plan({ items, categories, paymentMethods: [], options: { linkAccounts: false, pairAccounts: false } });
    expect(balanceOnly.operations[0]).toMatchObject({ type: 'movement', direction: 'debit' });
  });

  it('builds the record_bank_movement body, with the other leg found while writing', () => {
    const request = { kind: 'transfer', direction: 'debit', transferTarget: { type: 'account', accountId: 'acc-2' }, counterpartDescription: 'Transfer from Main' } as const;
    expect(engine.treatmentPayload({ request })).toEqual({
      type: 'transfer',
      counterparty_account_id: 'acc-2',
      counterpart_description: 'Transfer from Main',
    });
    expect(engine.treatmentPayload({ request, matchEntryId: 'led-9' })).toMatchObject({ match_entry_id: 'led-9' });
  });

  it('links a transfer’s other leg only when exactly one plain row matches', () => {
    const transfer = upiTx('u5', { kind: 'transfer', category: null, transferTarget: { type: 'account', accountId: 'acc-2' }, tags: [] });
    const items = engine.review({ current: [], transactions: [transfer], existing: [], categories });
    const { operations } = engine.plan({ items, categories, paymentMethods: [], options: { linkAccounts: true } });

    expect(engine.autoMatchWindows({ operations })).toEqual([{ accountId: 'acc-2', from: '2026-09-09', toExclusive: '2026-09-16' }]);

    const entry = (id: string, overrides: Partial<LedgerEntry> = {}): LedgerEntry => ({
      id,
      userId: 'u',
      accountId: 'acc-2',
      direction: 'credit',
      amount: 249,
      txnDate: '2026-09-13',
      description: 'UPI from Main',
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
      ...overrides,
    });
    expect(engine.autoMatches({ operations, entries: [entry('led-1')] })).toEqual({ u5: 'led-1' });
    // Two candidates: which one is unknowable, so the import adds its own leg.
    expect(engine.autoMatches({ operations, entries: [entry('led-1'), entry('led-2')] })).toEqual({});
    // An income row is never linked on its own; the user must choose it.
    expect(engine.autoMatches({ operations, entries: [entry('led-3', { incomeId: 'inc-1' })] })).toEqual({});
  });

  it('can leave out the kinds a client cannot record', () => {
    expect(engine.kindsFor({ type: 'debit', treatments: false })).toEqual(['expense', 'transfer']);
    expect(engine.kindsFor({ type: 'credit', treatments: false })).toEqual(['income', 'refund', 'transfer']);
    expect(engine.kindsFor({ type: 'debit' })).toContain('loan');
  });
});
