/**
 * Airtel Payments Bank parser. Every row here is synthetic — invented UPI IDs,
 * transaction IDs and figures — but laid out at the positions measured from a
 * real statement, with Particulars cut into 26-character pieces the way Airtel
 * prints them, and read through the same line grouping as a real PDF.
 */
import { describe, expect, it } from 'vitest';

import type { BankAccount, ExpenseCategory, PaymentMethod } from '../../models';
import { markDuplicates } from '../duplicates';
import { buildImportPlan } from '../importPlan';
import { groupFragments, type TextFragment } from '../layout';
import type { ExtractedDocument } from '../model';
import { selectParser } from '../parser';
import { processStatement } from '../pipeline';
import { toReviewItems } from '../review';

import { airtelPaymentsBankParser, interpretAirtelParticulars } from './airtelPaymentsBank';
import { genericTableParser } from './genericTable';
import { hdfcParser } from './hdfc';
import { BANK_PARSERS, FALLBACK_PARSER } from './index';

const ACCOUNT: BankAccount = {
  id: 'acc-airtel',
  userId: 'u1',
  bankName: 'Airtel Payments Bank',
  nickname: 'Wallet',
  last4: '4321',
  openingBalance: 0,
  isActive: true,
  createdAt: null,
};
const category = (id: string, name: string): ExpenseCategory => ({ id, userId: 'u1', name, icon: 'category', color: '#78909C', isDefault: true, createdAt: null });
const CATEGORIES = [category('c-food', 'Food'), category('c-bills', 'Bills'), category('c-other', 'Other')];
const METHODS: PaymentMethod[] = [
  { id: 'pm-upi', userId: 'u1', name: 'UPI', createdAt: null },
  { id: 'pm-nb', userId: 'u1', name: 'Net Banking', createdAt: null },
];

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

const CHAR = 4.4;
const WRAP = 26;
type Fragment = readonly [text: string, x: number, width?: number];
/** One printed line as raw PDF text items (spaces at the edges included), y in points. */
const at = (y: number, items: readonly Fragment[]): TextFragment[] => items.map(([text, x, width]) => ({ text, x, y, width: width ?? text.length * CHAR, height: 8 }));
const right = (text: string, edge: number): Fragment => [text, edge - text.length * CHAR];

type Page = TextFragment[];
const pages = (...list: Page[]): ExtractedDocument => ({ pageCount: list.length, source: 'pdf-text', lines: list.flatMap((fragments, i) => groupFragments(fragments, i + 1)) });

const header = (y: number) => at(y, [['Date', 51, 21], ['Transaction ID', 104, 69], ['Particulars', 209, 50], ['Debit', 376, 25], ['Credit', 439, 29], ['Balance', 502, 35]]);
const identity = (first: boolean, bankLine = true): Page => [
  ...(first
    ? [
        ...at(790, [['Account Statement', 437]]),
        ...at(714, [['Account Number:', 62], ['0000004321', 152]]),
        ...at(696, [['IFSC Code:', 62], ['AIRP0000001', 152]]),
        ...at(678, [['Statement Period:', 62], ['01-09-2026 - 30-09-2026', 152]]),
      ]
    : at(766, [['Account Number: 0000004321', 64]])),
  ...(bankLine ? at(92, [['Airtel Payments Bank Ltd.', 51]]) : []),
  ...at(57, [['Customer Care Number : 0000-0000000', 51], ['Page 1', 524]]),
];

/** Airtel's fixed-width cut: every 26 characters, spaces included, words or not — and the PDF text keeps no space at a piece's ends. */
const pieces = (particulars: string) => (particulars.match(new RegExp(`.{1,${String(WRAP)}}`, 'g')) ?? []).map((piece) => piece.trim());
type Money = { debit?: string; credit?: string };
/** A transaction: the dated first line, then the rest of the Particulars 9pt apart. */
const txn = (y: number, date: string, id: string, particulars: string, money: Money, balance: string): Page => {
  const [first = '', ...rest] = pieces(particulars);
  return [
    ...at(y, [
      [date, 51],
      [id, 104],
      [first, 209],
      money.debit ? right(money.debit, 400) : ['-', 376],
      money.credit ? right(money.credit, 468) : ['-', 439],
      right(balance, 531),
    ]),
    ...rest.flatMap((piece, i) => at(y - 9 * (i + 1), [[piece, 209]])),
  ];
};
const summary = (y: number, opening: string, closing: string, totalCredit: string, totalDebit: string): Page => [
  ...at(y + 17, [[`₹${opening}`, 89], [`₹${closing}`, 208], [`₹${totalCredit}`, 325], [`₹${totalDebit}`, 444]]),
  ...at(y, [['Opening Balance', 81], ['Closing Balance', 202], ['Total Credit', 329], ['Total Debit', 449]]),
  ...at(y - 39, [['End of statement', 272]]),
];

