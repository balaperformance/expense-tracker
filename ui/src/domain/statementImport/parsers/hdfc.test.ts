/**
 * HDFC parser. Every row here is synthetic — invented payees, handles,
 * references and figures — but shaped exactly like HDFC's statement layout.
 */
import { describe, expect, it } from 'vitest';

import type { BankAccount, ExpenseCategory, PaymentMethod } from '../../models';
import { markDuplicates } from '../duplicates';
import { buildImportPlan } from '../importPlan';
import type { ExtractedDocument, TextLine } from '../model';
import { selectParser } from '../parser';
import { processStatement } from '../pipeline';
import { toReviewItems } from '../review';

import { genericTableParser } from './genericTable';
import { hdfcParser, interpretHdfcNarration } from './hdfc';
import { BANK_PARSERS, FALLBACK_PARSER } from './index';

const ACCOUNT: BankAccount = {
  id: 'acc-hdfc',
  userId: 'u1',
  bankName: 'HDFC Bank',
  nickname: 'Salary',
  last4: '1234',
  openingBalance: 0,
  isActive: true,
  createdAt: null,
};
const category = (id: string, name: string): ExpenseCategory => ({ id, userId: 'u1', name, icon: 'category', color: '#78909C', isDefault: true, createdAt: null });
const CATEGORIES = [category('c-food', 'Food'), category('c-bills', 'Bills'), category('c-shop', 'Shopping'), category('c-other', 'Other')];
const METHODS: PaymentMethod[] = [
  { id: 'pm-upi', userId: 'u1', name: 'UPI', createdAt: null },
  { id: 'pm-dc', userId: 'u1', name: 'Debit Card', createdAt: null },
  { id: 'pm-nb', userId: 'u1', name: 'Net Banking', createdAt: null },
];

// ---------------------------------------------------------------------------
// Layouts
// ---------------------------------------------------------------------------

const HEADINGS = ['Date', 'Narration', 'Chq./Ref.No.', 'Value Dt', 'Withdrawal Amt.', 'Deposit Amt.', 'Closing Balance'];
const RULERS = ['********', '**********', '************', '********', '***************', '************', '***************'];
type Row = [date: string, narration: string, ref: string, valueDate: string, withdrawal: string, deposit: string, balance: string];

/** The spreadsheet download: one cell per column (x = column × 100), empty cells absent. */
function sheetLine(row: number, values: readonly string[]): TextLine {
  const cells = values.map((text, col) => ({ text, x: col * 100, width: 90 })).filter((c) => c.text);
  return { page: 1, y: -row * 12, cells, text: cells.map((c) => c.text).join(' ') };
}

function spreadsheet(rows: readonly Row[], banner = 'HDFC BANK Ltd.          Page No .:   1          Statement of accounts'): ExtractedDocument {
  return {
    pageCount: 1,
    source: 'spreadsheet',
    lines: [sheetLine(1, [banner]), sheetLine(2, ['*'.repeat(60)]), sheetLine(3, HEADINGS), sheetLine(4, RULERS), ...rows.map((r, i) => sheetLine(5 + i, r))],
  };
}

