/**
 * Paytm UPI statement parser, read from the text layer of a real statement
 * (paytm.fixture.ts — only personal details replaced) through the same line
 * grouping as a real PDF. A few extra payments — money in, a self transfer,
 * a statement across the new year — are laid out at the positions measured
 * from it, since the sample has none of those.
 */
import { describe, expect, it } from 'vitest';

import type { BankAccount, ExpenseCategory, PaymentMethod } from '../../models';
import { isUncategorized, detailProblem, reviewReducer, toReviewItems, type ReviewItem } from '../review';
import { markDuplicates } from '../duplicates';
import { buildImportPlan, type ImportOperation } from '../importPlan';
import { groupFragments, type TextFragment } from '../layout';
import type { ExistingMovement, ExtractedDocument, NormalizedTransaction } from '../model';
import { selectParser } from '../parser';
import { processStatement } from '../pipeline';
import { toCents } from '../parsing';

import { airtelPaymentsBankParser } from './airtelPaymentsBank';
import { hdfcParser } from './hdfc';
import { BANK_PARSERS, FALLBACK_PARSER } from './index';
import { PAYTM_SEP_2026, type FixtureItem } from './paytm.fixture';
import { paytmParser, paytmRowTotals, readPaytmStatement } from './paytm';

// ---------------------------------------------------------------------------
// The statement, and the user's accounts and categories
// ---------------------------------------------------------------------------

const fragments = (items: readonly FixtureItem[]): TextFragment[] => items.map(([text, x, y, width, height]) => ({ text, x, y, width, height }));
const toDoc = (pages: readonly (readonly FixtureItem[])[]): ExtractedDocument => ({
  pageCount: pages.length,
  source: 'pdf-text',
  lines: pages.flatMap((items, i) => groupFragments(fragments(items), i + 1)),
});
const [PAGE_1 = [], PAGE_2 = []] = PAYTM_SEP_2026;
const doc = toDoc(PAYTM_SEP_2026);

const account = (id: string, bankName: string, nickname: string, last4: string | null): BankAccount => ({
  id,
  userId: 'u1',
  bankName,
  nickname,
  last4,
  openingBalance: 0,
  isActive: true,
  createdAt: null,
});
// Shaped like the accounts the statement's owner keeps in the app.
const AIRTEL = account('acc-airtel', 'Airtel Payment Bank', 'Airtel Payment Bank', '9714');
const HDFC = account('acc-hdfc', 'HDFC Bank', 'HDFC Salary Account', '6459');
const INDIAN = account('acc-indian', 'Indian Bank', 'Indian Bank Savings Account', '4462');
const ACCOUNTS = [AIRTEL, HDFC, INDIAN];

const category = (name: string): ExpenseCategory => ({
  id: `c-${name.toLowerCase()}`,
  userId: 'u1',
  name,
  icon: 'category',
  color: '#78909C',
  isDefault: true,
  createdAt: null,
});
const CATEGORIES = ['Bills', 'Education', 'Entertainment', 'Food', 'Health', 'Other', 'Shopping', 'Transport', 'Travel'].map(category);
const METHODS: PaymentMethod[] = [{ id: 'pm-upi', userId: 'u1', name: 'UPI', createdAt: null }];

/** The upload screen's account is deliberately the wrong one: a Paytm statement must not use it. */
const process = (d: ExtractedDocument = doc, statementId = 'paytm-sep', options: { accounts?: BankAccount[]; categories?: ExpenseCategory[] } = {}) =>
  processStatement({
    doc: d,
    statementId,
    fileName: `${statementId}.pdf`,
    account: INDIAN,
    accounts: options.accounts ?? ACCOUNTS,
    categories: options.categories ?? CATEGORIES,
  });

const byRef = (list: readonly NormalizedTransaction[], reference: string) => {
  const found = list.find((t) => t.reference === reference);
  if (!found) throw new Error(`No row with reference ${reference}`);
  return found;
};

