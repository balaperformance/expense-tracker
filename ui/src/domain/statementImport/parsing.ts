/**
 * Date, amount and text helpers every statement parser shares. Bank-agnostic:
 * they understand the ways dates and money are commonly printed, not any one
 * bank's layout.
 */
import { fromParts, type IsoDate } from '@/lib/dates';

import type { TransactionType } from './model';

// ---------------------------------------------------------------------------
// Dates
// ---------------------------------------------------------------------------

const MONTHS: Record<string, number> = {
  jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, sept: 9, oct: 10, nov: 11, dec: 12,
};

const NUMERIC = /^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2}|\d{4})$/;
const ISO = /^(\d{4})[/.-](\d{1,2})[/.-](\d{1,2})$/;
const DAY_MONTH_NAME = /^(\d{1,2})(?:st|nd|rd|th)?[\s/.-]*([a-z]{3,9})[\s/.,-]*(\d{2}|\d{4})$/i;
const MONTH_NAME_DAY = /^([a-z]{3,9})[\s.-]*(\d{1,2})(?:st|nd|rd|th)?,?[\s/.-]*(\d{2}|\d{4})$/i;

function fullYear(text: string): number {
  const year = Number(text);
  if (text.length === 4) return year;
  // Two-digit years: statements are recent, so 00–69 are this century.
  return year < 70 ? 2000 + year : 1900 + year;
}

function monthNumber(name: string): number | null {
  const key = name.toLowerCase();
  return MONTHS[key] ?? MONTHS[key.slice(0, 3)] ?? null;
}

function validDate(year: number, month: number, day: number): IsoDate | null {
  if (month < 1 || month > 12 || day < 1 || year < 1970 || year > 2100) return null;
  const last = new Date(Date.UTC(year, month, 0)).getUTCDate();
  if (day > last) return null;
  return fromParts(year, month, day);
}

/**
 * Whether numeric dates in a statement are day-first. Decided by the dates
 * themselves: any first part above 12 proves day-first, any second part above
 * 12 proves month-first. Null when every date is ambiguous.
 */
export function detectDayFirst(dateTexts: readonly string[]): boolean | null {
  for (const text of dateTexts) {
    const m = NUMERIC.exec(text.trim());
    if (!m) continue;
    const [first, second] = [Number(m[1]), Number(m[2])];
    if (first > 12 && second <= 12) return true;
    if (second > 12 && first <= 12) return false;
  }
  return null;
}

/**
 * detectDayFirst, then — when every date is ambiguous — the span test: a
 * statement covers one short, continuous period, so the reading that packs
 * the dates into a far tighter span is the right one. 01/09–07/09 is a week
 * in September, not January to July. Still null when both readings are alike.
 */
export function inferDayFirst(dateTexts: readonly string[]): boolean | null {
  const proven = detectDayFirst(dateTexts);
  if (proven != null) return proven;
  const span = (dayFirst: boolean) => {
    const dates = dateTexts
      .filter((t) => NUMERIC.test(t.trim()))
      .map((t) => parseStatementDate(t, dayFirst))
      .filter((d): d is IsoDate => d != null)
      .sort();
    const first = dates[0];
    const last = dates[dates.length - 1];
    return first && last ? (Date.parse(last) - Date.parse(first)) / 86_400_000 : null;
  };
  const dayFirst = span(true);
  const monthFirst = span(false);
  if (dayFirst == null || monthFirst == null || dayFirst === monthFirst) return null;
  if (dayFirst * 2 < monthFirst) return true;
  if (monthFirst * 2 < dayFirst) return false;
  return null;
}

/** Parses the date formats statements commonly use. Returns null rather than guessing. */
export function parseStatementDate(text: string, dayFirst = true): IsoDate | null {
  const value = text.trim().replace(/\s+/g, ' ');
  if (!value) return null;

  let m = ISO.exec(value);
  if (m) return validDate(Number(m[1]), Number(m[2]), Number(m[3]));

  m = NUMERIC.exec(value);
  if (m) {
    const [a, b, y] = [Number(m[1]), Number(m[2]), fullYear(m[3] ?? '')];
    return dayFirst ? validDate(y, b, a) : validDate(y, a, b);
  }

  m = DAY_MONTH_NAME.exec(value);
  if (m) {
    const month = monthNumber(m[2] ?? '');
    return month == null ? null : validDate(fullYear(m[3] ?? ''), month, Number(m[1]));
  }

  m = MONTH_NAME_DAY.exec(value);
  if (m) {
    const month = monthNumber(m[1] ?? '');
    return month == null ? null : validDate(fullYear(m[3] ?? ''), month, Number(m[2]));
  }
  return null;
}

