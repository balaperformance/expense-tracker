/**
 * Display formatting for money and dates. Port of `core/utils/formatters.dart`.
 */
import { daysBetween, parts, today, type IsoDate } from './dates';

export const DEFAULT_CURRENCY = 'INR';

/** Currencies offered in Settings. The symbol is display-only. */
export const SUPPORTED_CURRENCIES: ReadonlyArray<readonly [code: string, symbol: string]> = [
  ['INR', '₹'],
  ['USD', '$'],
  ['EUR', '€'],
  ['GBP', '£'],
  ['AUD', '$'],
  ['CAD', '$'],
  ['SGD', '$'],
  ['AED', 'د.إ'],
  ['JPY', '¥'],
];

const SYMBOLS = new Map<string, string>(SUPPORTED_CURRENCIES.map(([code, symbol]) => [code, symbol]));

export function currencySymbol(code: string): string {
  return SYMBOLS.get(code) ?? code;
}

const numberFormats = new Map<string, Intl.NumberFormat>();

function numberFormat(code: string): Intl.NumberFormat {
  const locale = code === 'INR' ? 'en-IN' : 'en-US';
  let format = numberFormats.get(locale);
  if (!format) {
    format = new Intl.NumberFormat(locale, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    numberFormats.set(locale, format);
  }
  return format;
}

function compact(abs: number): string {
  if (abs >= 10_000_000) return `${(abs / 10_000_000).toFixed(2)}Cr`;
  if (abs >= 100_000) return `${(abs / 100_000).toFixed(2)}L`;
  return `${(abs / 1000).toFixed(1)}K`;
}

/**
 * `₹1,23,456.00` (Indian grouping for INR), `$1,234.56` elsewhere.
 * [compact] shortens amounts of 1,000 and over: `₹1.5K`, `₹2.40L`, `₹1.10Cr`.
 */
export function formatCurrency(amount: number, code: string = DEFAULT_CURRENCY, options?: { compact?: boolean }): string {
  const symbol = currencySymbol(code);
  const abs = Math.abs(amount);
  const sign = amount < 0 && abs >= 0.005 ? '-' : '';
  if (options?.compact && abs >= 1000) return `${sign}${symbol}${compact(abs)}`;
  return `${sign}${symbol}${numberFormat(code).format(abs)}`;
}

const MONTHS = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
const WEEKDAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

const shortMonthName = (month: number) => (MONTHS[month - 1] ?? '').slice(0, 3);

/** `5 Sep` */
export function dayMonth(iso: IsoDate): string {
  const { month, day } = parts(iso);
  return `${day} ${shortMonthName(month)}`;
}

/** `5 Sep 2026` */
export function dayMonthYear(iso: IsoDate): string {
  const { year, month, day } = parts(iso);
  return `${day} ${shortMonthName(month)} ${year}`;
}

/** `September 2026` */
export function monthYear(iso: IsoDate): string {
  const { year, month } = parts(iso);
  return `${MONTHS[month - 1] ?? ''} ${year}`;
}

/** `Sep` */
export function shortMonth(iso: IsoDate): string {
  return shortMonthName(parts(iso).month);
}

function weekday(iso: IsoDate): string {
  const { year, month, day } = parts(iso);
  return WEEKDAYS[new Date(year, month - 1, day).getDay()] ?? '';
}

/** "Today" / "Yesterday" / "Monday" / "12 Mar" / "12 Mar 2025" depending on recency. */
export function relativeDay(iso: IsoDate, now: Date = new Date()): string {
  const current = today(now);
  const diff = daysBetween(iso, current);
  if (diff === 0) return 'Today';
  if (diff === 1) return 'Yesterday';
  if (diff > 1 && diff < 7) return weekday(iso);
  if (iso.slice(0, 4) === current.slice(0, 4)) return dayMonth(iso);
  return dayMonthYear(iso);
}

/** `1st`, `2nd`, `3rd`, `11th`, `22nd` — a day of the month in words. */
export function ordinal(n: number): string {
  const tens = n % 100;
  if (tens >= 11 && tens <= 13) return `${n}th`;
  switch (n % 10) {
    case 1:
      return `${n}st`;
    case 2:
      return `${n}nd`;
    case 3:
      return `${n}rd`;
    default:
      return `${n}th`;
  }
}

/** `42%` — clamped to 0–999 like the Flutter formatter. */
export function formatPercent(ratio: number): string {
  const value = Math.min(Math.max(ratio * 100, 0), 999);
  return `${value.toFixed(0)}%`;
}

export function greeting(now: Date = new Date()): string {
  const hour = now.getHours();
  if (hour < 12) return 'Good morning';
  if (hour < 17) return 'Good afternoon';
  return 'Good evening';
}

/** "14:06" → `2:06 PM`; anything that is not "HH:mm" comes back unchanged. */
export function formatTime(hhmm: string): string {
  const m = /^(\d{1,2}):(\d{2})/.exec(hhmm);
  if (!m) return hhmm;
  const hour = Number(m[1]);
  return `${String(hour % 12 || 12)}:${m[2] ?? '00'} ${hour < 12 ? 'AM' : 'PM'}`;
}

/** `2026-09-24 18:05` */
export function timestamp(when: Date): string {
  const p = (v: number) => String(v).padStart(2, '0');
  return `${when.getFullYear()}-${p(when.getMonth() + 1)}-${p(when.getDate())} ${p(when.getHours())}:${p(when.getMinutes())}`;
}