/** A payment laid out at the positions measured from the statement: a dated first line, wrapped columns below. */
function payment(
  y: number,
  p: { date: string; time: string; title: string; upi: string; ref: string; note?: string; tag?: string; account: readonly string[]; amount: string },
): FixtureItem[] {
  const items: FixtureItem[] = [
    [p.date, 22.5, y, 31.2, 9],
    [p.time, 22.5, y - 12.4, 36.2, 9],
    [p.title, 91.1, y - 1.9, p.title.length * 4.5, 9],
    [`UPI ID: ${p.upi}`, 91.1, y - 19.2, 140, 9],
    [`UPI Ref No: ${p.ref}`, 91.1, y - 34.4, 120, 9],
    [p.amount, 491.7, y, 37, 9],
  ];
  let notesY = y - 1.5;
  if (p.note) {
    items.push([`Note: ${p.note}`, 288, notesY, 90, 9]);
    notesY -= 17.7;
  }
  if (p.tag) items.push(['Tag:', 302.3, notesY, 19.7, 9], [`# ${p.tag}`, 294.2, notesY - 15.8, 50, 7.5]);
  p.account.forEach((text, i) => items.push([text, 413.6, y - 1.9 - i * 16.1, 44.5, 9]));
  return items;
}
/** Page 1 above its first payment: owner, period, totals, per-account summary, column headings. */
const PAGE_1_HEAD = PAGE_1.filter(([, , y]) => y > 380);
const footer = (n: number, of: number): FixtureItem[] => [[`Page ${String(n)} of ${String(of)}`, 9, 61, 50, 9]];

// ---------------------------------------------------------------------------

describe('Paytm detection', () => {
  it('claims the Paytm statement — and the bank parsers do not, though it names Airtel and HDFC', () => {
    expect(paytmParser.detect(doc)).toBeGreaterThan(0.9);
    expect(selectParser(doc, BANK_PARSERS, FALLBACK_PARSER).parser.id).toBe('paytm-upi');
    expect(hdfcParser.detect(doc)).toBe(0);
    expect(airtelPaymentsBankParser.detect(doc)).toBe(0);
  });

  it('needs Paytm named above its own columns: a payment to "…@paytm" in a narration is not enough', () => {
    const unnamed = toDoc([PAGE_1.filter(([text]) => !/paytm/i.test(text)), PAGE_2]);
    expect(paytmParser.detect(unnamed)).toBe(0);
    const bankNarration = toDoc([
      [
        ['HDFC BANK Ltd.', 30, 800, 70, 9],
        ['Date', 30, 700, 20, 9],
        ['Narration', 90, 700, 40, 9],
        ['01/09/26', 30, 680, 40, 9],
        ['UPI-PAYTM-paytmqr123@paytm-PYTM0123456-612345678901-PAYTM', 90, 680, 300, 9],
      ],
    ]);
    expect(paytmParser.detect(bankNarration)).toBe(0);
  });
});

