import { describe, expect, it } from 'vitest';

import type { BankAccount, ExpenseCategory } from '../models';

import { classifyTransaction } from './classify';
import { fingerprintOf, markDuplicates } from './duplicates';
import { buildImportPlan, STATEMENT_NOTE, withoutNewlyRecorded } from './importPlan';
import { groupFragments } from './layout';
import type { ExistingMovement, ExtractedDocument, NormalizedTransaction, TextLine } from './model';
import { periodKindOf } from './normalize';
import { detectDayFirst, inferDayFirst, looksLikeMoney, parseStatementAmount, parseStatementDate } from './parsing';
import { genericTableParser } from './parsers/genericTable';
import { processStatement } from './pipeline';
import { reviewReducer, summarize, toReviewItems } from './review';

// ---------------------------------------------------------------------------
// Fixtures — synthetic, bank-neutral layouts
// ---------------------------------------------------------------------------

const ACCOUNT: BankAccount = {
  id: 'acc-1',
  userId: 'u1',
  bankName: 'Test Bank',
  nickname: 'Main',
  last4: '4821',
  openingBalance: 0,
  isActive: true,
  createdAt: null,
};
const SAVINGS: BankAccount = { ...ACCOUNT, id: 'acc-2', nickname: 'Savings', last4: '7788' };

const category = (id: string, name: string): ExpenseCategory => ({
  id,
  userId: 'u1',
  name,
  icon: 'category',
  color: '#78909C',
  isDefault: true,
  createdAt: null,
});
const CATEGORIES = [category('c-food', 'Food'), category('c-bills', 'Bills'), category('c-shop', 'Shopping'), category('c-other', 'Other')];

/** A line from [text, x] pairs; width is estimated from the text. */
function line(y: number, cells: ReadonlyArray<readonly [string, number]>, page = 1): TextLine {
  const mapped = cells.map(([text, x]) => ({ text, x, width: text.length * 4.5 }));
  return { page, y, cells: mapped, text: mapped.map((c) => c.text).join(' ') };
}

const doc = (lines: TextLine[]): ExtractedDocument => ({ pageCount: 1, lines, source: 'pdf-text' });

// Columns: Date 40 · Narration 110 · Ref 300 · Withdrawal 380 · Deposit 450 · Balance 520
const HEADER = line(700, [
  ['Date', 40],
  ['Narration', 110],
  ['Chq./Ref.No.', 300],
  ['Withdrawal Amt.', 380],
  ['Deposit Amt.', 450],
  ['Closing Balance', 520],
]);

function tableStatement(rows: TextLine[]): ExtractedDocument {
  return doc([
    line(760, [['Statement of account', 40]]),
    line(745, [['Account No : XXXXXX4821', 40]]),
    line(730, [['Statement From : 01/09/2026 To : 30/09/2026', 40]]),
    HEADER,
    ...rows,
    line(80, [['Page 1 of 1', 250]]),
  ]);
}

function process(document: ExtractedDocument, statementId = 'st-1', accounts: BankAccount[] = [ACCOUNT, SAVINGS]) {
  return processStatement({ doc: document, statementId, fileName: `${statementId}.pdf`, account: ACCOUNT, accounts, categories: CATEGORIES });
}

// ---------------------------------------------------------------------------
// Date and amount parsing
// ---------------------------------------------------------------------------

describe('date parsing', () => {
  it('reads the common statement formats', () => {
    expect(parseStatementDate('05/09/2026')).toBe('2026-09-05');
    expect(parseStatementDate('05-09-26')).toBe('2026-09-05');
    expect(parseStatementDate('05.09.2026')).toBe('2026-09-05');
    expect(parseStatementDate('2026-09-05')).toBe('2026-09-05');
    expect(parseStatementDate('05 Sep 2026')).toBe('2026-09-05');
    expect(parseStatementDate('05-SEP-26')).toBe('2026-09-05');
    expect(parseStatementDate('5th September 2026')).toBe('2026-09-05');
    expect(parseStatementDate('Sep 5, 2026')).toBe('2026-09-05');
  });

  it('honours month-first when asked and rejects impossible dates', () => {
    expect(parseStatementDate('09/05/2026', false)).toBe('2026-09-05');
    expect(parseStatementDate('31/02/2026')).toBeNull();
    expect(parseStatementDate('13/13/2026')).toBeNull();
    expect(parseStatementDate('not a date')).toBeNull();
    expect(parseStatementDate('')).toBeNull();
  });

  it('decides day-first from the dates themselves', () => {
    expect(detectDayFirst(['01/09/2026', '25/09/2026'])).toBe(true);
    expect(detectDayFirst(['09/01/2026', '09/25/2026'])).toBe(false);
    expect(detectDayFirst(['01/02/2026', '03/04/2026'])).toBeNull();
  });

  it('settles all-ambiguous dates by the tighter span, else leaves them flagged', () => {
    // A week in September, not January to July.
    expect(inferDayFirst(['01/09/2026', '03/09/2026', '07/09/2026'])).toBe(true);
    expect(inferDayFirst(['09/01/2026', '09/03/2026', '09/07/2026'])).toBe(false);
    expect(inferDayFirst(['01/02/2026', '02/03/2026'])).toBeNull();
    expect(inferDayFirst(['25/09/2026'])).toBe(true);
  });
});