// Synthetic rows. Balance runs from 50,000.00 and every row adds up.
const ROWS: Row[] = [
  ['01/09/26', 'UPI-ANITHA STORES-anithastores@okicici-ICIC0001234-612345678901-UPI', '0000612345678901', '01/09/26', '2900', '', '47100'],
  ['02/09/26', 'UPI-SWIGGY-swiggy.stores@axisbank-UTIB0000100-612345678902-Payment from Phone', '0000612345678902', '02/09/26', '485.50', '', '46614.50'],
  ['03/09/26', 'UPI-RAVI KUMAR-ravik@okaxis-HDFC0000999-612345678903-UPI', '0000612345678903', '03/09/26', '', '1500', '48114.50'],
  ['04/09/26', 'NWD-512345XXXXXX9876-S1ACME01-CHENNAI', '0000001234567890', '04/09/26', '2000', '', '46114.50'],
  ['05/09/26', 'ATW-512345XXXXXX9876-S1HDFC02-MUMBAI', '0000001234567891', '05/09/26', '1000', '', '45114.50'],
  ['05/09/26', 'EMI 99887766 CHQ S999887766001 0926999887766', '000000999887766', '05/09/26', '5250', '', '39864.50'],
  ['06/09/26', 'DPI 99887766 CHQ S999887766002 0926999887766', '000000999887766', '06/09/26', '118', '', '39746.50'],
  ['07/09/26', 'NEFT DR-SBIN0001234-SAMPLE PAYEE-NETBANK, MUM-HDFCN12345678901-RENT', 'HDFCN12345678901', '07/09/26', '12000', '', '27746.50'],
  ['08/09/26', 'POS 416021XXXXXX9876 SWIGGY BANGALORE', '0000009876543210', '08/09/26', '349', '', '27397.50'],
  ['09/09/26', 'CC 000512345XXXXXX9876 AUTOPAY SI-TAD', '0000009876543211', '09/09/26', '3000', '', '24397.50'],
  ['10/09/26', 'ACH D- SAMPLE MUTUAL FUND-SIP12345', '0000009876543212', '10/09/26', '1000', '', '23397.50'],
  ['12/09/26', 'REV-UPI-ANITHA STORES-anithastores@okicici-ICIC0001234-612345678901-UPI', '0000612345678901', '12/09/26', '', '2900', '26297.50'],
  ['15/09/26', 'UPI-A-ONE TRADERS-aonetraders@ybl-YESB0YBLUPI-612345678904-UPI', '0000612345678904', '15/09/26', '250', '', '26047.50'],
  ['20/09/26', 'DC INTL POS TXN MARKUP+ST 150926-MU', '0000009876543213', '20/09/26', '35.40', '', '26012.10'],
  ['30/09/26', 'CREDIT INTEREST CAPITALISED', '000000000000000', '30/09/26', '', '112', '26124.10'],
];

const process = (doc: ExtractedDocument, statementId = 'hdfc-sep') =>
  processStatement({ doc, statementId, fileName: `${statementId}.xlsx`, account: ACCOUNT, accounts: [ACCOUNT], categories: CATEGORIES });

// ---------------------------------------------------------------------------

describe('HDFC detection', () => {
  it('claims HDFC statements and nothing else', () => {
    expect(hdfcParser.detect(spreadsheet(ROWS))).toBeGreaterThan(0.9);
    expect(selectParser(spreadsheet(ROWS), BANK_PARSERS, FALLBACK_PARSER).parser.id).toBe('hdfc-bank');
    // HDFC's headings without HDFC named anywhere are not proof.
    expect(hdfcParser.detect(spreadsheet(ROWS, 'Statement of accounts'))).toBe(0);
    const unrelated: ExtractedDocument = { pageCount: 1, source: 'pdf-text', lines: [sheetLine(1, ['Txn Date', 'Details', 'Debit', 'Credit', 'Balance'])] };
    expect(selectParser(unrelated, BANK_PARSERS, FALLBACK_PARSER).parser).toBe(genericTableParser);
  });
});