describe('Paytm payments', () => {
  const read = readPaytmStatement(doc);
  const t = process().transactions;

  it('reads every payment in the Passbook Payments History — none dropped', () => {
    expect(read.rows).toHaveLength(7);
    expect(t).toHaveLength(7);
    expect(read.warnings).toEqual([]);
  });

  it.each([
    ['315827550212', '2026-09-30', '10:59', 'Paid to Bharti Airtel Limited', 'Bharti Airtel Limited', 229.07, 'airtel1paytm@hdfcbank', 'Airtel Broadband Bill Payment', ['Bill Payments'], 'Airtel Payments Bank - 14'],
    ['104077523535', '2026-09-20', '02:38', 'Automatic payment for Netflix India', 'Netflix India', 199, 'netflix.bdautopay@hdfcbank', 'Execution test', ['Entertainment'], 'HDFC Bank - 59'],
    ['315048571107', '2026-09-19', '15:52', 'Paid to Christhu Kani Stores', 'Christhu Kani Stores', 30, 'paytmqr6py5ee@ptys', null, ['Groceries'], 'Airtel Payments Bank - 14'],
    ['314670591712', '2026-09-14', '14:06', 'Paid to Payee One', 'Payee One', 75, 'paytm.s1payee1@pty', null, ['Food'], 'Airtel Payments Bank - 14'],
    ['215397422094', '2026-09-11', '12:49', 'Paid to Payee Two', 'Payee Two', 85, 'paytm.s1payee2@pty', null, ['Food'], 'Airtel Payments Bank - 14'],
    ['215286712573', '2026-09-09', '22:40', 'Paid to WOAHFFLES', 'WOAHFFLES', 150, 'paytm.d13984442613@pty', null, ['Food'], 'Airtel Payments Bank - 14'],
    ['613534224968', '2026-09-05', '20:57', 'Paid to Payee Three', 'Payee Three', 150, 'paytm.s1payee3@pty', null, ['Fuel'], 'Airtel Payments Bank - 14'],
  ] as const)('%s: date, time, payee, UPI ID, note, tag and account', (reference, date, time, description, payee, amount, upiId, notes, tags, sourceAccount) => {
    expect(byRef(t, reference)).toMatchObject({
      transactionDate: date,
      transactionTime: time,
      description,
      counterparty: payee,
      amount,
      transactionType: 'debit',
      upiId,
      notes,
      tags: [...tags],
      sourceAccount,
      channel: 'upi',
      confidence: 1,
    });
  });

  it('takes the year from the statement period and the direction from the amount’s sign', () => {
    expect(read.period).toEqual({ from: '2026-09-02', to: '2026-10-01' });
    expect(read.rows.map((r) => r.directionHint)).toEqual(Array(7).fill('debit'));
    expect(read.rows.map((r) => r.amountText)).toEqual(['- Rs.229.07', '- Rs.199', '- Rs.30', '- Rs.75', '- Rs.85', '- Rs.150', '- Rs.150']);
  });

  it('reads money in as money in — the "+" decides, not the wording', () => {
    const credit = payment(350, {
      date: '04 Sep',
      time: '9:15 AM',
      title: 'Received from Payee Four',
      upi: 'payee4@okaxis',
      ref: '612345678901',
      note: 'Dinner share',
      tag: 'Food',
      account: ['Airtel', 'Payments', 'Bank - 14'],
      amount: '+ Rs.500',
    });
    const row = byRef(process(toDoc([PAGE_1, [...PAGE_2, ...credit]]), 'with-credit').transactions, '612345678901');
    expect(row).toMatchObject({ transactionType: 'credit', kind: 'income', amount: 500, counterparty: 'Payee Four', notes: 'Dinner share', bankAccountId: AIRTEL.id });
  });

  it('works out the year across the new year from a period like "20 DEC\'25 - 15 JAN\'26"', () => {
    const head = PAGE_1_HEAD.map((item): FixtureItem => (item[0] === "2 SEP'26 - 1 OCT'26" ? ["20 DEC'25 - 15 JAN'26", item[1], item[2], item[3], item[4]] : item));
    const rows = readPaytmStatement(
      toDoc([
        [
          ...head,
          ...payment(350, { date: '05 Jan', time: '1:00 PM', title: 'Paid to Shop A', upi: 'a@ybl', ref: '600000000001', tag: 'Food', account: ['HDFC Bank -', '59'], amount: '- Rs.10' }),
          ...payment(250, { date: '30 Dec', time: '1:00 PM', title: 'Paid to Shop B', upi: 'b@ybl', ref: '600000000002', tag: 'Food', account: ['HDFC Bank -', '59'], amount: '- Rs.20' }),
          ...footer(1, 1),
        ],
      ]),
    ).rows;
    expect(rows.map((r) => r.dateText)).toEqual(['5 Jan 2026', '30 Dec 2025']);
  });
});

