/**
 * Form validators shared across auth and transaction forms.
 * Port of `core/utils/validators.dart` — same rules, same wording.
 * Each returns an error message, or null when the value is acceptable.
 */

const EMAIL = /^[\w.+-]+@[\w-]+\.[\w.-]+$/;

export const MIN_NEW_PASSWORD_LENGTH = 8;
export const PASSWORD_HINT = `At least ${MIN_NEW_PASSWORD_LENGTH} characters, with a letter and a number.`;
export const MAX_AMOUNT = 999_999_999;

export function validateEmail(value: string): string | null {
  const input = value.trim();
  if (!input) return 'Email is required';
  if (!EMAIL.test(input)) return 'Enter a valid email address';
  return null;
}

/** Sign-in only: lenient on purpose — strength rules belong where a password is chosen. */
export function validatePassword(value: string): string | null {
  if (!value) return 'Password is required';
  if (value.length < 6) return 'Use at least 6 characters';
  return null;
}

/** Registration and change-password: the strength rule. */
export function validateNewPassword(value: string): string | null {
  if (!value) return 'Password is required';
  if (value.length < MIN_NEW_PASSWORD_LENGTH) return `Use at least ${MIN_NEW_PASSWORD_LENGTH} characters`;
  if (value.trim() !== value) return 'Remove the spaces at the start or end';
  if (!/[A-Za-z]/.test(value)) return 'Include at least one letter';
  if (!/[0-9]/.test(value)) return 'Include at least one number';
  return null;
}

export function validateConfirmPassword(value: string, original: string): string | null {
  if (!value) return 'Confirm your password';
  if (value !== original) return 'Passwords do not match';
  return null;
}

export function validateRequired(value: string, label: string): string | null {
  return value.trim() ? null : `${label} is required`;
}

/** Parses "1,234.50" → 1234.5; null when it is not a number. */
export function parseAmount(value: string): number | null {
  const input = value.trim().replace(/,/g, '');
  if (!input) return null;
  if (!/^-?\d*\.?\d*$/.test(input) || input === '.' || input === '-') return null;
  const parsed = Number(input);
  return Number.isFinite(parsed) ? parsed : null;
}

/** Amount must parse and be strictly greater than zero. */
export function validateAmount(value: string): string | null {
  if (!value.trim()) return 'Amount is required';
  const parsed = parseAmount(value);
  if (parsed == null) return 'Enter a valid number';
  if (parsed <= 0) return 'Amount must be greater than 0';
  if (parsed > MAX_AMOUNT) return 'Amount is too large';
  return null;
}

/** "1234.50" for 1234.5, "1200" for 1200 — how a stored amount is put back in a field. */
export function amountToInput(value: number): string {
  const text = value.toFixed(2);
  return text.endsWith('.00') ? text.slice(0, -3) : text;
}

/** Keeps the typed amount to digits, one point and two decimals. */
export function sanitiseAmountInput(raw: string, allowNegative = false): string {
  let value = raw.replace(/[^\d.,-]/g, '').replace(/,/g, '');
  const negative = allowNegative && value.startsWith('-');
  value = value.replace(/-/g, '');
  const [whole = '', ...rest] = value.split('.');
  const decimals = rest.join('').slice(0, 2);
  const joined = rest.length ? `${whole}.${decimals}` : whole;
  return `${negative ? '-' : ''}${joined}`;
}
