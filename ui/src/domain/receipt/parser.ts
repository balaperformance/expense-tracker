/**
 * Turns OCR lines into merchant / total / date / items with confidences.
 * Port of `services/receipt/receipt_parser.dart` — same keyword lists and
 * heuristics, so a receipt reads the same on the phone and on the web.
 */
import { fromParts, today as todayIso, addDays, type IsoDate } from '@/lib/dates';

import { missingField, UNREADABLE_RECEIPT, type ReceiptField, type ReceiptLineItem, type ReceiptResult } from './result';

const TOTAL_KEYWORDS = [
  'total',
  'total amount',
  'amount payable',
  'amount due',
  'balance due',
  'net payable',
  'net amount',
  'grand total',
  'to pay',
];

const TOTAL_DECOYS = [
  'subtotal', 'sub total', 'sub-total', 'total savings', 'total saving',
  'total discount', 'total qty', 'total quantity', 'total items', 'total item',
  'total tax', 'tax total', 'total gst', 'total vat', 'cash total', 'card total',
  'you saved',
];

const MERCHANT_DECOYS = [
  'tax invoice', 'invoice', 'receipt', 'bill of supply', 'cash memo', 'gstin',
  'gst no', 'gst', 'tin', 'pan', 'cin', 'vat', 'phone', 'tel', 'mobile', 'www.',
  'http', '@', 'order no', 'order id', 'bill no', 'invoice no', 'table no',
  'counter', 'cashier', 'terminal', 'welcome to', 'thank you',
];

const ITEM_DECOYS = [
  'bill no', 'bill number', 'invoice', 'order no', 'order id', 'receipt no',
  'ref no', 'date', 'time', 'gstin', 'tin no', 'phone', 'table no', 'counter',
  'cashier', 'total', 'subtotal', 'sub total', 'tax', 'gst', 'cgst', 'sgst',
  'igst', 'vat', 'cess', 'discount', 'savings', 'change', 'cash', 'card', 'upi',
  'tender', 'balance', 'round off', 'rounding', 'amount', 'paid', 'payable', 'qty',
];

const collapseSpaces = (value: string) => value.replace(/\s+/g, ' ').trim();
const containsAny = (lower: string, needles: readonly string[]) => needles.some((n) => lower.includes(n));
const countWhere = (value: string, test: (c: number) => boolean) => {
  let count = 0;
  for (let i = 0; i < value.length; i++) if (test(value.charCodeAt(i))) count++;
  return count;
};
const isLetter = (c: number) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
const isDigit = (c: number) => c >= 48 && c <= 57;

export function parseReceiptLines(lines: readonly string[], now: Date = new Date()): ReceiptResult {
  const cleaned = lines.filter((line) => line.trim()).map(collapseSpaces);
  if (!cleaned.length) return UNREADABLE_RECEIPT;
  return {
    merchant: findMerchant(cleaned),
    total: findTotal(cleaned),
    date: findDate(cleaned, now),
    lineItems: findLineItems(cleaned),
    rawLines: cleaned,
  };
}

export function parseReceiptText(text: string, now?: Date): ReceiptResult {
  return parseReceiptLines(text.split(/[\r\n]+/), now);
}

// ---------------------------------------------------------------------------
// Total
// ---------------------------------------------------------------------------

function totalRank(lower: string): number {
  let rank = -1;
  TOTAL_KEYWORDS.forEach((keyword, i) => {
    if (lower.includes(keyword) && i > rank) rank = i;
  });
  return rank;
}