describe('HDFC spreadsheet statement', () => {
  const result = process(spreadsheet(ROWS));
  const byDate = (narrationStart: string) => result.transactions.find((t) => t.rawDescription.startsWith(narrationStart));

  it('reads every row, skipping the banner and asterisk rulers', () => {
    expect(result.parserId).toBe('hdfc-bank');
    expect(result.bankName).toBe('HDFC Bank');
    expect(result.transactions).toHaveLength(ROWS.length);
    expect(result.warnings).toEqual([]);
  });

  it('maps Withdrawal Amt. to debit and Deposit Amt. to credit, whole-number amounts included', () => {
    expect(byDate('UPI-ANITHA')).toMatchObject({ transactionType: 'debit', amount: 2900, balance: 47100 });
    expect(byDate('UPI-SWIGGY')).toMatchObject({ transactionType: 'debit', amount: 485.5, balance: 46614.5 });
    expect(byDate('UPI-RAVI')).toMatchObject({ transactionType: 'credit', amount: 1500, balance: 48114.5 });
  });

  it('preserves date, narration, reference and balance — and every balance adds up', () => {
    const first = result.transactions[0];
    expect(first).toMatchObject({
      transactionDate: '2026-09-01',
      rawDescription: ROWS[0]?.[1],
      reference: '0000612345678901',
      balance: 47100,
    });
    // The value date is its own column, never part of the narration.
    expect(first?.description).not.toMatch(/01\/09\/26/);
    expect(result.transactions.every((t) => t.confidence === 1 && t.issues.length === 0)).toBe(true);
  });

  it('picks out the UPI payee, hyphenated names included', () => {
    expect(byDate('UPI-ANITHA')).toMatchObject({ channel: 'upi', counterparty: 'ANITHA STORES' });
    expect(byDate('UPI-A-ONE')?.counterparty).toBe('A-ONE TRADERS');
    expect(byDate('UPI-SWIGGY')).toMatchObject({ category: 'Food', categorySource: 'rule' });
  });

  it('classifies the common HDFC patterns', () => {
    expect(byDate('NWD-')).toMatchObject({ channel: 'atm', kind: 'transfer' });
    expect(byDate('ATW-')).toMatchObject({ channel: 'atm', kind: 'transfer' });
    expect(byDate('EMI ')).toMatchObject({ channel: 'loan', kind: 'expense', category: 'Bills', categoryReason: 'loan repayment' });
    expect(byDate('DPI ')).toMatchObject({ channel: 'loan', kind: 'expense', category: 'Bills' });
    expect(byDate('NEFT DR-')).toMatchObject({ channel: 'neft', kind: 'expense', counterparty: 'SAMPLE PAYEE' });
    expect(byDate('POS ')).toMatchObject({ channel: 'card', counterparty: 'SWIGGY BANGALORE', category: 'Food' });
    expect(byDate('CC ')).toMatchObject({ channel: 'cardBill', kind: 'transfer' });
    expect(byDate('ACH D-')).toMatchObject({ channel: 'ach', counterparty: 'SAMPLE MUTUAL FUND', kind: 'expense' });
    expect(byDate('REV-UPI-')).toMatchObject({ channel: 'reversal', kind: 'refund', counterparty: 'ANITHA STORES' });
    expect(byDate('DC INTL')).toMatchObject({ channel: 'charges', kind: 'expense', category: 'Bills' });
    expect(byDate('CREDIT INTEREST')).toMatchObject({ channel: 'interest', kind: 'income', category: 'Interest' });
  });

  it('an own-account transfer still wins over the channel', () => {
    const own = { ...ACCOUNT, id: 'acc-2', last4: '5566' };
    const doc = spreadsheet([['01/09/26', 'UPI-SELF-self@okhdfcbank-HDFC0000001-612345678909-To XXXX5566', '0000612345678909', '01/09/26', '5000', '', '45000']]);
    const statement = processStatement({ doc, statementId: 's', fileName: 's.xlsx', account: ACCOUNT, accounts: [ACCOUNT, own], categories: CATEGORIES });
    expect(statement.transactions[0]?.kind).toBe('transfer');
  });
});

