/**
 * Transfers between your own accounts, money lent, repayments and purchases
 * paid for someone else: the review rules, the import plan, the request sent
 * to the database, and what is owed.
 */
import { describe, expect, it } from 'vitest';

import { personalSpending } from './analytics';
import type { LedgerEntry } from './models';
import {
  balancesByPerson,
  claimStatus,
  knownPeople,
  outstandingAfter,
  summariseClaims,
  totalOutstanding,
  type ClaimRepayment,
  type ClaimSource,
  type Receivable,
} from './receivables';
import { classifyTransaction } from './statementImport/classify';
import { fingerprintOf } from './statementImport/duplicates';
import { buildImportPlan, countOperations } from './statementImport/importPlan';
import type { NormalizedTransaction } from './statementImport/model';
import { detailProblem, pendingRepayments, reviewReducer, similarItems, summarize, toReviewItems, type ReviewItem } from './statementImport/review';
import {
  availableKinds,
  findTransferMatches,
  kindsFor,
  treatmentOfEntry,
  treatmentPayload,
  treatmentProblem,
  type TreatmentState,
} from './treatment';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

function tx(id: string, date: string, amount: number, description: string, type: 'debit' | 'credit' = 'debit', extra: Partial<NormalizedTransaction> = {}): NormalizedTransaction {
  const base = { bankAccountId: 'hdfc', transactionDate: date, amount, transactionType: type, rawDescription: description };
  return {
    ...base,
    id,
    description,
    balance: null,
    kind: type === 'debit' ? 'expense' : 'income',
    category: 'Food',
    categorySource: 'rule',
    categoryReason: null,
    sourceStatementId: 's',
    reference: null,
    counterparty: null,
    channel: null,
    confidence: 1,
    issues: [],
    fingerprint: fingerprintOf(base),
    duplicate: null,
    ...extra,
  };
}

const CATEGORIES = [{ id: 'c-food', userId: 'u1', name: 'Food', icon: 'restaurant', color: '#000', isDefault: true, createdAt: null }];

const review = (transactions: NormalizedTransaction[]) => toReviewItems(transactions, CATEGORIES);

const edit = (items: ReviewItem[], id: string, patch: Parameters<typeof reviewReducer>[1] extends infer A ? (A extends { type: 'edit'; patch: infer P } ? P : never) : never) =>
  reviewReducer(items, { type: 'edit', id, patch });