function findTotal(lines: string[]): ReceiptField<number> {
  let best: number | null = null;
  let bestRank = -1;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? '';
    const lower = line.toLowerCase();
    if (containsAny(lower, TOTAL_DECOYS)) continue;
    const rank = totalRank(lower);
    if (rank < 0) continue;
    // The figure usually sits on the keyword's line; otherwise just below it.
    let amount = lastAmountIn(line);
    amount ??= i + 1 < lines.length ? lastAmountIn(lines[i + 1] ?? '') : null;
    if (amount == null || amount <= 0) continue;
    // A later keyword of equal rank wins: "Grand Total" supersedes "Total".
    if (rank >= bestRank) {
      bestRank = rank;
      best = amount;
    }
  }
  if (best != null) return { value: best, confidence: 'high' };

  // No labelled total: the largest amount is often the one charged — a guess.
  const all = lines.filter((line) => !containsAny(line.toLowerCase(), TOTAL_DECOYS)).flatMap(amountsIn);
  if (!all.length) return missingField();
  const largest = Math.max(...all);
  return { value: largest, confidence: all.length === 1 ? 'low' : 'medium' };
}

// ---------------------------------------------------------------------------
// Merchant
// ---------------------------------------------------------------------------

const PRICE_PATTERN = /\d[.,]\d{2}(?!\d)/;

function couldBeMerchant(line: string): boolean {
  const trimmed = line.trim();
  if (trimmed.length < 3 || trimmed.length > 40) return false;
  const lower = trimmed.toLowerCase();
  if (containsAny(lower, MERCHANT_DECOYS)) return false;
  // A line that states money is a total, an item or a tax row, never the name.
  if (totalRank(lower) >= 0 || containsAny(lower, TOTAL_DECOYS) || PRICE_PATTERN.test(trimmed)) return false;
  const letters = countWhere(trimmed, isLetter);
  if (letters < 3) return false;
  // Mostly digits means an address, a phone number or a bill reference.
  return countWhere(trimmed, isDigit) <= letters;
}

function isShouting(line: string): boolean {
  const upper = countWhere(line, (c) => c >= 65 && c <= 90);
  const lower = countWhere(line, (c) => c >= 97 && c <= 122);
  return upper >= 3 && upper > lower;
}

function titleiseIfShouting(line: string): string {
  const trimmed = line.trim();
  if (!isShouting(trimmed)) return trimmed;
  return trimmed
    .split(' ')
    .map((word) => (word.length <= 1 ? word : `${word[0] ?? ''}${word.slice(1).toLowerCase()}`))
    .join(' ');
}

function findMerchant(lines: string[]): ReceiptField<string> {
  const window = Math.min(lines.length, 6);
  let firstPlausible: string | null = null;
  for (let i = 0; i < window; i++) {
    const line = lines[i] ?? '';
    if (!couldBeMerchant(line)) continue;
    const name = titleiseIfShouting(line);
    // A shouting line near the very top is the classic receipt header.
    if (i < 3 && isShouting(line)) return { value: name, confidence: 'high' };
    firstPlausible ??= name;
  }
  return firstPlausible != null ? { value: firstPlausible, confidence: 'medium' } : missingField();
}

// ---------------------------------------------------------------------------
// Date
// ---------------------------------------------------------------------------

const NUMERIC_DATE = /(\d{1,4})\s*[/\-.]\s*(\d{1,2})\s*[/\-.]\s*(\d{2,4})/;
const NUMERIC_DATE_ALL = new RegExp(NUMERIC_DATE.source, 'g');
const DAY_MONTH_NAME = /(\d{1,2})\s*[-\s]\s*([A-Za-z]{3,9})\.?\s*[-,\s]\s*(\d{2,4})/;
const MONTH_NAME_DAY = /([A-Za-z]{3,9})\.?\s+(\d{1,2})\s*[-,\s]\s*(\d{2,4})/;

const MONTHS: Record<string, number> = {
  jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6,
  jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12,
};

const expandYear = (year: number) => (year < 100 ? 2000 + year : year);

function monthFrom(word: string): number | null {
  const key = word.toLowerCase();
  return key.length < 3 ? null : (MONTHS[key.slice(0, 3)] ?? null);
}

function build(day: number, month: number, year: number): IsoDate | null {
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  if (year < 1990 || year > 2100) return null;
  const date = new Date(year, month - 1, day);
  if (date.getDate() !== day || date.getMonth() !== month - 1) return null;
  return fromParts(year, month, day);
}

