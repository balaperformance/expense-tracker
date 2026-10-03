/** Money as whole cents, so sums never drift; and how an amount reads in a notification. */

export const toCents = (amount: number): number => Math.round(amount * 100);

/** Currencies the app offers (src/lib/format.ts); the symbol is display-only. */
const SYMBOLS: Record<string, string> = {
  INR: '₹',
  USD: '$',
  EUR: '€',
  GBP: '£',
  AUD: '$',
  CAD: '$',
  SGD: '$',
  AED: 'د.إ',
  JPY: '¥',
};

const formats = new Map<string, Intl.NumberFormat>();

function numberFormat(currency: string, fraction: boolean): Intl.NumberFormat {
  const locale = currency === 'INR' ? 'en-IN' : 'en-US';
  const key = `${locale}:${fraction}`;
  let format = formats.get(key);
  if (!format) {
    format = new Intl.NumberFormat(locale, { minimumFractionDigits: fraction ? 2 : 0, maximumFractionDigits: fraction ? 2 : 0 });
    formats.set(key, format);
  }
  return format;
}

/**
 * `₹12,450`, `₹420.50`, `-₹120`: Indian grouping for INR, the symbol the app
 * uses, and paise only when there are some.
 */
export function formatAmount(cents: number, currency: string): string {
  const symbol = SYMBOLS[currency] ?? currency;
  const abs = Math.abs(cents);
  const text = numberFormat(currency, abs % 100 !== 0).format(abs / 100);
  return `${cents < 0 && abs >= 1 ? '-' : ''}${symbol}${text}`;
}