describe('Paytm totals check', () => {
  it('adds up to the statement’s own summary: 7 payments, Rs.918.07 paid, nothing received', () => {
    const { rows, summary } = readPaytmStatement(doc);
    const read = paytmRowTotals(rows);
    expect(summary.paid).toEqual({ count: 7, amount: 918.07 });
    expect(summary.received).toEqual({ count: 0, amount: 0 });
    expect(read.paid).toEqual({ count: 7, cents: toCents(918.07) });
    expect(read.received).toEqual({ count: 0, cents: 0 });
  });

  it('per account: Airtel Payments Bank - 14 made 6 for Rs.719.07, HDFC Bank - 59 made 1 for Rs.199', () => {
    const { rows, summary } = readPaytmStatement(doc);
    expect(summary.accounts).toEqual([
      { label: 'Airtel Payments Bank - 14', paid: { count: 6, amount: 719.07 }, received: { count: 0, amount: 0 } },
      { label: 'HDFC Bank - 59', paid: { count: 1, amount: 199 }, received: { count: 0, amount: 0 } },
    ]);
    const byAccount = paytmRowTotals(rows).byAccount;
    expect(byAccount.get('airtel payments bank - 14')?.paid).toEqual({ count: 6, cents: toCents(719.07) });
    expect(byAccount.get('hdfc bank - 59')?.paid).toEqual({ count: 1, cents: toCents(199) });
  });

  it('warns — naming the account — when a payment was not read', () => {
    // Without WOAHFFLES (9 Sep, Rs.150), which is on page 2.
    const missing = toDoc([PAGE_1, PAGE_2.filter(([, , y]) => y < 490 || y > 550)]);
    const warnings = readPaytmStatement(missing).warnings.filter((w) => w.code === 'balanceMismatch').map((w) => w.message);
    expect(warnings.some((m) => m.startsWith('Paid:') && m.includes('7 for Rs.918.07') && m.includes('6 for Rs.768.07'))).toBe(true);
    expect(warnings.some((m) => m.startsWith('Paid from Airtel Payments Bank - 14'))).toBe(true);
    expect(warnings.some((m) => m.includes('HDFC'))).toBe(false);
  });
});

describe('Paytm accounts', () => {
  it('puts each payment in the account the statement names, not the one chosen for the upload', () => {
    const t = process().transactions;
    expect(t.filter((x) => x.bankAccountId === AIRTEL.id)).toHaveLength(6);
    expect(t.filter((x) => x.bankAccountId === HDFC.id)).toHaveLength(1);
    expect(t.filter((x) => x.bankAccountId === INDIAN.id)).toHaveLength(0);
    expect(t.every((x) => x.accountStatus === 'matched')).toBe(true);
    // The account is part of the row's identity.
    expect(byRef(t, '104077523535').fingerprint.startsWith(`${HDFC.id}|2026-09-20|19900|debit|`)).toBe(true);
  });

  it('leaves a row for review — with no account — when the named account is not one of the user’s', () => {
    const t = process(doc, 'no-hdfc', { accounts: [AIRTEL, INDIAN] }).transactions;
    const netflix = byRef(t, '104077523535');
    expect(netflix).toMatchObject({ bankAccountId: '', accountStatus: 'unmatched' });
    const items = toReviewItems(t, CATEGORIES);
    const item = items.find((i) => i.id === netflix.id) as ReviewItem;
    expect(detailProblem(item)).toBe('account');
    const plan = buildImportPlan(items, { fallbackCategoryId: 'c-other', paymentMethods: METHODS });
    expect(plan.operations.some((op) => op.itemId === netflix.id)).toBe(false);
    expect(plan.skipped).toContainEqual({ itemId: netflix.id, reason: 'Choose the account it was paid from' });

    // Choosing it in review makes the row importable — into that account.
    const chosen = reviewReducer(items, { type: 'edit', id: netflix.id, patch: { bankAccountId: HDFC.id } });
    const edited = chosen.find((i) => i.id === netflix.id) as ReviewItem;
    expect(edited).toMatchObject({ bankAccountId: HDFC.id, accountStatus: 'chosen' });
    expect(detailProblem(edited)).toBeNull();
    const after = buildImportPlan(chosen, { fallbackCategoryId: 'c-other', paymentMethods: METHODS });
    expect(after.operations.find((op) => op.itemId === netflix.id)?.bankAccountId).toBe(HDFC.id);
  });

  it('never guesses between two accounts with the same bank and digits', () => {
    const twin = account('acc-airtel-2', 'Airtel Payments Bank', 'Wallet', '0014');
    const t = process(doc, 'twins', { accounts: [AIRTEL, twin, HDFC] }).transactions;
    expect(t.filter((x) => x.sourceAccount?.startsWith('Airtel')).every((x) => x.bankAccountId === '')).toBe(true);
    expect(byRef(t, '104077523535').bankAccountId).toBe(HDFC.id);
  });

  it('needs the bank to agree as well as the digits', () => {
    // Ends in 59, but it is not an HDFC account.
    const lookalike = account('acc-other', 'Indian Bank', 'Indian Bank Savings Account', '1259');
    const t = process(doc, 'lookalike', { accounts: [AIRTEL, lookalike] }).transactions;
    expect(byRef(t, '104077523535').bankAccountId).toBe('');
  });
});