describe('HDFC PDF statement', () => {
  // PDF geometry: points, right-aligned amounts, a wrapped narration, the header repeated on page 2.
  const X = { date: 32, narration: 78, ref: 262, valueDt: 342, withdrawal: 392, deposit: 462, balance: 532 };
  const pdfLine = (page: number, y: number, cells: ReadonlyArray<readonly [string, number, number?]>): TextLine => {
    const mapped = cells.map(([text, x, width]) => ({ text, x, width: width ?? text.length * 4.4 }));
    return { page, y, cells: mapped, text: mapped.map((c) => c.text).join(' ') };
  };
  const header = (page: number, y: number) =>
    pdfLine(page, y, [
      ['Date', X.date],
      ['Narration', X.narration],
      ['Chq./Ref.No.', X.ref],
      ['Value Dt', X.valueDt],
      ['Withdrawal Amt.', X.withdrawal, 60],
      ['Deposit Amt.', X.deposit, 55],
      ['Closing Balance', X.balance, 60],
    ]);
  const doc: ExtractedDocument = {
    pageCount: 2,
    source: 'pdf-text',
    lines: [
      pdfLine(1, 800, [['HDFC BANK Ltd.', 32]]),
      pdfLine(1, 780, [['Account No :50100123451234   Customer ID : 12345678', 32]]),
      pdfLine(1, 768, [['Statement From : 01/09/2026 To : 30/09/2026', 32]]),
      header(1, 740),
      pdfLine(1, 725, [['01/09/26', X.date], ['UPI-ANITHA STORES-anithastores@okicici-ICIC', X.narration], ['000061234567', X.ref], ['01/09/26', X.valueDt], ['2,900.00', 420, 32], ['47,100.00', 560, 32]]),
      pdfLine(1, 716, [['0001234-612345678901-UPI', X.narration], ['8901', X.ref]]),
      pdfLine(2, 800, [['HDFC BANK Ltd.', 32]]),
      header(2, 780),
      pdfLine(2, 765, [['03/09/26', X.date], ['UPI-RAVI KUMAR-ravik@okaxis-HDFC0000999-612', X.narration], ['000061234567', X.ref], ['03/09/26', X.valueDt], ['1,500.00', 490, 32], ['48,600.00', 560, 32]]),
      pdfLine(2, 756, [['345678903-UPI', X.narration], ['8903', X.ref]]),
      pdfLine(2, 700, [['STATEMENT SUMMARY :-', 32]]),
      pdfLine(2, 688, [['Opening Balance', 32], ['Dr Count', 120], ['Cr Count', 180], ['Debits', 250], ['Credits', 330], ['Closing Bal', 420]]),
      pdfLine(2, 676, [['50,000.00', 32], ['1', 120], ['1', 180], ['2,900.00', 250], ['1,500.00', 330], ['48,600.00', 420]]),
    ],
  };
  const result = process(doc, 'hdfc-pdf');

  it('reads rows across pages and joins wrapped narration and reference', () => {
    expect(result.parserId).toBe('hdfc-bank');
    expect(result.transactions.map((t) => [t.transactionType, t.amount, t.balance])).toEqual([
      ['debit', 2900, 47100],
      ['credit', 1500, 48600],
    ]);
    expect(result.transactions[0]?.rawDescription).toBe('UPI-ANITHA STORES-anithastores@okicici-ICIC0001234-612345678901-UPI');
    expect(result.transactions[0]?.reference).toBe('0000612345678901');
    expect(result.transactions[0]?.counterparty).toBe('ANITHA STORES');
  });

  it('reads account digits, period and the summary balances', () => {
    expect(result.accountLast4).toBe('1234');
    expect(result.period).toEqual({ from: '2026-09-01', to: '2026-09-30' });
    expect(result.periodKind).toBe('monthly');
    expect(result.openingBalance).toBe(50000);
    expect(result.closingBalance).toBe(48600);
    // The opening balance anchors the first row's balance check too.
    expect(result.transactions.every((t) => t.confidence === 1)).toBe(true);
  });
});

