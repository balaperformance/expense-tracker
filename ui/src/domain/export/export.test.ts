/**
 * Parity tests: ported from `mobile/test/export_test.dart` (date ranges,
 * filenames, dataset figures and CSV safety).
 */
import { describe, expect, it } from 'vitest';

import type { Expense, ExpenseCategory, Income } from '../models';

import { ExportContext, expensesDataset, incomeVsExpenseDataset, spendingReportDataset } from './builder';
import {
  exportFileName,
  isWholeMonth,
  lastDaysRange,
  monthRangeOf,
  rangeDayCount,
  rangeEndExclusive,
  slugify,
  type ExportDataset,
} from './model';
import { renderCsv } from './render';

const september = monthRangeOf('2026-09-10');

describe('date range', () => {
  it('an inclusive end becomes an exclusive query bound', () => {
    expect(rangeEndExclusive(september)).toBe('2026-10-01');
  });

  it('counts every day it covers and recognises whole months', () => {
    expect(rangeDayCount(september)).toBe(30);
    expect(isWholeMonth(september)).toBe(true);
    expect(isWholeMonth({ start: '2026-09-01', endInclusive: '2026-09-14' })).toBe(false);
    expect(monthRangeOf('2024-02-05')).toEqual({ start: '2024-02-01', endInclusive: '2024-02-29' });
  });

  it('lastDays counts today as one of them', () => {
    expect(rangeDayCount(lastDaysRange(90, new Date(2026, 8, 24)))).toBe(90);
  });
});

describe('file names', () => {
  it('a whole month collapses to yyyy-MM; a partial range spells both ends out', () => {
    expect(exportFileName('spendingReport', september, 'pdf')).toBe('spending_report_2026-09.pdf');
    expect(exportFileName('expenses', { start: '2026-09-01', endInclusive: '2026-09-14' }, 'csv')).toBe(
      'expenses_2026-09-01_to_2026-09-14.csv',
    );
  });

  it('a statement carries the bank name', () => {
    expect(exportFileName('bankStatement', september, 'csv', 'HDFC')).toBe('bank_statement_hdfc_2026-09.csv');
    expect(exportFileName('categoryReport', september, 'pdf')).toBe('category_spending_2026-09.pdf');
  });

  it('slugify keeps a filename safe and short', () => {
    expect(slugify('State Bank of India')).toBe('state_bank_of_india');
    expect(slugify('HDFC •••• 4821')).toBe('hdfc_4821');
    expect(slugify('  /../etc/passwd  ')).toBe('etc_passwd');
    expect(slugify('...')).toBe('');
    expect(slugify('a very long bank name that keeps going on').length).toBeLessThanOrEqual(24);
  });
});

const food: ExpenseCategory = { id: 'food', userId: 'u', name: 'Food', icon: 'restaurant', color: '#FF7043', isDefault: true, createdAt: null };
const expense = (id: string, amount: number, date: string, extra: Partial<Expense> = {}): Expense => ({
  id,
  userId: 'u',
  amount,
  expenseDate: date,
  categoryId: 'food',
  paymentMethodId: null,
  bankAccountId: null,
  merchant: null,
  description: null,
  notes: null,
  createdAt: null,
  updatedAt: null,
  category: food,
  paymentMethod: null,
  ...extra,
});
const context = new ExportContext('INR', [], [food]);

describe('datasets', () => {
  it('expenses: totals, averages, Cash for no account, and a matching total row', () => {
    const dataset = expensesDataset({ expenses: [expense('1', 100, '2026-09-02'), expense('2', 300, '2026-09-01')], range: september, context });
    expect(dataset.summary.map((s) => s.value)).toEqual(['₹400.00', '2', '₹200.00']);
    const section = dataset.sections[0];
    expect(section?.rows[0]?.[0]?.text).toBe('1 Sep 2026');
    expect(section?.rows[0]?.[4]?.text).toBe('Cash');
    expect(section?.totalRow?.at(-1)?.raw).toBe(400);
  });

  it('a daily average uses the period, not the number of rows', () => {
    const dataset = spendingReportDataset({ expenses: [expense('1', 3000, '2026-09-05')], categories: [food], range: september, context });
    expect(dataset.summary.find((s) => s.label === 'Daily average')?.value).toBe('₹100.00');
    expect(dataset.sections.map((s) => s.title)).toEqual(['By category', 'By payment source', 'By month']);
  });

  it('income vs expense: net, savings rate, and zero income does not divide by zero', () => {
    const income: Income[] = [
      { id: 'i', userId: 'u', amount: 1000, incomeDate: '2026-09-01', source: 'Salary', description: null, bankAccountId: null, createdAt: null },
    ];
    const dataset = incomeVsExpenseDataset({ expenses: [expense('1', 250, '2026-09-03')], income, range: september, context });
    expect(dataset.summary.find((s) => s.label === 'Net balance')?.value).toBe('₹750.00');
    expect(dataset.summary.find((s) => s.label === 'Savings rate')?.value).toBe('75%');
    const empty = incomeVsExpenseDataset({ expenses: [expense('1', 250, '2026-09-03')], income: [], range: september, context });
    expect(empty.summary.find((s) => s.label === 'Savings rate')?.value).toBe('—');
  });
});

describe('CSV', () => {
  const csvOf = (merchant: string, notes: string | null = null) =>
    renderCsv(expensesDataset({ expenses: [expense('1', 1234.5, '2026-09-01', { merchant, notes })], range: september, context }));

  it('writes money as a bare number, with CRLF line endings', () => {
    const csv = csvOf('Cafe');
    expect(csv).toContain(',1234.50\r\n');
    expect(csv.split('\r\n').length).toBeGreaterThan(5);
    expect(csv).not.toMatch(/[^\r]\n/);
  });

  it('quotes commas and doubles embedded quotes', () => {
    expect(csvOf('Cafe, Bar')).toContain('"Cafe, Bar"');
    expect(csvOf('The "Best" Cafe')).toContain('"The ""Best"" Cafe"');
  });

  it('neutralises a formula injected through a merchant name', () => {
    const csv = csvOf('=HYPERLINK("http://evil")');
    expect(csv).toContain(`"'=HYPERLINK(""http://evil"")"`);
    expect(csv).not.toMatch(/,=HYPERLINK/);
  });

  it('a newline inside a note cannot break the row structure', () => {
    const csv = csvOf('Cafe', 'line one\nline two');
    expect(csv).toContain('line one line two');
  });

  it('an empty report still produces a readable file', () => {
    const empty: ExportDataset = expensesDataset({ expenses: [], range: september, context });
    expect(renderCsv(empty)).toContain('No expenses in this period.');
  });
});
