/**
 * Reads a pasted bank transaction alert. Port of
 * `services/sms/bank_sms_parser.dart` + `bank_sms.dart` — same patterns, same
 * rules, so a message parses identically on the phone and on the web.
 *
 * Runs entirely in the browser; the message is never sent anywhere.
 */
import { fromParts, type IsoDate } from '@/lib/dates';

export type SmsDirection = 'debit' | 'credit';

export type ParsedBankSms = {
  direction: SmsDirection | null;
  amount: number | null;
  bankName: string | null;
  last4: string | null;
  counterparty: string | null;
  date: IsoDate | null;
  reference: string | null;
  availableBalance: number | null;
};

export const UNRECOGNISED_SMS: ParsedBankSms = {
  direction: null,
  amount: null,
  bankName: null,
  last4: null,
  counterparty: null,
  date: null,
  reference: null,
  availableBalance: null,
};

export const smsIsUsable = (sms: ParsedBankSms) => sms.amount != null && sms.amount > 0 && sms.direction != null;

export const MAX_SMS_CHARS = 2000;
const MAX_AMOUNT = 999_999_999;

// ---------------------------------------------------------------------------
// Patterns
// ---------------------------------------------------------------------------

const DEBIT_WORDS = /\b(?:debited|debit|spent|paid|sent|withdrawn|withdrawal|purchased|purchase)\b/i;
const CREDIT_WORDS = /\b(?:credited|credit|received|deposited|deposit|refunded|refund)\b/i;

const CURRENCY_LED = /(?:rs\.?|inr|₹)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)/gi;
const CURRENCY_TRAILED = /([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*(?:rs\.?|inr|₹)/gi;
const BARE_AFTER_VERB =
  /\b(?:debited|credited|spent|paid|sent|withdrawn)\s+(?:by|for|with|of)?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)\b/i;

const BALANCE =
  /(?:avl\.?\s*|available\s*|a\/?c\s*|closing\s*|clear\s*|total\s*)*bal(?:ance)?\.?\s*(?:is\s*)?[:-]?\s*(?:rs\.?|inr|₹)?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)/i;