// Synthetic Particulars. Cut at 26, the breaks fall mid-word — and, for cafe, right after a space.
const P = {
  store: 'PAYMENT MADE VIA UPI TO samplestore@ybl TXN REF 612345678901',
  person: 'PAYMENT RECEIVED VIA UPI FROM sampleperson@okaxis REF 612345678902',
  cafe: 'PAYMENT MADE VIA UPI TO A cafe@ybl REF 612345678903',
  charge: 'ACCOUNT MAINTENANCE CHARGE',
  pharmacy: 'PAYMENT MADE VIA UPI TO x.pharmacy@okicici TXN REF 612345678905',
};
const ROWS_PAGE_1 = [
  txn(532, '01-09-2026', 'AB000000000000001', P.store, { debit: '150.00' }, '850.00'),
  txn(480, '02-09-2026', 'AB000000000000002', P.person, { credit: '2000.00' }, '2850.00'),
  txn(427, '03-09-2026', 'AB000000000000003', P.cafe, { debit: '99.50' }, '2750.50'),
  txn(375, '05-09-2026', 'AB000000000000004', P.charge, { debit: '118.00' }, '2632.50'),
];
const PAGE_2_ROW = txn(684, '06-09-2026', 'AB000000000000005', P.pharmacy, { debit: '1250.50' }, '1382.00');

const statement = (rowsPage1 = ROWS_PAGE_1, bankLine = true): ExtractedDocument =>
  pages(
    [...identity(true, bankLine), ...header(563), ...rowsPage1.flat()],
    [...identity(false, bankLine), ...header(715), ...PAGE_2_ROW, ...summary(391, '1000.00', '1382.00', '2000.00', '1618.00')],
  );
const doc = statement();

const process = (d: ExtractedDocument, statementId = 'airtel-sep') =>
  processStatement({ doc: d, statementId, fileName: `${statementId}.pdf`, account: ACCOUNT, accounts: [ACCOUNT], categories: CATEGORIES });

// ---------------------------------------------------------------------------

describe('Airtel Payments Bank detection', () => {
  it('claims Airtel statements by their own header and footer, and nothing else', () => {
    expect(airtelPaymentsBankParser.detect(doc)).toBeGreaterThan(0.9);
    expect(selectParser(doc, BANK_PARSERS, FALLBACK_PARSER).parser.id).toBe('airtel-payments-bank');
    expect(hdfcParser.detect(doc)).toBe(0);
  });

  it('is not fooled by Airtel appearing only in a narration', () => {
    const noIdentity = (d: ExtractedDocument): ExtractedDocument => ({ ...d, lines: d.lines.filter((l) => !/IFSC/.test(l.text)) });
    const recharge = txn(532, '01-09-2026', 'AB000000000000001', 'PAYMENT MADE VIA UPI TO X Airtel Payments Bank recharge', { debit: '150.00' }, '850.00');
    const narrationOnly = noIdentity(statement([recharge, ...ROWS_PAGE_1.slice(1)], false));
    expect(narrationOnly.lines.some((l) => /Airtel Payments Bank/.test(l.text))).toBe(true);
    expect(airtelPaymentsBankParser.detect(narrationOnly)).toBe(0);
    expect(selectParser(narrationOnly, BANK_PARSERS, FALLBACK_PARSER).parser).toBe(genericTableParser);
  });

  it('needs Airtel’s column set, not just its name', () => {
    const otherTable = pages([...identity(true), ...at(563, [['Date', 51], ['Details', 209], ['Debit', 376], ['Credit', 439], ['Balance', 502]])]);
    expect(airtelPaymentsBankParser.detect(otherTable)).toBe(0);
  });
});