describe('Paytm categories and tags', () => {
  const t = process().transactions;

  it('suggests each category from the Paytm tag, among the user’s own categories', () => {
    const categoryOf = (ref: string) => byRef(t, ref).category;
    expect(categoryOf('315827550212')).toBe('Bills'); // # Bill Payments
    expect(categoryOf('104077523535')).toBe('Entertainment'); // # Entertainment
    expect(categoryOf('315048571107')).toBe('Food'); // # Groceries: no Groceries category, Food as the receipt keywords do
    expect(categoryOf('314670591712')).toBe('Food'); // # Food
    expect(categoryOf('613534224968')).toBe('Transport'); // # Fuel: no Fuel category, Transport as the receipt keywords do
    expect(t.every((x) => x.kind === 'expense' && x.categorySource === 'rule')).toBe(true);
    expect(byRef(t, '104077523535').categoryReason).toBe('tagged "Entertainment"');
  });

  it('prefers a category named exactly like the tag', () => {
    const own = process(doc, 'own', { categories: [...CATEGORIES, category('Groceries'), category('Fuel')] }).transactions;
    expect(byRef(own, '315048571107').category).toBe('Groceries');
    expect(byRef(own, '613534224968').category).toBe('Fuel');
  });

  it('leaves the category for review when nothing fits — and keeps the tag', () => {
    const few = process(doc, 'few', { categories: [category('Health'), category('Other')] }).transactions;
    const bill = byRef(few, '315827550212');
    expect(bill).toMatchObject({ category: 'Other', categorySource: 'fallback', tags: ['Bill Payments'] });
    expect(isUncategorized(toReviewItems([bill], [category('Health'), category('Other')])[0] as ReviewItem)).toBe(true);
  });

  it('lets the note decide when the tag alone does not', () => {
    const noTag = payment(350, {
      date: '04 Sep',
      time: '9:15 AM',
      title: 'Paid to Some Vendor',
      upi: 'vendor@ybl',
      ref: '612345678902',
      note: 'Broadband bill for September',
      tag: 'Misc',
      account: ['Airtel', 'Payments', 'Bank - 14'],
      amount: '- Rs.100',
    });
    const row = byRef(process(toDoc([PAGE_1, [...PAGE_2, ...noTag]]), 'note').transactions, '612345678902');
    expect(row).toMatchObject({ category: 'Bills', categoryReason: 'the note mentions bills' });
  });
});

