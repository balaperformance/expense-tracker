/**
 * Amount rules and money formatting.
 *
 * The caps mirror the Flutter validators (`Validators.amount`,
 * `TransferValidation.maxAmount`) so an amount the app would refuse in a form
 * is refused here too, and the cents comparison mirrors the transfer check
 * so a full-balance transfer is never rejected by float noise.
 */

export const MAX_AMOUNT = 999_999_999;

export type AmountCheck = { ok: true; value: number } | { ok: false; error: string };

/** Positive, finite, within the cap, rounded to the paisa. */
export function checkAmount(raw: unknown): AmountCheck {
  if (typeof raw !== "number" || !Number.isFinite(raw)) {
    return { ok: false, error: "The amount must be a number." };
  }
  if (raw <= 0) return { ok: false, error: "The amount must be greater than 0." };
  if (raw > MAX_AMOUNT) return { ok: false, error: "That amount is too large." };
  return { ok: true, value: Math.round(raw * 100) / 100 };
}

export function cents(value: number): number {
  return Math.round(value * 100);
}

export function round2(value: number): number {
  return Math.round(value * 100) / 100;
}

const SYMBOLS: Record<string, string> = {
  INR: "₹", USD: "$", EUR: "€", GBP: "£", AUD: "A$", CAD: "C$", SGD: "S$", AED: "AED ", JPY: "¥",
};

export function symbolFor(currency: string): string {
  return SYMBOLS[currency] ?? `${currency} `;
}

/**
 * "₹2,000" for a whole amount, "₹2,000.50" otherwise, Indian grouping for
 * INR. Falls back to a plain fixed-point string if Intl lacks the locale.
 */
export function formatMoney(amount: number, currency: string): string {
  const whole = cents(amount) % 100 === 0;
  const locale = currency === "INR" ? "en-IN" : "en-US";
  try {
    const formatted = new Intl.NumberFormat(locale, {
      minimumFractionDigits: whole ? 0 : 2,
      maximumFractionDigits: 2,
    }).format(Math.abs(amount));
    return `${amount < 0 ? "-" : ""}${symbolFor(currency)}${formatted}`;
  } catch {
    return `${amount < 0 ? "-" : ""}${symbolFor(currency)}${Math.abs(amount).toFixed(whole ? 0 : 2)}`;
  }
}

export function sum(values: number[]): number {
  let total = 0;
  for (const v of values) total += v;
  return round2(total);
}