describe('Airtel Payments Bank statement', () => {
  const result = process(doc);
  const t = result.transactions;

  it('reads every row across pages, skipping repeated headings, account lines and footers', () => {
    expect(result.parserId).toBe('airtel-payments-bank');
    expect(result.bankName).toBe('Airtel Payments Bank');
    expect(result.warnings).toEqual([]);
    expect(t.map((x) => [x.transactionDate, x.transactionType, x.amount, x.balance])).toEqual([
      ['2026-09-01', 'debit', 150, 850],
      ['2026-09-02', 'credit', 2000, 2850],
      ['2026-09-03', 'debit', 99.5, 2750.5],
      ['2026-09-05', 'debit', 118, 2632.5],
      ['2026-09-06', 'debit', 1250.5, 1382],
    ]);
  });

  it('maps Transaction ID to reference', () => {
    expect(t.map((x) => x.reference)).toEqual(['AB000000000000001', 'AB000000000000002', 'AB000000000000003', 'AB000000000000004', 'AB000000000000005']);
  });

  it('rebuilds each Particulars exactly from its fixed-width pieces', () => {
    expect(t.map((x) => x.rawDescription)).toEqual([P.store, P.person, P.cafe, P.charge, P.pharmacy]);
  });

  it('keeps words joined where a space fell at the very start of a piece — the PDF text has none there', () => {
    const lost = 'PAYMENT MADE VIA UPI TO ID abc@ybl REF 612345678906'; // the second piece began with the space
    const d = pages([...identity(true), ...header(563), ...txn(532, '01-09-2026', 'AB000000000000006', lost, { debit: '10.00' }, '990.00')]);
    expect(process(d).transactions[0]?.rawDescription).toBe('PAYMENT MADE VIA UPI TO IDabc@ybl REF 612345678906');
  });

  it('reads the summary: every balance, the first included, is checked, and the totals agree', () => {
    expect(result.openingBalance).toBe(1000);
    expect(result.closingBalance).toBe(1382);
    expect(t.every((x) => x.confidence === 1 && x.issues.length === 0)).toBe(true);
  });

  it('flags a balance that does not follow from the row before it', () => {
    const wrongBalance = txn(480, '02-09-2026', 'AB000000000000002', P.person, { credit: '2000.00' }, '2950.00');
    const wrong = process(statement([ROWS_PAGE_1[0] ?? [], wrongBalance, ...ROWS_PAGE_1.slice(2)]), 'wrong');
    expect(wrong.warnings.map((w) => w.code)).toContain('balanceMismatch');
  });

  it('warns when the rows read do not add up to the statement’s own totals', () => {
    const missing = process(statement([ROWS_PAGE_1[0] ?? [], ...ROWS_PAGE_1.slice(2)]), 'missing');
    expect(missing.warnings.some((w) => w.code === 'balanceMismatch' && /totals/.test(w.message))).toBe(true);
  });

  it('marks UPI and charge rows, and takes no payee from a UPI ID', () => {
    expect(t.map((x) => x.channel)).toEqual(['upi', 'upi', 'upi', 'charges', 'upi']);
    expect(t.map((x) => x.counterparty)).toEqual([null, null, null, null, null]);
    expect(t[3]).toMatchObject({ kind: 'expense', category: 'Bills', categoryReason: 'bank charge' });
    expect(t[1]?.kind).toBe('income');
  });

  it('reads the account digits and the statement period from the header', () => {
    expect(result.accountLast4).toBe('4321');
    expect(result.period).toEqual({ from: '2026-09-01', to: '2026-09-30' });
  });
});

describe('Airtel Payments Bank malformed rows', () => {
  const base = [...identity(true), ...header(563)];

  it('warns about an undated line that carries amounts instead of dropping it silently', () => {
    const broken = process(pages([...base, ...txn(532, '0I-09-2026', 'AB000000000000001', P.store, { debit: '150.00' }, '850.00')]), 'broken');
    expect(broken.transactions).toHaveLength(0);
    expect(broken.warnings.map((w) => w.code)).toContain('skippedLine');
  });

  it('warns about a dated line with no debit or credit', () => {
    const noAmount = process(pages([...base, ...txn(532, '01-09-2026', 'AB000000000000001', P.store, {}, '850.00')]), 'no-amount');
    expect(noAmount.transactions).toHaveLength(0);
    expect(noAmount.warnings.map((w) => w.code)).toContain('skippedLine');
  });
});

describe('Airtel Payments Bank with duplicate protection and import', () => {
  it('a re-uploaded statement is entirely duplicate', () => {
    const a = process(doc, 'first');
    const b = process(doc, 'again');
    const marked = markDuplicates([...a.transactions, ...b.transactions], []);
    expect(marked.filter((x) => x.duplicate?.type === 'overlap')).toHaveLength(a.transactions.length);
  });

  it('rows already imported are not imported again', () => {
    const plan = buildImportPlan(toReviewItems(process(doc, 'first').transactions, CATEGORIES), { fallbackCategoryId: 'c-other', paymentMethods: METHODS });
    const ledger = plan.operations.map((op) => ({
      accountId: ACCOUNT.id,
      date: op.date,
      amount: op.amount,
      direction: op.type === 'expense' ? ('debit' as const) : op.type === 'income' ? ('credit' as const) : op.direction,
      description: op.type === 'expense' ? (op.merchant ?? op.description) : op.type === 'income' ? (op.source ?? op.description) : op.description,
    }));
    const again = markDuplicates(process(doc, 'again').transactions, ledger);
    expect(again.every((x) => x.duplicate?.type === 'existing' && x.duplicate.strength === 'exact')).toBe(true);
    const rePlan = buildImportPlan(toReviewItems(again, CATEGORIES), { fallbackCategoryId: 'c-other', paymentMethods: METHODS });
    expect(rePlan.operations).toHaveLength(0);
  });

  it('imports UPI rows with the UPI payment method, the full Particulars and the transaction ID', () => {
    const items = toReviewItems(process(doc).transactions, CATEGORIES);
    const plan = buildImportPlan(items, { fallbackCategoryId: 'c-other', paymentMethods: METHODS });
    const op = plan.operations.find((o) => o.itemId === items[2]?.id);
    expect(op).toMatchObject({ type: 'expense', paymentMethodId: 'pm-upi', merchant: null, description: P.cafe });
    expect(op?.type === 'expense' ? op.notes : '').toContain('AB000000000000003');
  });
});

describe('Airtel Payments Bank particulars', () => {
  it.each([
    [P.store, 'upi'],
    [P.person, 'upi'],
    [P.charge, 'charges'],
    ['SOMETHING UNFAMILIAR', null],
  ])('%s', (particulars, channel) => {
    expect(interpretAirtelParticulars(particulars)).toEqual({ channel, counterparty: null });
  });
});