describe('HDFC PDF statement — real NetBanking geometry', () => {
  // Positions measured from a real HDFC PDF (text replaced with synthetic rows). The column
  // headings are centred — "Narration" sits far right of where narrations start — and are
  // printed on page 1 only; later pages repeat the customer block, with "Page No .:" under
  // Chq./Ref.No. A short first narration fragment ("UPI-A") is its own text item.
  type Cell = readonly [text: string, left: number, right?: number];
  const line = (page: number, y: number, cells: readonly Cell[]): TextLine => {
    const mapped = cells.map(([text, left, right]) => ({ text, x: left, width: (right ?? left + text.length * 4.4) - left }));
    return { page, y, cells: mapped, text: mapped.map((c) => c.text).join(' ') };
  };
  const amount = (text: string, right: number): Cell => [text, right - text.length * 4.4, right];
  const W = 470;
  const D = 548;
  const B = 627;
  const row = (page: number, y: number, date: string, narration: Cell, ref: string, money: Cell, balance: string) =>
    line(page, y, [[date, 34, 62], narration, [ref, 289, 353], [date, 362, 391], money, amount(balance, B)]);
  const customerBlock = (page: number): TextLine[] => [
    line(page, 820, [[`Page No .: ${String(page)}`, 292, 332]]),
    line(page, 810, [['Account Branch : SAMPLE BRANCH', 340, 463]]),
    line(page, 800, [['Address', 340, 366], [': HDFC BANK LTD,', 397, 468]]),
    line(page, 790, [['Account No', 340, 379], [': 50100123451234', 397, 459], ['OTHER', 465, 526]]),
    line(page, 780, [['From : 01/09/2026', 34, 98], ['To : 30/09/2026', 154, 210], ['Statement of account', 340, 441]]),
  ];
  const footer = (page: number): TextLine[] => [
    line(page, 60, [['HDFC BANK LIMITED', 28, 124]]),
    line(page, 50, [['*Closing balance includes funds earmarked for hold and uncleared funds', 28, 262]]),
  ];
  const doc: ExtractedDocument = {
    pageCount: 2,
    source: 'pdf-text',
    lines: [
      ...customerBlock(1),
      line(1, 760, [['Date', 40, 56], ['Narration', 144, 178], ['Chq./Ref.No.', 284, 328], ['Value Dt', 362, 392], ['Withdrawal Amt.', 405, 466], ['Deposit Amt.', 491, 536], ['Closing Balance', 564, 619]]),
      row(1, 740, '01/09/26', ['UPI-A', 72, 92], '0000612345678901', amount('250.00', W), '9,750.00'),
      line(1, 731, [['NITHA STORES-anithastores@okicici-ICIC', 68, 233]]),
      line(1, 722, [['0001234-612345678901-UPI', 72, 196]]),
      row(1, 710, '02/09/26', ['UPI-SWIGGY', 72, 120], '0000612345678902', amount('485.50', W), '9,264.50'),
      line(1, 701, [['-swiggy.stores@axisbank-UTIB0000100-6', 68, 230]]),
      line(1, 692, [['12345678902-UPI', 72, 150]]),
      row(1, 680, '03/09/26', ['UPI-RAVI KUMAR-ravik@okaxis-HDFC0000999-', 68, 258], '0000612345678903', amount('1,500.00', D), '10,764.50'),
      line(1, 671, [['612345678903-UPI', 72, 150]]),
      row(1, 660, '04/09/26', ['NEFT DR-SBIN0001234-SAMPLE PAYEE-NETBANK', 72, 252], 'HDFCN12345678901', amount('2,000.00', W), '8,764.50'),
      ...footer(1),
      ...customerBlock(2),
      // The NEFT narration wraps across the page break.
      line(2, 760, [[', MUM-HDFCN12345678901-RENT', 72, 224]]),
      row(2, 745, '05/09/26', ['ATW-512345XXXXXX9876-S1HDFC02-MUMBAI', 68, 260], '0000001234567891', amount('1,000.00', W), '7,764.50'),
      line(2, 700, [['STATEMENT SUMMARY :-', 68, 198]]),
      line(2, 688, [['Opening Balance', 132, 191], ['Dr Count', 290, 322], ['Cr Count', 361, 393], ['Debits', 425, 447], ['Credits', 501, 526], ['Closing Bal', 572, 611]]),
      line(2, 676, [['10,000.00', 144, 180], ['4', 302, 310], ['1', 373, 381], ['3,735.50', 418, 454], ['1,500.00', 498, 530], ['7,764.50', 576, 608]]),
      ...footer(2),
    ],
  };
  const result = process(doc, 'hdfc-real-layout');

  it('reads every row — short first narration fragments included — and every balance adds up', () => {
    expect(result.parserId).toBe('hdfc-bank');
    expect(result.warnings).toEqual([]);
    expect(result.transactions.map((t) => [t.transactionDate, t.transactionType, t.amount, t.balance])).toEqual([
      ['2026-09-01', 'debit', 250, 9750],
      ['2026-09-02', 'debit', 485.5, 9264.5],
      ['2026-09-03', 'credit', 1500, 10764.5],
      ['2026-09-04', 'debit', 2000, 8764.5],
      ['2026-09-05', 'debit', 1000, 7764.5],
    ]);
    expect(result.transactions.every((t) => t.confidence === 1 && t.issues.length === 0)).toBe(true);
    expect(result.openingBalance).toBe(10000);
    expect(result.closingBalance).toBe(7764.5);
  });

  it('joins wrapped narration, across the page break too, and keeps references as printed', () => {
    expect(result.transactions.map((t) => t.rawDescription)).toEqual([
      'UPI-ANITHA STORES-anithastores@okicici-ICIC0001234-612345678901-UPI',
      'UPI-SWIGGY-swiggy.stores@axisbank-UTIB0000100-612345678902-UPI',
      'UPI-RAVI KUMAR-ravik@okaxis-HDFC0000999-612345678903-UPI',
      'NEFT DR-SBIN0001234-SAMPLE PAYEE-NETBANK, MUM-HDFCN12345678901-RENT',
      'ATW-512345XXXXXX9876-S1HDFC02-MUMBAI',
    ]);
    // "Page No .: 2" under the reference column is page furniture, not the NEFT row's reference.
    expect(result.transactions.map((t) => t.reference)).toEqual(['0000612345678901', '0000612345678902', '0000612345678903', 'HDFCN12345678901', '0000001234567891']);
    expect(result.transactions.map((t) => [t.channel, t.counterparty])).toEqual([
      ['upi', 'ANITHA STORES'],
      ['upi', 'SWIGGY'],
      ['upi', 'RAVI KUMAR'],
      ['neft', 'SAMPLE PAYEE'],
      ['atm', null],
    ]);
  });

  it('matches the same rows from the Excel download exactly', () => {
    const sheet = process(
      spreadsheet(
        result.transactions.map((t) => [
          t.transactionDate.slice(8) + '/' + t.transactionDate.slice(5, 7) + '/' + t.transactionDate.slice(2, 4),
          t.rawDescription,
          t.reference ?? '',
          '',
          t.transactionType === 'debit' ? String(t.amount) : '',
          t.transactionType === 'credit' ? String(t.amount) : '',
          String(t.balance),
        ]),
      ),
      'hdfc-xlsx',
    );
    expect(result.transactions.map((t) => t.fingerprint)).toEqual(sheet.transactions.map((t) => t.fingerprint));
  });

  it('warns about an undated line that carries amounts instead of dropping it silently', () => {
    const header = doc.lines[5];
    if (!header) throw new Error('fixture');
    const broken = process(
      { pageCount: 1, source: 'pdf-text', lines: [...customerBlock(1), header, row(1, 740, '0I/09/26', ['UPI-A', 72, 92], '0000612345678901', amount('250.00', W), '9,750.00')] },
      'hdfc-broken',
    );
    expect(broken.transactions).toHaveLength(0);
    expect(broken.warnings.map((w) => w.code)).toContain('skippedLine');
  });
});