const ledger = (id: string, extra: Partial<LedgerEntry> = {}): LedgerEntry => ({
  id,
  userId: 'u1',
  accountId: 'sbi',
  direction: 'credit',
  amount: 27000,
  txnDate: '2026-09-05',
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

const state = (patch: Partial<TreatmentState>): TreatmentState => ({
  kind: 'expense',
  categoryId: 'c-food',
  transferTarget: null,
  person: '',
  dueDate: null,
  note: '',
  reimbursable: false,
  settles: null,
  ...patch,
});

// ---------------------------------------------------------------------------
// Choices and their required details
// ---------------------------------------------------------------------------

describe('record-as choices', () => {
  it('fit the direction, and loans need migration 005', () => {
    expect(kindsFor('debit')).toEqual(['expense', 'transfer', 'loan']);
    expect(kindsFor('credit')).toEqual(['income', 'refund', 'transfer', 'loan', 'reimbursement']);
    expect(availableKinds('credit', false)).toEqual(['income', 'refund', 'transfer']);
  });

  it('asks for exactly the detail each treatment needs', () => {
    expect(treatmentProblem(state({ kind: 'transfer' }), 'debit')).toBe('transferTarget');
    expect(treatmentProblem(state({ kind: 'transfer', transferTarget: { type: 'cash' } }), 'debit')).toBeNull();
    expect(treatmentProblem(state({ kind: 'loan', person: '  ' }), 'debit')).toBe('loanPerson');
    expect(treatmentProblem(state({ kind: 'loan', person: 'Arun' }), 'debit')).toBeNull();
    expect(treatmentProblem(state({ kind: 'loan' }), 'credit')).toBe('loan');
    // A reimbursable claim is not a loan.
    expect(treatmentProblem(state({ kind: 'loan', settles: { type: 'claim', receivableId: 'r', kind: 'reimbursable' } }), 'credit')).toBe('loan');
    expect(treatmentProblem(state({ kind: 'reimbursement', settles: { type: 'expense', expenseId: 'e' } }), 'credit')).toBe('settlePerson');
    expect(treatmentProblem(state({ kind: 'reimbursement', person: 'Ravi', settles: { type: 'expense', expenseId: 'e' } }), 'credit')).toBeNull();
    expect(treatmentProblem(state({ reimbursable: true }), 'debit')).toBe('paidForPerson');
  });
});

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

describe('classifying the other side of a transfer', () => {
  const ctx = {
    categories: CATEGORIES,
    otherAccountLast4: ['7788'],
    otherAccounts: [{ id: 'sbi', last4: '7788' }],
    cards: [{ id: 'card-1', last4: '4821' }],
  };
  const classify = (text: string, type: 'debit' | 'credit' = 'debit') =>
    classifyTransaction({ description: text, rawDescription: text, transactionType: type }, ctx);

  it('names your own account when its digits are in the narration', () => {
    expect(classify('IMPS TO XXXX7788 SAVINGS')).toMatchObject({ kind: 'transfer', transferTarget: { type: 'account', accountId: 'sbi' } });
  });

  it('sends a cash withdrawal to cash and a card bill to the card', () => {
    expect(classify('ATM CASH WDL MG ROAD')).toMatchObject({ kind: 'transfer', transferTarget: { type: 'cash' } });
    expect(classify('CC 4821 PAYMENT')).toMatchObject({ kind: 'transfer', transferTarget: { type: 'card', cardId: 'card-1' }, creditCardId: 'card-1' });
  });

  it('leaves the other side open when the narration does not say', () => {
    expect(classify('SELF TRANSFER').transferTarget).toBeUndefined();
  });
});

// ---------------------------------------------------------------------------
// Review and import plan
// ---------------------------------------------------------------------------

describe('a transfer to one of your accounts', () => {
  it('is written as both legs, and an undecided other leg is left to an exact match', () => {
    let items = review([tx('t', '2026-09-05', 27000, 'UPI-BALAMURUGANS', 'debit', { counterparty: 'BALAMURUGANS' })]);
    items = edit(items, 't', { kind: 'transfer', transferTarget: { type: 'account', accountId: 'sbi' } });
    const plan = buildImportPlan(items, { fallbackCategoryId: 'c-food', accountNames: new Map([['hdfc', 'HDFC'], ['sbi', 'SBI']]) });
    expect(plan.operations).toHaveLength(1);
    expect(plan.operations[0]).toMatchObject({
      type: 'treatment',
      direction: 'debit',
      amount: 27000,
      autoMatch: true,
      request: { kind: 'transfer', transferTarget: { type: 'account', accountId: 'sbi' }, counterpartDescription: 'Transfer from HDFC' },
    });
    expect(countOperations(plan.operations)).toMatchObject({ transfers: 1, expenses: 0 });
  });

  it('links the row the user chose, and stays balance only without migration 005', () => {
    let items = review([tx('t', '2026-09-05', 27000, 'UPI-X')]);
    items = edit(items, 't', { kind: 'transfer', transferTarget: { type: 'account', accountId: 'sbi' }, transferMatch: { entryId: 'sbi-row', label: 'x' } });
    expect(buildImportPlan(items, { fallbackCategoryId: null }).operations[0]).toMatchObject({ autoMatch: false, request: { matchEntryId: 'sbi-row' } });
    expect(buildImportPlan(items, { fallbackCategoryId: null, linkAccounts: false }).operations[0]).toMatchObject({ type: 'movement', direction: 'debit' });
  });

  it('still writes both legs without migration 005, as long as transfers (003) exist', () => {
    let items = review([tx('t', '2026-09-05', 27000, 'UPI-X')]);
    items = edit(items, 't', { kind: 'transfer', transferTarget: { type: 'account', accountId: 'sbi' } });
    const plan = buildImportPlan(items, { fallbackCategoryId: null, linkAccounts: false, pairAccounts: true, accountNames: new Map([['hdfc', 'Salary']]) });
    expect(plan.operations[0]).toMatchObject({
      type: 'transfer',
      bankAccountId: 'hdfc',
      counterpartyAccountId: 'sbi',
      direction: 'debit',
      amount: 27000,
      description: 'UPI-X',
      counterpartDescription: 'Transfer from Salary',
    });
    expect(countOperations(plan.operations)).toMatchObject({ transfers: 1, movements: 0 });
  });

  it('forgets a chosen other leg when the amount, date or account changes', () => {
    let items = review([tx('t', '2026-09-05', 27000, 'UPI-X')]);
    items = edit(items, 't', { kind: 'transfer', transferTarget: { type: 'account', accountId: 'sbi' }, transferMatch: { entryId: 'm', label: 'x' } });
    expect(edit(items, 't', { amount: 26000 })[0]?.transferMatch).toBeNull();
    expect(edit(items, 't', { transferTarget: { type: 'account', accountId: 'icici' } })[0]?.transferMatch).toBeNull();
    expect(edit(items, 't', { description: 'Rent' })[0]?.transferMatch).toEqual({ entryId: 'm', label: 'x' });
  });

  it('imports a transfer with no other side chosen as balance only, flagged for attention', () => {
    const items = review([tx('t', '2026-09-05', 500, 'SELF', 'debit', { kind: 'transfer' })]);
    expect(detailProblem(items[0] as ReviewItem)).toBe('transferTarget');
    expect(summarize(items)).toMatchObject({ transfers: 1, needsDetail: 1 });
    expect(buildImportPlan(items, { fallbackCategoryId: null }).operations).toEqual([expect.objectContaining({ type: 'movement' })]);
  });
});

describe('money lent and paid back in the same statement', () => {
  const base = () => {
    let items = review([
      tx('lent', '2026-09-06', 5000, 'UPI-ARUN', 'debit', { counterparty: 'ARUN' }),
      tx('back1', '2026-09-20', 2000, 'UPI-ARUN', 'credit', { counterparty: 'ARUN' }),
      tx('back2', '2026-09-28', 3000, 'UPI-ARUN', 'credit', { counterparty: 'ARUN' }),
    ]);
    items = edit(items, 'lent', { kind: 'loan', person: 'Arun', dueDate: '2026-12-31', note: 'bike' });
    return items;
  };

  it('writes the loan first, then repayments that point at it', () => {
    let items = base();
    // Listed first on purpose: it must still be written after the loan.
    items = [...items.slice(1), ...items.slice(0, 1)];
    items = edit(items, 'back1', { kind: 'loan', settles: { type: 'pending', itemId: 'lent', kind: 'loan' } });
    const plan = buildImportPlan(items, { fallbackCategoryId: 'c-food' });
    expect(plan.operations.map((op) => op.itemId)).toEqual(['back2', 'lent', 'back1']);
    expect(plan.operations.find((op) => op.itemId === 'lent')).toMatchObject({
      type: 'treatment',
      request: { kind: 'loan', direction: 'debit', person: 'Arun', dueDate: '2026-12-31', note: 'bike' },
    });
    expect(plan.operations.find((op) => op.itemId === 'back1')).toMatchObject({ settlesItemId: 'lent', request: { kind: 'loan', direction: 'credit' } });
    expect(pendingRepayments(items, null).get('lent')).toBe(2000);
    expect(countOperations(plan.operations)).toMatchObject({ lent: 1, repaid: 1, income: 1 });
  });

  it('skips a repayment whose loan is not imported, and unlinks it when the loan row is removed', () => {
    let items = edit(base(), 'back1', { kind: 'loan', settles: { type: 'pending', itemId: 'lent', kind: 'loan' } });
    const deselected = reviewReducer(items, { type: 'toggle', id: 'lent' });
    expect(buildImportPlan(deselected, { fallbackCategoryId: 'c-food' }).skipped).toContainEqual({ itemId: 'back1', reason: 'What it pays back is not being imported' });
    items = reviewReducer(items, { type: 'remove', id: 'lent' });
    expect(items.find((i) => i.id === 'back1')?.settles).toBeNull();
    // Changing the loan row into an expense also unlinks it.
    const changed = edit(edit(base(), 'back1', { settles: { type: 'pending', itemId: 'lent', kind: 'loan' }, kind: 'loan' }), 'lent', { kind: 'expense' });
    expect(changed.find((i) => i.id === 'back1')?.settles).toBeNull();
  });

  it('never writes a loan or a repayment that is missing its detail', () => {
    let items = edit(base(), 'lent', { person: ' ' });
    items = edit(items, 'back2', { kind: 'loan' });
    const plan = buildImportPlan(items, { fallbackCategoryId: 'c-food' });
    expect(plan.skipped).toEqual([
      { itemId: 'lent', reason: 'Add who you lent the money to' },
      { itemId: 'back2', reason: 'Choose the loan this repays' },
    ]);
  });
});

describe('reimbursements', () => {
  it('pays back a purchase, marking it as paid for that person', () => {
    let items = review([tx('in', '2026-09-12', 3000, 'UPI-RAVI', 'credit')]);
    items = edit(items, 'in', { kind: 'reimbursement', person: 'Ravi', settles: { type: 'expense', expenseId: 'card-purchase' } });
    expect(buildImportPlan(items, { fallbackCategoryId: null }).operations[0]).toMatchObject({
      type: 'treatment',
      request: { kind: 'reimbursement', settles: { expenseId: 'card-purchase', person: 'Ravi' } },
    });
  });

  it('records an expense paid for someone as an expense with its claim', () => {
    let items = review([tx('out', '2026-09-08', 800, 'UPI-CAFE', 'debit', { counterparty: 'CAFE' })]);
    items = edit(items, 'out', { reimbursable: true, person: 'Ravi' });
    const op = buildImportPlan(items, { fallbackCategoryId: 'c-food' }).operations[0];
    expect(op).toMatchObject({ type: 'treatment', description: 'CAFE', request: { kind: 'expense', reimbursablePerson: 'Ravi', categoryId: 'c-food', merchant: 'CAFE' } });
    expect(countOperations(op ? [op] : [])).toMatchObject({ paidFor: 1, expenses: 0 });
  });

  it('drops reimbursable and settlement details that do not fit a new direction', () => {
    let items = review([tx('x', '2026-09-08', 800, 'UPI-CAFE')]);
    items = edit(items, 'x', { reimbursable: true, person: 'Ravi' });
    items = edit(items, 'x', { transactionType: 'credit' });
    expect(items[0]).toMatchObject({ kind: 'income', reimbursable: false });
  });
});

describe('apply to similar rows', () => {
  it('finds rows from the same payee in the same direction, not duplicates', () => {
    const items = review([
      tx('a', '2026-09-01', 100, 'UPI-ARUN', 'debit', { counterparty: 'Arun ' }),
      tx('b', '2026-09-02', 200, 'UPI-ARUN', 'debit', { counterparty: 'ARUN' }),
      tx('c', '2026-09-03', 300, 'UPI-ARUN', 'credit', { counterparty: 'ARUN' }),
      tx('d', '2026-09-04', 400, 'UPI-ARUN', 'debit', { counterparty: 'ARUN', duplicate: { type: 'overlap', ofId: 'a' } }),
      tx('e', '2026-09-05', 500, 'UPI-MEENA', 'debit', { counterparty: 'MEENA' }),
    ]);
    expect(similarItems(items, items[0] as ReviewItem).map((i) => i.id)).toEqual(['b']);
    const changed = reviewReducer(items, { type: 'editMany', ids: ['a', 'b'], patch: { kind: 'transfer', transferTarget: { type: 'account', accountId: 'sbi' } } });
    expect(changed.filter((i) => i.kind === 'transfer').map((i) => i.id)).toEqual(['a', 'b']);
  });
});

// ---------------------------------------------------------------------------
// The request sent to the database
// ---------------------------------------------------------------------------

describe('treatment requests', () => {
  it('maps every treatment to the function’s JSON, with only the keys that mean something', () => {
    expect(treatmentPayload({ kind: 'refund', direction: 'credit' })).toEqual({ type: 'plain' });
    expect(treatmentPayload({ kind: 'transfer', direction: 'debit', transferTarget: { type: 'cash' } })).toEqual({ type: 'plain' });
    expect(treatmentPayload({ kind: 'transfer', direction: 'debit', transferTarget: { type: 'card', cardId: 'k' } })).toEqual({ type: 'card_payment', credit_card_id: 'k' });
    // A card cannot send money in.
    expect(treatmentPayload({ kind: 'transfer', direction: 'credit', transferTarget: { type: 'card', cardId: 'k' } })).toEqual({ type: 'plain' });
    expect(
      treatmentPayload({ kind: 'transfer', direction: 'debit', transferTarget: { type: 'account', accountId: 'sbi' }, matchEntryId: 'm', amount: 27000.004, keepPreviousCounterpart: true }),
    ).toEqual({ type: 'transfer', counterparty_account_id: 'sbi', match_entry_id: 'm', amount: 27000, keep_previous_counterpart: true });
    expect(treatmentPayload({ kind: 'loan', direction: 'debit', person: ' Arun ', dueDate: null, note: '' })).toEqual({ type: 'loan', person: 'Arun', due_date: null, note: null });
    expect(treatmentPayload({ kind: 'loan', direction: 'credit', settles: { receivableId: 'r1' } })).toEqual({ type: 'settlement', receivable_id: 'r1' });
    expect(treatmentPayload({ kind: 'reimbursement', direction: 'credit', settles: { entryId: 'e1' } })).toEqual({ type: 'settlement', settle_entry_id: 'e1' });
    expect(treatmentPayload({ kind: 'expense', direction: 'debit', categoryId: 'c', reimbursablePerson: null })).toEqual({ type: 'expense', category_id: 'c', reimbursable_person: null });
    expect(treatmentPayload({ kind: 'income', direction: 'credit', source: ' Salary ' })).toEqual({ type: 'income', source: 'Salary' });
  });

  it('reads back what a saved movement is recorded as', () => {
    expect(treatmentOfEntry(ledger('a', { direction: 'debit', transferGroupId: 'g', counterpartyAccountId: 'hdfc' }))).toMatchObject({
      kind: 'transfer',
      transferTarget: { type: 'account', accountId: 'hdfc' },
    });
    expect(treatmentOfEntry(ledger('b', { direction: 'debit', claim: { receivableId: 'r', kind: 'loan', person: 'Arun', role: 'source' } }))).toMatchObject({ kind: 'loan', person: 'Arun' });
    expect(treatmentOfEntry(ledger('c', { receivableId: 'r', claim: { receivableId: 'r', kind: 'reimbursable', person: 'Ravi', role: 'settles' } }))).toMatchObject({
      kind: 'reimbursement',
      settles: { type: 'claim', receivableId: 'r', kind: 'reimbursable' },
    });
    expect(treatmentOfEntry(ledger('d', { direction: 'debit', expenseId: 'e', categoryId: 'c', claim: { receivableId: 'r', kind: 'reimbursable', person: 'Ravi', role: 'source' } }))).toMatchObject({
      kind: 'expense',
      reimbursable: true,
      person: 'Ravi',
    });
    expect(treatmentOfEntry(ledger('e', { direction: 'debit' }))).toMatchObject({ kind: 'transfer', transferTarget: { type: 'cash' } });
    expect(treatmentOfEntry(ledger('f'))).toMatchObject({ kind: 'refund' });
  });
});

describe('finding the other leg already on the other account', () => {
  it('matches the opposite direction and same amount within a few days, closest and plainest first', () => {
    const entries = [
      ledger('income', { incomeId: 'i', txnDate: '2026-09-05' }),
      ledger('plain', { txnDate: '2026-09-05' }),
      ledger('later', { txnDate: '2026-09-07' }),
      ledger('far', { txnDate: '2026-09-12' }),
      ledger('other-amount', { amount: 26999 }),
      ledger('same-direction', { direction: 'debit' }),
      ledger('already-a-leg', { transferGroupId: 'g' }),
      ledger('lent', { claim: { receivableId: 'r', kind: 'loan', person: 'x', role: 'source' } }),
    ];
    expect(findTransferMatches(entries, { direction: 'debit', amount: 27000, date: '2026-09-05' }).map((e) => e.id)).toEqual(['plain', 'income', 'later']);
  });
});

// ---------------------------------------------------------------------------
// What is owed
// ---------------------------------------------------------------------------

describe('what is owed', () => {
  const receivable = (id: string, kind: 'loan' | 'reimbursable', person: string, dueDate: string | null = null): Receivable => ({
    id,
    userId: 'u1',
    kind,
    person,
    ledgerEntryId: kind === 'loan' ? `l-${id}` : null,
    expenseId: kind === 'reimbursable' ? `e-${id}` : null,
    dueDate,
    note: null,
    createdAt: null,
  });
  const source = (amount: number, date: string): ClaimSource => ({ date, amount, title: 'x', accountId: 'hdfc', cardId: null, ledgerEntryId: null, expenseId: null });
  const repayment = (receivableId: string, amount: number, entryId: string): ClaimRepayment => ({ entryId, receivableId, accountId: 'hdfc', amount, date: '2026-09-20', description: null });

  const claims = summariseClaims({
    receivables: [receivable('loan', 'loan', 'Arun', '2026-09-30'), receivable('card', 'reimbursable', 'arun '), receivable('done', 'loan', 'Meena')],
    sources: new Map([
      ['loan', source(5000, '2026-09-06')],
      ['card', source(3000, '2026-09-10')],
      ['done', source(1500, '2026-08-01')],
    ]),
    repayments: [repayment('loan', 2000, 'p1'), repayment('card', 2000, 'p2'), repayment('done', 1000, 'p3'), repayment('done', 500, 'p4')],
    today: '2026-10-03',
  });

  it('tracks partial and full repayment, and overdue loans', () => {
    const byId = new Map(claims.map((c) => [c.receivable.id, c]));
    expect(byId.get('loan')).toMatchObject({ principal: 5000, received: 2000, outstanding: 3000, status: 'partial', overdue: true });
    expect(byId.get('card')).toMatchObject({ principal: 3000, received: 2000, outstanding: 1000, status: 'partial', overdue: false });
    expect(byId.get('done')).toMatchObject({ outstanding: 0, status: 'settled', overdue: false });
    expect(claims.at(-1)?.receivable.id).toBe('done');
    expect(totalOutstanding(claims)).toBe(4000);
  });

  it('groups people however their name was typed', () => {
    const groups = balancesByPerson(claims);
    expect(groups[0]).toMatchObject({ person: 'Arun', outstanding: 4000, open: 2 });
    expect(knownPeople(claims)).toHaveLength(2);
  });

  it('says what is left after a repayment, not counting the one being edited', () => {
    const loan = claims.find((c) => c.receivable.id === 'loan');
    expect(loan && outstandingAfter(loan, 3000)).toBe(0);
    expect(loan && outstandingAfter(loan, 3000, { excludeEntryId: 'p1' })).toBe(2000);
    expect(loan && outstandingAfter(loan, 1000, { pendingElsewhere: 500 })).toBe(1500);
    expect(claimStatus(100, 150)).toBe('overpaid');
    expect(claimStatus(100, 0)).toBe('open');
  });

  it('keeps purchases paid for others out of personal spending', () => {
    const expenses = [{ id: 'e1', amount: 3000 }, { id: 'e2', amount: 400 }];
    expect(personalSpending(expenses, new Set(['e1']))).toEqual([{ id: 'e2', amount: 400 }]);
    expect(personalSpending(expenses, new Set())).toHaveLength(2);
  });
});