function dateIn(line: string): IsoDate | null {
  const numeric = NUMERIC_DATE.exec(line);
  if (numeric) {
    const a = Number(numeric[1]);
    const b = Number(numeric[2]);
    const c = Number(numeric[3]);
    if (a > 31) return build(c, b, a); // yyyy-MM-dd
    // Day-first unless a value above 12 settles it the other way.
    if (a > 12) return build(a, b, expandYear(c));
    if (b > 12) return build(b, a, expandYear(c));
    return build(a, b, expandYear(c));
  }
  const dayFirst = DAY_MONTH_NAME.exec(line);
  if (dayFirst) {
    const month = monthFrom(dayFirst[2] ?? '');
    if (month != null) return build(Number(dayFirst[1]), month, expandYear(Number(dayFirst[3])));
  }
  const monthFirst = MONTH_NAME_DAY.exec(line);
  if (monthFirst) {
    const month = monthFrom(monthFirst[1] ?? '');
    if (month != null) return build(Number(monthFirst[2]), month, expandYear(Number(monthFirst[3])));
  }
  return null;
}

function findDate(lines: string[], now: Date): ReceiptField<string> {
  const tomorrow = addDays(todayIso(now), 1);
  const fiveYearsAgo = fromParts(now.getFullYear() - 5, now.getMonth() + 1, now.getDate());
  for (const line of lines) {
    const parsed = dateIn(line);
    if (parsed == null) continue;
    // Offered either way; a future or very old date is flagged as unsure.
    const plausible = parsed < tomorrow && parsed > fiveYearsAgo;
    return { value: parsed, confidence: plausible ? 'high' : 'low' };
  }
  return missingField();
}

// ---------------------------------------------------------------------------
// Line items & amounts
// ---------------------------------------------------------------------------

const QUANTITY_PREFIX = /^(\d{1,3})\s*(?:x|X|\*)\s*(.+)$/;
const AMOUNT_TOKEN = /\d{1,3}(?:,\d{2,3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?/g;

function toAmount(token: string): number | null {
  const digitsOnly = token.replace(/,/g, '');
  const value = Number(digitsOnly);
  if (!Number.isFinite(value)) return null;
  // A long run of digits with no decimal point is a phone number or an id.
  if (!token.includes('.') && digitsOnly.length >= 8) return null;
  if (value > 99_999_999) return null;
  return value;
}

function amountsIn(line: string): number[] {
  // Strip date- and time-shaped runs first: "12.05.2024" would yield 12.05.
  const withoutDates = line.replace(NUMERIC_DATE_ALL, ' ').replace(/\d{1,2}:\d{2}(?::\d{2})?/g, ' ');
  const found: number[] = [];
  for (const match of withoutDates.matchAll(AMOUNT_TOKEN)) {
    const value = toAmount(match[0]);
    if (value != null) found.push(value);
  }
  return found;
}

function lastAmountIn(line: string): number | null {
  const amounts = amountsIn(line);
  return amounts.length ? (amounts[amounts.length - 1] ?? null) : null;
}

function stripTrailingAmount(line: string): string {
  const matches = [...line.matchAll(AMOUNT_TOKEN)];
  const last = matches[matches.length - 1];
  return last ? line.slice(0, last.index) : line;
}

function findLineItems(lines: string[]): ReceiptLineItem[] {
  const items: ReceiptLineItem[] = [];
  for (const line of lines) {
    if (containsAny(line.toLowerCase(), ITEM_DECOYS)) continue;
    const amount = lastAmountIn(line);
    if (amount == null || amount <= 0) continue;
    const tidy = collapseSpaces(stripTrailingAmount(line).replace(/[.\-_·…]{2,}/g, ' '));
    if (countWhere(tidy, isLetter) < 3) continue;
    const quantity = QUANTITY_PREFIX.exec(tidy);
    items.push({
      description: quantity ? collapseSpaces(quantity[2] ?? '') : tidy,
      amount,
      quantity: quantity ? Number.parseInt(quantity[1] ?? '', 10) || null : null,
    });
  }
  // Dozens of "items" is a misread layout; a wall of wrong rows is worse than none.
  return items.length > 30 ? [] : items;
}