describe('HDFC with duplicate protection and import', () => {
  it('a re-uploaded statement is entirely duplicate', () => {
    const a = process(spreadsheet(ROWS), 'first');
    const b = process(spreadsheet(ROWS), 'again');
    const marked = markDuplicates([...a.transactions, ...b.transactions], []);
    expect(marked.filter((t) => t.duplicate?.type === 'overlap')).toHaveLength(ROWS.length);
  });

  it('matches an earlier import exactly, whose ledger row carries the payee', () => {
    const [first] = process(spreadsheet(ROWS)).transactions;
    const marked = markDuplicates(process(spreadsheet(ROWS)).transactions.slice(0, 1), [
      { accountId: ACCOUNT.id, date: '2026-09-01', amount: 2900, direction: 'debit', description: first?.counterparty ?? null },
    ]);
    expect(marked[0]?.duplicate).toMatchObject({ type: 'existing', strength: 'exact' });
  });

  it('imports payee as merchant, the channel as payment method, and cash / card bills as balance-only', () => {
    const items = toReviewItems(process(spreadsheet(ROWS)).transactions, CATEGORIES);
    const plan = buildImportPlan(items, { fallbackCategoryId: 'c-other', paymentMethods: METHODS });
    const op = (start: string) => plan.operations.find((o) => items.find((i) => i.id === o.itemId)?.rawDescription.startsWith(start));
    expect(op('UPI-ANITHA')).toMatchObject({ type: 'expense', merchant: 'ANITHA STORES', paymentMethodId: 'pm-upi', description: ROWS[0]?.[1] });
    expect(op('POS ')).toMatchObject({ type: 'expense', paymentMethodId: 'pm-dc', categoryId: 'c-food' });
    expect(op('NEFT DR-')).toMatchObject({ type: 'expense', merchant: 'SAMPLE PAYEE', paymentMethodId: 'pm-nb' });
    expect(op('UPI-RAVI')).toMatchObject({ type: 'income', source: 'RAVI KUMAR' });
    expect(op('CREDIT INTEREST')).toMatchObject({ type: 'income', source: 'Interest' });
    expect(op('NWD-')).toMatchObject({ type: 'movement', direction: 'debit' });
    expect(op('CC ')).toMatchObject({ type: 'movement', direction: 'debit' });
    expect(op('REV-UPI-')).toMatchObject({ type: 'movement', direction: 'credit' });
  });
});