describe('amount parsing', () => {
  it('reads grouping, currency, signs and Dr/Cr markers', () => {
    expect(parseStatementAmount('1,23,456.78')).toEqual({ value: 123456.78, negative: false, marker: null });
    expect(parseStatementAmount('1,234.50')?.value).toBe(1234.5);
    expect(parseStatementAmount('1,234.50 Dr')).toEqual({ value: 1234.5, negative: false, marker: 'debit' });
    expect(parseStatementAmount('500.00CR')?.marker).toBe('credit');
    expect(parseStatementAmount('₹ 1,000.00 CR')).toEqual({ value: 1000, negative: false, marker: 'credit' });
    expect(parseStatementAmount('Rs. 99.00')?.value).toBe(99);
    expect(parseStatementAmount('(250.00)')).toEqual({ value: 250, negative: true, marker: null });
    expect(parseStatementAmount('-99.00')?.negative).toBe(true);
  });

  it('rejects things that are not money', () => {
    expect(parseStatementAmount('')).toBeNull();
    expect(parseStatementAmount(null)).toBeNull();
    expect(parseStatementAmount('abc')).toBeNull();
    expect(parseStatementAmount('12/09/2026')).toBeNull();
    expect(parseStatementAmount('1.2.3')).toBeNull();
    expect(looksLikeMoney('004512')).toBe(false);
    expect(looksLikeMoney('1,250.00')).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Parsing and normalisation
// ---------------------------------------------------------------------------

describe('generic table parser', () => {
  const statement = tableStatement([
    line(685, [['Opening Balance', 110], ['10,000.00', 520]]),
    line(670, [['01/09/2026', 40], ['UPI/DR/612345/SWIGGY', 110], ['612345', 300], ['450.00', 385], ['9,550.00', 520]]),
    line(660, [['BANGALORE', 110]]),
    line(645, [['02/09/2026', 40], ['SALARY SEP ACME CORP', 110], ['50,000.00', 455], ['59,550.00', 520]]),
    line(630, [['03/09/2026', 40], ['BROKEN LINE WITHOUT AMOUNT', 110]]),
    line(615, [['***', 110]]),
  ]);

  it('reads a debit transaction', () => {
    const result = process(statement);
    const debit = result.transactions[0];
    expect(debit).toMatchObject({
      transactionDate: '2026-09-01',
      amount: 450,
      transactionType: 'debit',
      balance: 9550,
      reference: '612345',
      bankAccountId: 'acc-1',
      sourceStatementId: 'st-1',
      confidence: 1,
      kind: 'expense',
      category: 'Food',
    });
    // A wrapped narration line joins its row.
    expect(debit?.description).toBe('UPI/DR/612345/SWIGGY BANGALORE');
  });

  it('reads a credit transaction', () => {
    const credit = process(statement).transactions[1];
    expect(credit).toMatchObject({ amount: 50000, transactionType: 'credit', balance: 59550, kind: 'income', category: 'Salary', confidence: 1 });
  });

  it('skips malformed and empty rows with a warning instead of guessing', () => {
    const result = process(statement);
    expect(result.transactions).toHaveLength(2);
    expect(result.warnings.map((w) => w.code)).toContain('skippedLine');
  });

  it('reads the statement header: account digits, period, opening balance', () => {
    const result = process(statement);
    expect(result.accountLast4).toBe('4821');
    expect(result.period).toEqual({ from: '2026-09-01', to: '2026-09-30' });
    expect(result.periodKind).toBe('monthly');
    expect(result.openingBalance).toBe(10000);
  });

  it('reads Dr/Cr markers when there is no header', () => {
    const result = process(
      doc([
        line(700, [['05-Sep-2026', 40], ['POS AMAZON RETAIL', 110], ['1,299.00 Dr', 380], ['8,251.00 Cr', 480]]),
        line(685, [['06-Sep-2026', 40], ['NEFT FROM CLIENT', 110], ['2,000.00 Cr', 380], ['10,251.00 Cr', 480]]),
      ]),
    );
    expect(result.transactions.map((t) => [t.transactionType, t.amount, t.balance])).toEqual([
      ['debit', 1299, 8251],
      ['credit', 2000, 10251],
    ]);
  });

  it('works out direction from the running balance, newest-first statements included', () => {
    const result = process(
      doc([
        line(700, [['03/09/2026', 40], ['CARD PAYMENT', 110], ['200.00', 380], ['1,300.00', 480]]),
        line(685, [['02/09/2026', 40], ['TRANSFER IN', 110], ['500.00', 380], ['1,500.00', 480]]),
        line(670, [['01/09/2026', 40], ['OPENING DEPOSIT', 110], ['1,000.00', 380], ['1,000.00', 480]]),
      ]),
    );
    const byDate = Object.fromEntries(result.transactions.map((t) => [t.transactionDate, t]));
    expect(byDate['2026-09-02']?.transactionType).toBe('credit');
    expect(byDate['2026-09-03']?.transactionType).toBe('debit');
    expect(byDate['2026-09-03']?.issues).toContain('Debit or credit worked out from the balance');
    expect(byDate['2026-09-03']?.confidence).toBeLessThan(1);
  });

  it('flags a row whose direction cannot be known rather than hiding it', () => {
    const result = process(doc([line(700, [['01/09/2026', 40], ['SOMETHING', 110], ['75.00', 380]])]));
    expect(result.transactions[0]?.confidence).toBeLessThan(0.6);
    expect(result.warnings.map((w) => w.code)).toContain('unknownDirection');
  });

  it('flags a running balance that does not add up', () => {
    const result = process(
      tableStatement([
        line(685, [['Opening Balance', 110], ['1,000.00', 520]]),
        line(670, [['01/09/2026', 40], ['GROCERY', 110], ['100.00', 385], ['800.00', 520]]),
      ]),
    );
    expect(result.transactions[0]?.issues).toContain('The running balance does not add up here');
    expect(result.warnings.map((w) => w.code)).toContain('balanceMismatch');
  });

  it('reports a document with no transactions', () => {
    const parsed = genericTableParser.parse(doc([line(700, [['Nothing here', 40]])]));
    expect(parsed.rows).toHaveLength(0);
    expect(parsed.warnings.map((w) => w.code)).toContain('noTransactions');
  });
});

describe('statement periods', () => {
  it('names weekly, fortnightly and monthly spans', () => {
    expect(periodKindOf({ from: '2026-09-01', to: '2026-09-07' })).toBe('weekly');
    expect(periodKindOf({ from: '2026-09-01', to: '2026-09-15' })).toBe('fortnightly');
    expect(periodKindOf({ from: '2026-09-01', to: '2026-09-30' })).toBe('monthly');
    expect(periodKindOf({ from: '2026-09-01', to: '2026-11-30' })).toBe('custom');
  });
});

describe('text layout', () => {
  it('groups fragments into lines and keeps column gaps as separate cells', () => {
    const lines = groupFragments(
      [
        { text: '01/09/2026', x: 40, y: 700, width: 45, height: 9 },
        { text: 'UPI/DR/', x: 110, y: 700.6, width: 30, height: 9 },
        { text: 'SWIGGY', x: 141, y: 700, width: 30, height: 9 },
        { text: '450.00', x: 385, y: 699.8, width: 27, height: 9 },
        { text: ' ', x: 420, y: 700, width: 3, height: 9 },
        { text: 'Next line', x: 40, y: 685, width: 40, height: 9 },
      ],
      1,
    );
    expect(lines).toHaveLength(2);
    expect(lines[0]?.cells.map((c) => c.text)).toEqual(['01/09/2026', 'UPI/DR/SWIGGY', '450.00']);
    expect(lines[1]?.text).toBe('Next line');
  });
});

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

describe('classification', () => {
  const ctx = { categories: CATEGORIES, otherAccountLast4: ['7788'] };
  const classify = (description: string, transactionType: 'debit' | 'credit') =>
    classifyTransaction({ description, rawDescription: description, transactionType }, ctx);

  it('maps obvious merchants to the user’s own categories', () => {
    expect(classify('UPI/DR/1/ZOMATO', 'debit')).toMatchObject({ kind: 'expense', category: 'Food', categorySource: 'rule' });
    expect(classify('SMS ALERT CHARGES', 'debit')).toMatchObject({ kind: 'expense', category: 'Bills' });
  });

  it('puts unknown transactions in Other', () => {
    expect(classify('XYZ 998877 QWERTY', 'debit')).toMatchObject({ kind: 'expense', category: 'Other', categorySource: 'fallback' });
    const noOther = classifyTransaction(
      { description: 'XYZ', rawDescription: 'XYZ', transactionType: 'debit' },
      { categories: [category('c-food', 'Food')], otherAccountLast4: [] },
    );
    expect(noOther).toMatchObject({ kind: 'expense', category: null, categorySource: 'none' });
  });

  it('treats credits as income, refunds separately', () => {
    expect(classify('INTEREST PAID', 'credit')).toMatchObject({ kind: 'income', category: 'Interest' });
    expect(classify('NEFT FROM A FRIEND', 'credit')).toMatchObject({ kind: 'income', category: null });
    expect(classify('REFUND AMAZON ORDER', 'credit')).toMatchObject({ kind: 'refund' });
  });

  it('keeps own-account transfers, cash withdrawals and card bills out of spending', () => {
    expect(classify('IMPS TO XXXX7788 SAVINGS', 'debit').kind).toBe('transfer');
    expect(classify('SELF TRANSFER', 'credit').kind).toBe('transfer');
    expect(classify('ATM CASH WDL MG ROAD', 'debit').kind).toBe('transfer');
    expect(classify('CREDIT CARD PAYMENT HDFC', 'debit').kind).toBe('transfer');
  });
});

// ---------------------------------------------------------------------------
// Duplicate protection
// ---------------------------------------------------------------------------

function tx(id: string, statement: string, date: string, amount: number, description: string, type: 'debit' | 'credit' = 'debit'): NormalizedTransaction {
  const base = { bankAccountId: 'acc-1', transactionDate: date, amount, transactionType: type, rawDescription: description };
  return {
    ...base,
    id,
    description,
    balance: null,
    kind: type === 'debit' ? 'expense' : 'income',
    category: 'Food',
    categorySource: 'rule',
    categoryReason: null,
    sourceStatementId: statement,
    reference: null,
    counterparty: null,
    channel: null,
    confidence: 1,
    issues: [],
    fingerprint: fingerprintOf(base),
    duplicate: null,
  };
}

const existing = (date: string, amount: number, description: string | null, direction: 'debit' | 'credit' = 'debit'): ExistingMovement => ({
  accountId: 'acc-1',
  date,
  amount,
  direction,
  description,
});

describe('duplicate protection', () => {
  it('uses a deterministic fingerprint of account, date, amount, direction and description', () => {
    const a = tx('a', 's', '2026-09-05', 20, 'UPI/DR/1/TEA  STALL');
    const b = tx('b', 't', '2026-09-05', 20.0, 'upi dr 1 tea stall');
    expect(a.fingerprint).toBe('acc-1|2026-09-05|2000|debit|upi dr 1 tea stall');
    expect(a.fingerprint).toBe(b.fingerprint);
    expect(tx('c', 's', '2026-09-05', 20, 'TEA STALL', 'credit').fingerprint).not.toBe(a.fingerprint);
  });

  it('removes rows repeated by overlapping statements, but keeps genuine repeats', () => {
    const weekly = [tx('w1', 'weekly', '2026-09-05', 20, 'TEA'), tx('w2', 'weekly', '2026-09-05', 20, 'TEA'), tx('w3', 'weekly', '2026-09-06', 99, 'BOOK')];
    const monthly = [
      tx('m1', 'monthly', '2026-09-05', 20, 'TEA'),
      tx('m2', 'monthly', '2026-09-05', 20, 'TEA'),
      tx('m3', 'monthly', '2026-09-05', 20, 'TEA'), // a third tea only the monthly statement shows
      tx('m4', 'monthly', '2026-09-06', 99, 'BOOK'),
      tx('m5', 'monthly', '2026-09-20', 450, 'FUEL'),
    ];
    const marked = markDuplicates([...weekly, ...monthly], []);
    const overlap = marked.filter((t) => t.duplicate?.type === 'overlap').map((t) => t.id);
    expect(overlap).toEqual(['m1', 'm2', 'm4']);
    expect(marked.find((t) => t.id === 'm3')?.duplicate).toBeNull();
    expect(marked.find((t) => t.id === 'm5')?.duplicate).toBeNull();
  });

  it('matches rows already in the ledger one-to-one', () => {
    const incoming = [tx('a', 's', '2026-09-05', 20, 'TEA'), tx('b', 's', '2026-09-05', 20, 'TEA'), tx('c', 's', '2026-09-07', 300, 'UPI/DR/9/SWIGGY')];
    const marked = markDuplicates(incoming, [existing('2026-09-05', 20, 'TEA'), existing('2026-09-07', 300, 'Swiggy dinner')]);
    expect(marked[0]?.duplicate).toEqual({ type: 'existing', strength: 'exact', existingLabel: 'TEA' });
    expect(marked[1]?.duplicate).toBeNull(); // only one tea was recorded
    expect(marked[2]?.duplicate).toMatchObject({ type: 'existing', strength: 'likely' });
  });

  it('never matches across direction or account', () => {
    const marked = markDuplicates(
      [tx('a', 's', '2026-09-05', 500, 'X', 'credit'), tx('b', 's', '2026-09-05', 500, 'X')],
      [existing('2026-09-05', 500, 'X', 'debit'), { ...existing('2026-09-05', 500, 'X', 'credit'), accountId: 'acc-2' }],
    );
    expect(marked[0]?.duplicate).toBeNull();
    expect(marked[1]?.duplicate).toMatchObject({ type: 'existing', strength: 'exact' });
  });

  it('flags a same-amount entry a day or two away without deselecting it', () => {
    const marked = markDuplicates([tx('a', 's', '2026-09-05', 1299, 'AMAZON')], [existing('2026-09-04', 1299, 'Amazon order')]);
    expect(marked[0]?.duplicate).toMatchObject({ type: 'nearby', existingDate: '2026-09-04' });
    expect(toReviewItems(marked, CATEGORIES)[0]?.selected).toBe(true);
  });

  it('an overlapping statement read end to end imports each row once', () => {
    const rowsA = [
      line(670, [['01/09/2026', 40], ['UPI/DR/1/SWIGGY', 110], ['450.00', 385], ['9,550.00', 520]]),
      line(655, [['05/09/2026', 40], ['NETFLIX', 110], ['649.00', 385], ['8,901.00', 520]]),
    ];
    const rowsB = [...rowsA, line(640, [['12/09/2026', 40], ['ELECTRICITY BILL', 110], ['1,200.00', 385], ['7,701.00', 520]])];
    const a = process(tableStatement(rowsA), 'weekly');
    const b = process(tableStatement(rowsB), 'fortnightly');
    const marked = markDuplicates([...a.transactions, ...b.transactions], []);
    const items = toReviewItems(marked, CATEGORIES);
    expect(items.filter((i) => i.selected).map((i) => i.description)).toEqual(['UPI/DR/1/SWIGGY', 'NETFLIX', 'ELECTRICITY BILL']);
    expect(summarize(items).duplicates).toBe(2);
  });
});

// ---------------------------------------------------------------------------
// Review and import confirmation
// ---------------------------------------------------------------------------

describe('review and import', () => {
  const incoming = markDuplicates(
    [
      tx('e1', 's', '2026-09-01', 450, 'UPI SWIGGY'),
      tx('i1', 's', '2026-09-02', 50000, 'SALARY', 'credit'),
      { ...tx('r1', 's', '2026-09-03', 120, 'REFUND', 'credit'), kind: 'refund' as const },
      { ...tx('t1', 's', '2026-09-04', 2000, 'ATM WDL'), kind: 'transfer' as const },
      tx('d1', 's', '2026-09-05', 20, 'TEA'),
    ],
    [existing('2026-09-05', 20, 'TEA')],
  );
  const categories = CATEGORIES;

  it('summarises what was found before anything is written', () => {
    const items = toReviewItems(incoming, categories);
    expect(summarize(items)).toMatchObject({
      total: 5,
      income: { count: 1, amount: 50000 },
      // The recorded tea is a duplicate, counted on its own — not as a new expense.
      expense: { count: 1, amount: 450 },
      refunds: 1,
      transfers: 1,
      duplicates: 1,
      selected: 4,
    });
  });

  it('imports only what is selected, each kind to its own place', () => {
    let items = toReviewItems(incoming, categories);
    items = reviewReducer(items, { type: 'edit', id: 'i1', patch: { category: 'Salary' } });
    const plan = buildImportPlan(items, { fallbackCategoryId: 'c-other' });
    expect(plan.operations.map((op) => [op.type, op.itemId])).toEqual([
      ['expense', 'e1'],
      ['income', 'i1'],
      ['movement', 'r1'],
      ['movement', 't1'],
    ]);
    expect(plan.operations[0]).toMatchObject({ categoryId: 'c-food', bankAccountId: 'acc-1', notes: STATEMENT_NOTE });
    expect(plan.operations[1]).toMatchObject({ source: 'Salary', amount: 50000 });
    expect(plan.operations[2]).toMatchObject({ direction: 'credit' });
    expect(plan.operations[3]).toMatchObject({ direction: 'debit' });
  });

  it('select all / deselect all, and a deliberately included duplicate', () => {
    let items = toReviewItems(incoming, categories);
    items = reviewReducer(items, { type: 'setSelected', ids: items.map((i) => i.id), selected: false });
    expect(buildImportPlan(items, { fallbackCategoryId: null }).operations).toHaveLength(0);
    items = reviewReducer(items, { type: 'toggle', id: 'd1' });
    expect(items.find((i) => i.id === 'd1')).toMatchObject({ selected: true, duplicateOverridden: true });
  });

  it('edits and removals change the plan', () => {
    let items = toReviewItems(incoming, categories);
    items = reviewReducer(items, { type: 'edit', id: 'e1', patch: { amount: 460, categoryId: 'c-shop', description: 'Dinner' } });
    items = reviewReducer(items, { type: 'remove', id: 't1' });
    const plan = buildImportPlan(items, { fallbackCategoryId: null });
    expect(plan.operations.find((op) => op.itemId === 'e1')).toMatchObject({ amount: 460, categoryId: 'c-shop', description: 'Dinner' });
    expect(plan.operations.some((op) => op.itemId === 't1')).toBe(false);
    // Switching money-out to money-in moves an expense to income.
    items = reviewReducer(items, { type: 'edit', id: 'e1', patch: { transactionType: 'credit' } });
    expect(items.find((i) => i.id === 'e1')?.kind).toBe('income');
  });

  it('a retried ledger check deselects newly found duplicates', () => {
    let items = toReviewItems(markDuplicates(incoming, []), categories); // the first check could not reach the ledger
    items = reviewReducer(items, { type: 'toggle', id: 'e1' }); // user deselects …
    items = reviewReducer(items, { type: 'toggle', id: 'e1' }); // … and re-selects it
    const retried = markDuplicates(items, [existing('2026-09-05', 20, 'TEA'), existing('2026-09-01', 450, 'UPI SWIGGY')]);
    items = reviewReducer(items, { type: 'applyDuplicates', marked: retried });
    expect(items.find((i) => i.id === 'd1')).toMatchObject({ selected: false, duplicate: { type: 'existing' } });
    expect(items.find((i) => i.id === 'e1')).toMatchObject({ selected: false, duplicate: { type: 'existing' } });
    expect(items.find((i) => i.id === 'i1')?.selected).toBe(true);
  });

  it('skips an expense with no category rather than inventing one', () => {
    const items = toReviewItems([tx('x', 's', '2026-09-01', 10, 'MYSTERY')], [category('c-food', 'Food')]).map((i) => ({ ...i, categoryId: null }));
    const plan = buildImportPlan(items, { fallbackCategoryId: null });
    expect(plan.operations).toHaveLength(0);
    expect(plan.skipped).toEqual([{ itemId: 'x', reason: 'Choose a category' }]);
  });

  it('drops rows recorded since review started, but keeps a duplicate the user chose to import', () => {
    let items = toReviewItems(incoming, categories);
    items = reviewReducer(items, { type: 'toggle', id: 'd1' }); // import the tea anyway
    const plan = buildImportPlan(items, { fallbackCategoryId: 'c-other' });
    const fresh = [existing('2026-09-05', 20, 'TEA'), existing('2026-09-01', 450, 'UPI SWIGGY')]; // swiggy added meanwhile
    const final = withoutNewlyRecorded(plan, items, fresh);
    expect(final.operations.map((op) => op.itemId)).toEqual(['i1', 'r1', 't1', 'd1']);
    expect(final.skipped).toEqual([{ itemId: 'e1', reason: 'Already recorded' }]);
  });
});