const ACCOUNT_MARKER = /\b(?:a\/c|ac|account)\b/gi;
const MASKED_DIGITS = /^\s*(?:no\.?|number)?\s*[:#]?\s*[*xX]{0,8}\s*([0-9]{3,6})(?![0-9])/;
const ENDING_DIGITS = /\bending\s*(?:with|in)?\s*[*xX]*\s*([0-9]{4})(?![0-9])/i;
const BARE_BANK_NAME = /\b([A-Z][A-Za-z&.]*(?:\s+[A-Za-z&.]+){0,2}\s+Bank)\b/;

const BANK_NOISE = new Set([
  'from', 'in', 'to', 'at', 'your', 'ur', 'the', 'with', 'on', 'by',
  'is', 'was', 'has', 'been', 'a', 'an', 'rs', 'inr', 'debited',
  'credited', 'spent', 'paid', 'sent', 'withdrawn', 'received', 'deposited',
  'transferred', 'dear', 'customer', 'txn', 'transaction', 'amount', 'using',
  'for', 'via', 'thru', 'through', 'linked',
]);

const PAYEE = new RegExp(
  String.raw`\b(?:to|at)\s+([A-Za-z0-9@][^\n]{1,59}?)` +
    String.raw`(?=\s+on\s+[0-9]` +
    String.raw`|\s+(?:ref|refno|txn|txnid|transaction|upi|utr|rrn|bal|avl|info|dt|` +
    String.raw`date|a/c|not\b|if\b|call\b|thru\b|via\b|from\b)` +
    String.raw`|\s*[.;,]?\s*$)`,
  'gi',
);

const REFERENCE =
  /\b(?:txn\s*(?:id|no\.?|number|num)?|transaction\s*(?:id|no\.?)?|ref(?:erence)?\s*(?:id|no\.?|number|num)?|rrn|utr)\s*[:#-]?\s*([A-Za-z0-9]{4,24})\b/gi;

const ISO_DATE = /(?<![0-9])([0-9]{4})-([0-9]{2})-([0-9]{2})(?![0-9])/;
const NAMED_MONTH_DATE = /(?<![0-9A-Za-z])([0-9]{1,2})[-\s/]([A-Za-z]{3,9})[-\s/]([0-9]{2,4})(?![0-9])/gi;
const SLASH_DATE = /(?<![0-9])([0-9]{1,2})[/-]([0-9]{1,2})[/-]([0-9]{2,4})(?![0-9])/g;
const DOTTED_DATE = /(?<![0-9])([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{2,4})(?![0-9])/g;

const MONTH_NAMES = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

type Span = { start: number; end: number; capture: string | undefined };

// ---------------------------------------------------------------------------

export function parseBankSms(raw: string, now: Date = new Date()): ParsedBankSms {
  const text = normalise(raw);
  if (!text) return UNRECOGNISED_SMS;

  const direction = readDirection(text);
  const balanceMatch = BALANCE.exec(text);
  const balanceSpan: Span | null = balanceMatch
    ? { start: balanceMatch.index, end: balanceMatch.index + balanceMatch[0].length, capture: balanceMatch[1] }
    : null;
  const amount = readAmount(text, balanceSpan);

  // Without these two there is no transaction.
  if (direction == null || amount == null) return UNRECOGNISED_SMS;

  const account = readAccount(text);
  return {
    direction,
    amount,
    bankName: account.bankName,
    last4: account.last4,
    counterparty: readCounterparty(text),
    date: readDate(text, now),
    reference: readReference(text),
    availableBalance: balanceSpan ? toAmount(balanceSpan.capture) : null,
  };
}

function normalise(raw: string): string {
  const capped = raw.length > MAX_SMS_CHARS ? raw.slice(0, MAX_SMS_CHARS) : raw;
  return capped.replace(/\s+/g, ' ').trim();
}

function readDirection(text: string): SmsDirection | null {
  const debit = DEBIT_WORDS.exec(text)?.index ?? -1;
  const credit = CREDIT_WORDS.exec(text)?.index ?? -1;
  if (debit < 0 && credit < 0) return null;
  if (credit < 0) return 'debit';
  if (debit < 0) return 'credit';
  return debit <= credit ? 'debit' : 'credit';
}

const overlaps = (start: number, end: number, span: Span) => start < span.end && end > span.start;

function readAmount(text: string, balance: Span | null): number | null {
  for (const pattern of [CURRENCY_LED, CURRENCY_TRAILED]) {
    for (const match of text.matchAll(pattern)) {
      const start = match.index;
      if (balance && overlaps(start, start + match[0].length, balance)) continue;
      const value = toAmount(match[1]);
      if (value != null) return value;
    }
  }
  const bare = BARE_AFTER_VERB.exec(text);
  if (!bare) return null;
  if (balance && overlaps(bare.index, bare.index + bare[0].length, balance)) return null;
  return toAmount(bare[1]);
}

function toAmount(raw: string | undefined): number | null {
  if (raw == null) return null;
  const value = Number(raw.replace(/,/g, ''));
  if (!Number.isFinite(value) || value <= 0 || value > MAX_AMOUNT) return null;
  return value;
}

function readAccount(text: string): { bankName: string | null; last4: string | null } {
  let last4: string | null = null;
  let bankName: string | null = null;

  for (const marker of text.matchAll(ACCOUNT_MARKER)) {
    const from = marker.index + marker[0].length;
    const to = Math.min(from + 24, text.length);
    const digits = lastFour(MASKED_DIGITS.exec(text.slice(from, to))?.[1]);
    const named = cleanBank(bankBefore(text.slice(0, marker.index)));
    if (digits != null || named != null) {
      last4 = digits;
      bankName = named;
      break;
    }
  }

  last4 ??= lastFour(ENDING_DIGITS.exec(text)?.[1]);
  bankName ??= cleanBank(BARE_BANK_NAME.exec(text)?.[1]);
  return { bankName, last4 };
}

function bankBefore(prefix: string): string | null {
  const words = prefix.split(' ').filter((w) => w.trim().length > 0);
  if (!words.length) return null;
  const tail = words.length <= 4 ? words : words.slice(words.length - 4);
  // Cut after the *last* piece of scaffolding, so a merchant word before a
  // preposition is not carried into the bank's name.
  let start = 0;
  tail.forEach((word, i) => {
    if (isBankNoise(word)) start = i + 1;
  });
  if (start >= tail.length) return null;
  return tail.slice(start).join(' ');
}

function isBankNoise(word: string): boolean {
  const plain = word.toLowerCase().replace(/[^a-z]/g, '');
  return !plain || BANK_NOISE.has(plain) || /[0-9]/.test(word);
}

function cleanBank(raw: string | null | undefined): string | null {
  const trimmed = raw?.trim().replace(/[.,;:]+$/, '');
  if (!trimmed) return null;
  if (trimmed.length > 40) return null;
  if (trimmed.toLowerCase() === 'bank') return null;
  if (!/[A-Za-z]{2}/.test(trimmed)) return null;
  return trimmed;
}

function lastFour(digits: string | null | undefined): string | null {
  if (digits == null || digits.length < 3) return null;
  return digits.length <= 4 ? digits.padStart(4, '0') : digits.slice(digits.length - 4);
}

function readCounterparty(text: string): string | null {
  for (const match of text.matchAll(PAYEE)) {
    const name = cleanPayee(match[1]);
    if (name != null) return name;
  }
  return null;
}

function cleanPayee(raw: string | undefined): string | null {
  const name = raw?.trim().replace(/[.,;:-]+$/, '').trim();
  if (!name || name.length < 2 || name.length > 60) return null;
  // Digits alone are a reference, not a payee.
  if (!/[A-Za-z]{2}/.test(name)) return null;
  const lower = name.toLowerCase();
  if (lower === 'your account' || lower === 'account' || lower === 'bank') return null;
  return name;
}

function readReference(text: string): string | null {
  for (const match of text.matchAll(REFERENCE)) {
    const value = match[1];
    // A "reference" with no digit in it is a word the pattern ran into.
    if (value && /[0-9]/.test(value)) return value;
  }
  return null;
}

function readDate(text: string, now: Date): IsoDate | null {
  const iso = ISO_DATE.exec(text);
  if (iso) {
    const parsed = build(Number(iso[3]), Number(iso[2]), Number(iso[1]), now);
    if (parsed) return parsed;
  }
  for (const match of text.matchAll(NAMED_MONTH_DATE)) {
    const month = monthFromName(match[2] ?? '');
    if (month == null) continue;
    const parsed = build(Number(match[1]), month, Number(match[3]), now);
    if (parsed) return parsed;
  }
  for (const pattern of [SLASH_DATE, DOTTED_DATE]) {
    for (const match of text.matchAll(pattern)) {
      const parsed = build(Number(match[1]), Number(match[2]), Number(match[3]), now);
      if (parsed) return parsed;
    }
  }
  return null;
}

function monthFromName(raw: string): number | null {
  const key = raw.toLowerCase();
  if (key.length < 3) return null;
  const index = MONTH_NAMES.indexOf(key.slice(0, 3));
  return index < 0 ? null : index + 1;
}

function build(day: number, month: number, rawYear: number, now: Date): IsoDate | null {
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  const year = rawYear < 100 ? 2000 + rawYear : rawYear;
  if (year < 2000 || year > now.getFullYear() + 1) return null;
  const candidate = new Date(year, month - 1, day);
  // Rejects 31 February and friends, which Date would roll forward.
  if (candidate.getDate() !== day || candidate.getMonth() !== month - 1) return null;
  return fromParts(year, month, day);
}