const TIME = /^(\d{1,2})[:.](\d{2})(?:[:.]\d{2})?\s*(?:([ap])\.?\s*m\.?)?$/i;

/** "10:59 AM", "2:38 pm", "14:05" → "HH:mm" (24-hour). Null for anything that is not a time of day. */
export function parseStatementTime(text: string | null | undefined): string | null {
  const m = TIME.exec((text ?? '').trim());
  if (!m) return null;
  let hour = Number(m[1]);
  const minute = Number(m[2]);
  const half = m[3]?.toLowerCase();
  if (minute > 59) return null;
  if (half) {
    if (hour < 1 || hour > 12) return null;
    hour = (hour % 12) + (half === 'p' ? 12 : 0);
  } else if (hour > 23) {
    return null;
  }
  return `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
}

// ---------------------------------------------------------------------------
// Amounts
// ---------------------------------------------------------------------------

export type ParsedAmount = {
  /** Always positive. */
  value: number;
  /** Printed negative: a leading/trailing minus or parentheses. */
  negative: boolean;
  /** A Dr / Cr marker printed with the figure. */
  marker: TransactionType | null;
};

const CURRENCY = /(₹|rs\.?|inr|usd|\$|£|€|aed|sgd)/gi;
const TRAILING_MARKER = /(?<=[\d\s(])(dr|cr)\.?\)?$/i;
const LEADING_MARKER = /^(dr|cr)\.?\s*/i;
const DIGITS = /^\d{1,3}(?:,\d{2,3})*(?:\.\d+)?$|^\d+(?:\.\d+)?$/;

/**
 * Parses a printed amount: "1,23,456.78", "1,234.50 Dr", "(250.00)", "-99",
 * "₹ 1,000.00 CR". Both Indian and western digit grouping are accepted.
 * Returns null for anything that is not unambiguously money.
 */
export function parseStatementAmount(text: string | null | undefined): ParsedAmount | null {
  if (text == null) return null;
  let value = text.trim();
  if (!value) return null;

  let marker: TransactionType | null = null;
  for (const pattern of [TRAILING_MARKER, LEADING_MARKER]) {
    const match = pattern.exec(value);
    if (!match) continue;
    marker = (match[1] ?? '').toLowerCase() === 'cr' ? 'credit' : 'debit';
    value = value.replace(pattern, '').trim();
    break;
  }

  value = value.replace(CURRENCY, '').replace(/\s+/g, '');
  let negative = false;
  if (/^\(.*\)$/.test(value)) {
    negative = true;
    value = value.slice(1, -1);
  }
  if (value.startsWith('-') || value.endsWith('-')) {
    negative = true;
    value = value.replace(/^-|-$/g, '');
  } else if (value.startsWith('+')) {
    value = value.slice(1);
  }

  if (!DIGITS.test(value)) return null;
  const amount = Number(value.replace(/,/g, ''));
  if (!Number.isFinite(amount)) return null;
  return { value: Math.abs(amount), negative, marker };
}

/**
 * Whether a cell holds a money figure rather than a date, a reference or a
 * count. Statements print money with exactly two decimals, which is what sets
 * "1,250.00" apart from a cheque number like "004512".
 */
export function looksLikeMoney(text: string): boolean {
  return /\d\.\d{2}(?!\d)/.test(text) && parseStatementAmount(text) != null;
}

/** Whole cents, so comparisons never trip over floating point. */
export const toCents = (amount: number) => Math.round(amount * 100);

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

/** For display and storage: whitespace collapsed, stray separators trimmed. */
export function cleanDescription(raw: string): string {
  return raw
    .replace(/\s+/g, ' ')
    .replace(/^[\s\-/|:,.]+|[\s\-/|:,]+$/g, '')
    .trim();
}

/** For matching only: lower case, letters and digits, single spaces. */
export function normalizeDescription(raw: string | null | undefined): string {
  return (raw ?? '')
    .normalize('NFKD')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}