describe('Paytm import plan', () => {
  const items = toReviewItems(process().transactions, CATEGORIES);
  const plan = buildImportPlan(items, { fallbackCategoryId: 'c-other', paymentMethods: METHODS, storeDetails: true, storeTags: true });
  const opFor = (ref: string) => {
    const item = items.find((i) => i.reference === ref);
    return plan.operations.find((op) => op.itemId === item?.id) as Extract<ImportOperation, { type: 'expense' }>;
  };

  it('imports all seven, into the accounts that paid them', () => {
    expect(plan.operations).toHaveLength(7);
    expect(plan.skipped).toEqual([]);
    const total = (accountId: string) => plan.operations.filter((op) => op.bankAccountId === accountId).reduce((s, op) => s + toCents(op.amount), 0);
    expect(total(AIRTEL.id)).toBe(toCents(719.07));
    expect(total(HDFC.id)).toBe(toCents(199));
  });

  it('description, payee, Notes from the Paytm note, tags, UPI payment method — and the UPI details kept on the movement', () => {
    expect(opFor('315827550212')).toMatchObject({
      type: 'expense',
      bankAccountId: AIRTEL.id,
      date: '2026-09-30',
      amount: 229.07,
      description: 'Paid to Bharti Airtel Limited',
      merchant: 'Bharti Airtel Limited',
      notes: 'Airtel Broadband Bill Payment',
      categoryId: 'c-bills',
      paymentMethodId: 'pm-upi',
      tags: ['Bill Payments'],
      details: { reference: '315827550212', upiId: 'airtel1paytm@hdfcbank', time: '10:59' },
    });
  });

  it('leaves Notes empty when Paytm printed no note', () => {
    expect(opFor('315048571107')).toMatchObject({ notes: null, tags: ['Groceries'], categoryId: 'c-food' });
  });

  it('before migrations 006/007, keeps the UPI reference, UPI ID and tags in Notes rather than lose them', () => {
    const older = buildImportPlan(items, { fallbackCategoryId: 'c-other', paymentMethods: METHODS });
    const op = older.operations.find((o) => o.itemId === items.find((i) => i.reference === '315827550212')?.id) as Extract<ImportOperation, { type: 'expense' }>;
    expect(op.details).toBeUndefined();
    expect(op.tags).toBeUndefined();
    expect(op.notes).toBe('Airtel Broadband Bill Payment\nUPI ref 315827550212\nUPI ID airtel1paytm@hdfcbank\nTags: Bill Payments');
  });

  it('keeps a bank statement’s rows exactly as before: the import marker in Notes', () => {
    const bankRow = { ...items[0], notes: undefined, tags: undefined, upiId: undefined, sourceAccount: undefined, reference: 'REF1' } as ReviewItem;
    const op = buildImportPlan([bankRow], { fallbackCategoryId: 'c-other', paymentMethods: METHODS }).operations[0];
    expect(op?.type === 'expense' ? op.notes : null).toBe('Imported from bank statement · ref REF1');
  });
});

