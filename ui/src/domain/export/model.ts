/**
 * Format-neutral export model. Port of `services/export/export_models.dart`:
 * the builders produce an [ExportDataset], and the CSV and PDF renderers draw
 * that one structure — so both formats always carry the same figures.
 */
import { addDays, daysBetween, fromParts, parts, today, type IsoDate } from '@/lib/dates';

export type ExportFormat = 'csv' | 'pdf';

export const EXPORT_FORMATS: ReadonlyArray<{ value: ExportFormat; label: string; description: string }> = [
  { value: 'csv', label: 'CSV', description: 'Open in Excel or Sheets' },
  { value: 'pdf', label: 'PDF', description: 'Formatted for reading and printing' },
];

export type ExportReportType =
  | 'bankStatement'
  | 'expenses'
  | 'income'
  | 'spendingReport'
  | 'categoryReport'
  | 'incomeVsExpense';

export const REPORT_TYPES: ReadonlyArray<{
  value: ExportReportType;
  label: string;
  description: string;
  fileStem: string;
}> = [
  {
    value: 'bankStatement',
    label: 'Bank statement',
    description: 'One account, every movement, with a running balance',
    fileStem: 'bank_statement',
  },
  { value: 'expenses', label: 'Expenses', description: 'Every expense with category, source and notes', fileStem: 'expenses' },
  { value: 'income', label: 'Income', description: 'Every income entry with its source', fileStem: 'income' },
  {
    value: 'spendingReport',
    label: 'Spending report',
    description: 'Totals by category, by source and by month',
    fileStem: 'spending_report',
  },
  {
    value: 'categoryReport',
    label: 'Category breakdown',
    description: 'Each category with its total, count and share',
    fileStem: 'category_spending',
  },
  {
    value: 'incomeVsExpense',
    label: 'Income vs expense',
    description: 'Money in, money out, and the monthly net',
    fileStem: 'income_vs_expense',
  },
];

export function reportMeta(type: ExportReportType): (typeof REPORT_TYPES)[number] {
  const meta = REPORT_TYPES.find((r) => r.value === type);
  if (!meta) throw new Error(`Unknown report type: ${type}`);
  return meta;
}

export const needsAccount = (type: ExportReportType) => type === 'bankStatement';
export const supportsCategoryFilter = (type: ExportReportType) =>
  type === 'expenses' || type === 'spendingReport' || type === 'categoryReport';

export type ExportAlign = 'left' | 'right';
export type ExportCellKind = 'text' | 'money' | 'date' | 'count' | 'percent';

export type ExportColumn = { label: string; align: ExportAlign; width: number };
export const col = (label: string, width = 1): ExportColumn => ({ label, align: 'left', width });
export const numCol = (label: string, width = 1): ExportColumn => ({ label, align: 'right', width });

export type ExportCell = { text: string; kind: ExportCellKind; raw: number | null };
export const cell = (text: string): ExportCell => ({ text, kind: 'text', raw: null });
export const moneyCell = (text: string, amount: number): ExportCell => ({ text, kind: 'money', raw: amount });
export const countCell = (value: number): ExportCell => ({ text: String(value), kind: 'count', raw: value });
export const dateCell = (text: string): ExportCell => ({ text, kind: 'date', raw: null });
export const percentCell = (text: string, ratio: number | null): ExportCell => ({ text, kind: 'percent', raw: ratio });
export const blank = (): ExportCell => cell('');

export type ExportSection = {
  title: string;
  note?: string;
  columns: ExportColumn[];
  rows: ExportCell[][];
  totalRow?: ExportCell[];
  emptyMessage: string;
};

export type ExportSummaryItem = { label: string; value: string; emphasis?: boolean };

export type ExportDataset = {
  title: string;
  subtitle?: string | null;
  periodLabel: string;
  summary: ExportSummaryItem[];
  sections: ExportSection[];
  footnote?: string;
  generatedAt: Date;
};

export const datasetHasRows = (d: ExportDataset) => d.sections.some((s) => s.rows.length > 0);

// ---------------------------------------------------------------------------
// Date range
// ---------------------------------------------------------------------------

export type ExportDateRange = { start: IsoDate; endInclusive: IsoDate };

export function monthRangeOf(anchor: IsoDate): ExportDateRange {
  const { year, month } = parts(anchor);
  return { start: fromParts(year, month, 1), endInclusive: fromParts(year, month + 1, 0) };
}

export function lastDaysRange(days: number, now: Date = new Date()): ExportDateRange {
  const end = today(now);
  return { start: addDays(end, -(days - 1)), endInclusive: end };
}

export function yearRangeOf(anchor: IsoDate): ExportDateRange {
  const { year } = parts(anchor);
  return { start: fromParts(year, 1, 1), endInclusive: fromParts(year, 12, 31) };
}

export const rangeEndExclusive = (r: ExportDateRange) => addDays(r.endInclusive, 1);
export const rangeDayCount = (r: ExportDateRange) => daysBetween(r.start, r.endInclusive) + 1;
export const rangeIsValid = (r: ExportDateRange) => r.endInclusive >= r.start;
export const sameRange = (a: ExportDateRange, b: ExportDateRange) =>
  a.start === b.start && a.endInclusive === b.endInclusive;

export function isWholeMonth(r: ExportDateRange): boolean {
  if (!r.start.endsWith('-01')) return false;
  return sameRange(r, monthRangeOf(r.start));
}

/** `2026-09` for a whole month, otherwise `2026-09-01_to_2026-09-15`. */
export const rangeFileToken = (r: ExportDateRange) =>
  isWholeMonth(r) ? r.start.slice(0, 7) : `${r.start}_to_${r.endInclusive}`;

/**
 * Lowercases, keeps letters and digits, and collapses everything else to one
 * underscore; at most 24 characters. Filenames travel through share sheets
 * and other people's filesystems, so anything not plainly safe is removed.
 */
export function slugify(value: string): string {
  const slug = value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '');
  return slug.slice(0, 24);
}

/** `bank_statement_hdfc_2026-09.csv`, `expenses_2026-09-01_to_2026-09-14.csv`. */
export function exportFileName(type: ExportReportType, range: ExportDateRange, format: ExportFormat, qualifier?: string | null): string {
  const slug = qualifier ? slugify(qualifier) : '';
  return `${reportMeta(type).fileStem}${slug ? `_${slug}` : ''}_${rangeFileToken(range)}.${format}`;
}

export type ExportRequest = {
  type: ExportReportType;
  range: ExportDateRange;
  format: ExportFormat;
  accountId: string | null;
  categoryIds: string[];
};

export const requestIsRunnable = (r: ExportRequest) =>
  rangeIsValid(r.range) && (!needsAccount(r.type) || r.accountId != null);
