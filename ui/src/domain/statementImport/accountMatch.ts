/**
 * Matching an account a statement names — "Airtel Payments Bank - 14",
 * "HDFC Bank - 59", "SBI XX1234" — to one of the user's own.
 *
 * The same rules as the bank-SMS matcher (smsDraft.ts), made strict enough to
 * act on without asking: the printed digits must be the end of the account's
 * number AND the bank's identifying words must agree. Payment apps print only
 * the last two digits, which alone are not enough to tell two accounts apart.
 * Never guesses: no account, or more than one, is no match, and the user
 * chooses in review.
 */
import type { BankAccount } from '../models';
import { identifyingWords } from '../sms/smsDraft';

export type PrintedAccount = { bank: string; digits: string };

/** "<bank> - 14", "<bank> A/c XX1234", "<bank> ending 1234", "<bank> ••1234". */
const PRINTED = /^(.*?[a-z].*?)[\s:–—-]*(?:(?:a\/?c|acct?|account)(?:\s*no\.?)?[\s:.-]*)?(?:ending(?:\s+in)?\s*)?[x*•·.]*\s*(\d{2,6})$/i;

export function parsePrintedAccount(text: string | null | undefined): PrintedAccount | null {
  const value = (text ?? '').replace(/\s+/g, ' ').trim();
  const m = PRINTED.exec(value);
  if (!m) return null;
  const bank = (m[1] ?? '').replace(/[\s:–—-]+$/, '').trim();
  return bank ? { bank, digits: m[2] ?? '' } : null;
}

const digitsOf = (raw: string | null | undefined) => (raw ?? '').replace(/[^0-9]/g, '');

/** The printed digits are the end of the stored number — or, when fewer are stored, the other way round. */
function digitsAgree(printed: string, stored: string): boolean {
  if (printed.length < 2 || stored.length < 2) return false;
  return stored.length >= printed.length ? stored.endsWith(printed) : printed.endsWith(stored);
}

/** "State Bank of India" → sbi, sboi: what such a name is often shortened to. Only for names of three words or more. */
function acronyms(name: string | null | undefined): string[] {
  const words = (name ?? '').toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
  if (words.length < 3) return [];
  const all = words.map((w) => w[0] ?? '').join('');
  const content = words
    .filter((w) => w !== 'of' && w !== 'the' && w !== 'and')
    .map((w) => w[0] ?? '')
    .join('');
  return [...new Set([all, content])].filter((a) => a.length >= 2);
}

const nameWords = (name: string | null | undefined) => new Set([...identifyingWords(name), ...acronyms(name)]);

/** The whole name in plain words, for names made only of generic ones ("Indian Bank"). */
const plainName = (name: string | null | undefined) =>
  (name ?? '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .replace(/\b(ltd|limited|the)\b/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

/** Whether the printed bank is the account's bank, by the words that identify banks. */
function namesAgree(printedBank: string, account: BankAccount): boolean {
  const printed = nameWords(printedBank);
  if (printed.size) {
    const mine = new Set([...nameWords(account.bankName), ...nameWords(account.nickname)]);
    return [...printed].some((w) => mine.has(w));
  }
  const plain = plainName(printedBank);
  return plain !== '' && (plainName(account.bankName) === plain || plainName(account.nickname) === plain);
}

/**
 * The one account [text] names, or null. [exceptId] leaves out an account —
 * the row's own, when looking for the other side of a transfer.
 */
export function matchPrintedAccount(
  text: string | null | undefined,
  accounts: readonly BankAccount[],
  { exceptId }: { exceptId?: string } = {},
): BankAccount | null {
  const printed = parsePrintedAccount(text);
  if (!printed) return null;
  const hits = accounts.filter((a) => a.id !== exceptId && digitsAgree(printed.digits, digitsOf(a.last4)) && namesAgree(printed.bank, a));
  const [only] = hits;
  return hits.length === 1 && only ? only : null;
}