describe('Paytm duplicates', () => {
  const recorded = (ops: readonly ImportOperation[], shift: (op: ImportOperation) => Partial<ExistingMovement> = () => ({})): ExistingMovement[] =>
    ops.map((op) => ({
      accountId: op.bankAccountId,
      date: op.date,
      amount: op.amount,
      direction: 'debit' as const,
      description: op.type === 'expense' ? (op.merchant ?? op.description) : op.description,
      reference: op.details?.reference ?? null,
      upiId: op.details?.upiId ?? null,
      ...shift(op),
    }));
  const firstPlan = () =>
    buildImportPlan(toReviewItems(process(doc, 'first').transactions, CATEGORIES), { fallbackCategoryId: 'c-other', paymentMethods: METHODS, storeDetails: true });

  it('the same statement added twice in one session is entirely duplicate', () => {
    const a = process(doc, 'a').transactions;
    const b = process(doc, 'b').transactions;
    const marked = markDuplicates([...a, ...b], []);
    expect(marked.slice(7).every((x) => x.duplicate?.type === 'overlap')).toBe(true);
    expect(marked.slice(0, 7).every((x) => x.duplicate == null)).toBe(true);
  });

  it('a statement already imported is recognised by its UPI reference numbers — nothing is planned again', () => {
    const again = markDuplicates(process(doc, 'again').transactions, recorded(firstPlan().operations));
    expect(again.every((x) => x.duplicate?.type === 'existing' && x.duplicate.strength === 'exact' && x.duplicate.sameReference)).toBe(true);
    const rePlan = buildImportPlan(toReviewItems(again, CATEGORIES), { fallbackCategoryId: 'c-other', paymentMethods: METHODS });
    expect(rePlan.operations).toHaveLength(0);
  });

  it('the same reference matches even when the bank recorded it a day later, in its own words, zero-padded', () => {
    const fromBank = recorded(firstPlan().operations, (op) => ({
      date: op.date === '2026-09-30' ? '2026-10-01' : op.date,
      description: 'UPI-BHARTI AIRTEL LIMITED-AIRTEL1PAYTM@HDFCBANK',
      reference: op.details?.reference ? `0000${op.details.reference}` : null,
      upiId: null,
    }));
    const marked = markDuplicates(process(doc, 'after-bank').transactions, fromBank);
    expect(byRef(marked, '315827550212').duplicate).toMatchObject({ type: 'existing', strength: 'exact', sameReference: true, existingDate: '2026-10-01' });
  });

  it('a recorded UPI payment with a different reference is not taken for this one', () => {
    // Rs.150 on 5 Sep from Airtel, recorded from a UPI statement under another reference.
    const other: ExistingMovement = { accountId: AIRTEL.id, date: '2026-09-05', amount: 150, direction: 'debit', description: 'Someone else', reference: '999999999999', upiId: 'other@ybl' };
    expect(byRef(markDuplicates(process().transactions, [other]), '613534224968').duplicate).toBeNull();
    // Without a UPI reference to tell them apart, the same amount on the same day is still flagged.
    expect(byRef(markDuplicates(process().transactions, [{ ...other, reference: null, upiId: null }]), '613534224968').duplicate).toMatchObject({ type: 'existing', strength: 'likely' });
  });

  it('a payment also in a bank statement added earlier in the session is flagged, though worded differently', () => {
    const fromHdfc: NormalizedTransaction = {
      ...byRef(process().transactions, '104077523535'),
      id: 'hdfc:0',
      sourceStatementId: 'hdfc-sep',
      description: 'ACH D- NETFLIX',
      rawDescription: 'ACH D- NETFLIX-104077523535',
      counterparty: null,
      reference: '0000104077523535',
      upiId: undefined,
      sourceAccount: undefined,
      notes: undefined,
      tags: undefined,
      fingerprint: 'hdfc-row',
    };
    const marked = markDuplicates([fromHdfc, ...process().transactions], []);
    expect(byRef(marked.slice(1), '104077523535').duplicate).toEqual({ type: 'overlap', ofId: 'hdfc:0' });
    expect(marked.slice(1).filter((x) => x.duplicate).length).toBe(1);
  });
});

describe('Paytm self transfers', () => {
  const selfTransfer = payment(350, {
    date: '04 Sep',
    time: '9:15 AM',
    title: 'Self transfer to HDFC Bank - 59',
    upi: 'holder@hdfcbank',
    ref: '612345678903',
    account: ['Airtel', 'Payments', 'Bank - 14'],
    amount: '- Rs.1,000',
  });
  const withSelf = toDoc([PAGE_1, [...PAGE_2, ...selfTransfer]]);

  it('records a transfer to the user’s own account as a transfer to it — not spending', () => {
    const row = byRef(process(withSelf, 'self').transactions, '612345678903');
    expect(row).toMatchObject({ kind: 'transfer', bankAccountId: AIRTEL.id, transferTarget: { type: 'account', accountId: HDFC.id }, category: null });
  });

  it('leaves it out of the totals check, as Paytm leaves it out of its totals', () => {
    expect(readPaytmStatement(withSelf).warnings).toEqual([]);
  });

  it('does not invent a transfer from a payment to a person', () => {
    const row = byRef(process().transactions, '215397422094');
    expect(row.kind).toBe('expense');
    expect(row.transferTarget ?? null).toBeNull();
    expect(row.counterpartyAccount).toBeNull();
  });
});