describe('HDFC UPI payee', () => {
  // Synthetic names; the shapes are HDFC's. The VPA's numeric suffix ("-2@…") splits the handle.
  it.each([
    ['UPI-SAMPLEP-SAMPLEPAYEE183-2@OKAXIS-HDFC0001234-612345678910-UPI', 'SAMPLEP'],
    ['UPI-SAMPLE PERSON-SAMPLEPERSON-1@OKAXIS-SBIN0001234-612345678911-UPI', 'SAMPLE PERSON'],
    ['UPI-S SAMPLENAME-SAMPLENAMEFULL4-1@OKSBI-SBIN0012345-612345678912-Payment', 'S SAMPLENAME'],
    ['UPI-A-ONE TRADERS-aonetraders-12@ybl-YESB0YBLUPI-612345678913-UPI', 'A-ONE TRADERS'],
    // Without a numeric suffix nothing changes: hyphenated names and phone-number VPAs stay whole.
    ['UPI-A-ONE TRADERS-aonetraders@ybl-YESB0YBLUPI-612345678914-UPI', 'A-ONE TRADERS'],
    ['UPI-P SAMPLE-9000000001@AXL-SBIN0002196-612345678915-PAY', 'P SAMPLE'],
    ['UPI-A-ONE-9000000002@ybl-YESB0YBLUPI-612345678916-UPI', 'A-ONE'],
    // A suffix right after UPI- leaves no name to trim; a VPA with no name is no payee.
    ['UPI-SHOP-1@ybl-YESB0YBLUPI-612345678917-UPI', 'SHOP'],
    ['UPI-9000000003@ybl-YESB0YBLUPI-612345678918-UPI', null],
    ['REV-UPI-SAMPLEP-SAMPLEPAYEE183-2@OKAXIS-HDFC0001234-612345678919-UPI', 'SAMPLEP'],
  ])('%s', (narration, counterparty) => {
    expect(interpretHdfcNarration(narration).counterparty).toBe(counterparty);
  });

  it('keeps the full narration as the description and puts only the name in merchant/source', () => {
    const narration = 'UPI-SAMPLEP-SAMPLEPAYEE183-2@OKAXIS-HDFC0001234-612345678910-UPI';
    const statement = process(spreadsheet([['11/09/26', narration, '0000612345678910', '11/09/26', '', '140', '50140']]));
    const t = statement.transactions[0];
    expect(t).toMatchObject({ rawDescription: narration, counterparty: 'SAMPLEP', kind: 'income' });
    const plan = buildImportPlan(toReviewItems(statement.transactions, CATEGORIES), { fallbackCategoryId: 'c-other', paymentMethods: METHODS });
    expect(plan.operations[0]).toMatchObject({ type: 'income', source: 'SAMPLEP', description: narration });
  });
});

describe('HDFC narration codes', () => {
  it.each([
    ['UPI-SHOP-shop@okhdfcbank-HDFC0000001-612345678905-UPI', 'upi', 'SHOP'],
    ['UPIRET-612345678906-SHOP', 'reversal', null],
    ['IMPS-612345678907-SAMPLE NAME-SBIN-XXXXXXX4321-GIFT', 'imps', 'SAMPLE NAME'],
    ['RTGS CR-ICIC0000001-SAMPLE CORP-SAMPLE HOLDER-ICICR12345678901', 'rtgs', 'SAMPLE CORP'],
    ['EAW-512345XXXXXX9876-S1ACME03-PUNE', 'atm', null],
    ['CHQ DEP - MICR CLG - CHENNAI', 'cheque', null],
    ['CASH DEPOSIT BY - SELF', 'cash', null],
    ['FT - DR - 50100999999999 - SAMPLE', 'internal', null],
    ['SOMETHING UNFAMILIAR', null, null],
  ])('%s', (narration, channel, counterparty) => {
    expect(interpretHdfcNarration(narration)).toEqual({ channel, counterparty });
  });
});
