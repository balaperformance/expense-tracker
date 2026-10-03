/**
 * From a parsed bank message to a reviewable expense draft.
 * Ports of `sms_account_matcher.dart`, `sms_expense_draft.dart` and the pure
 * half of `sms_category_assistant.dart`.
 */
import type { IsoDate } from '@/lib/dates';

import type { BankAccount, ExpenseCategory } from '../models';
import { suggestCategoryForText } from '../receipt/suggester';

import type { ParsedBankSms } from './bankSmsParser';

// ---------------------------------------------------------------------------
// Account matching
// ---------------------------------------------------------------------------

export type SmsMatchStrength = 'exact' | 'likely';

export type SmsAccountMatch = { account: BankAccount; strength: SmsMatchStrength; reason: string };

const GENERIC_BANK_WORDS = new Set([
  'bank', 'banks', 'banking', 'payments', 'payment', 'ltd', 'limited',
  'india', 'indian', 'the', 'of', 'and', 'co', 'corporation', 'finance',
  'financial', 'services', 'account', 'savings', 'current', 'a/c', 'ac',
]);

/** A bank or account name's words that tell banks apart ("HDFC Bank Salary" → hdfc, salary). Shared with statement import. */
export function identifyingWords(name: string | null | undefined): Set<string> {
  if (!name) return new Set();
  return new Set(
    name
      .toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter((w) => w.length > 1 && !GENERIC_BANK_WORDS.has(w)),
  );
}

function lastDigits(raw: string | null | undefined): string | null {
  const cleaned = (raw ?? '').replace(/[^0-9]/g, '');
  return cleaned.length < 4 ? null : cleaned.slice(cleaned.length - 4);
}

function matchByBankName(sms: ParsedBankSms, accounts: readonly BankAccount[]): SmsAccountMatch | null {
  const wanted = identifyingWords(sms.bankName);
  if (!wanted.size) return null;
  const hits = accounts.filter((account) => {
    const mine = new Set([...identifyingWords(account.bankName), ...identifyingWords(account.nickname)]);
    return [...mine].some((w) => wanted.has(w));
  });
  const [only] = hits;
  if (hits.length !== 1 || !only) return null;
  return { account: only, strength: 'likely', reason: `the only ${sms.bankName ?? ''} account` };
}

/**
 * Finds the account a message is about. Digits win outright; a bank-name
 * match is offered only when it cannot contradict digits the message stated.
 * Never guesses between two candidates — that is the user's call.
 */
export function matchSmsAccount(sms: ParsedBankSms, accounts: readonly BankAccount[]): SmsAccountMatch | null {
  const usable = accounts.filter((a) => a.isActive);
  if (!usable.length) return null;

  const last4 = sms.last4;
  if (last4 != null) {
    const byDigits = usable.filter((a) => lastDigits(a.last4) === last4);
    const [only] = byDigits;
    if (byDigits.length === 1 && only) {
      return { account: only, strength: 'exact', reason: `account ending ${last4}` };
    }
    if (byDigits.length > 1) return null;
    // Digits named but on no account: only an account with no digits on file
    // cannot contradict them.
    const unmasked = usable.filter((a) => lastDigits(a.last4) == null);
    return unmasked.length ? matchByBankName(sms, unmasked) : null;
  }
  return matchByBankName(sms, usable);
}

// ---------------------------------------------------------------------------
// Draft
// ---------------------------------------------------------------------------

export type SmsCategorySource = 'keyword' | 'assistant' | 'fallback' | 'user' | 'none';

export type SmsExpenseDraft = {
  amount: number;
  date: IsoDate;
  merchant: string | null;
  categoryId: string | null;
  categorySource: SmsCategorySource;
  categoryReason: string | null;
  bankAccountId: string | null;
  accountMatch: SmsAccountMatch | null;
  reference: string | null;
};

const FALLBACK_NAMES = ['other', 'others', 'miscellaneous', 'misc', 'uncategorised', 'uncategorized', 'general'];

export function fallbackCategory(categories: readonly ExpenseCategory[]): ExpenseCategory | null {
  for (const wanted of FALLBACK_NAMES) {
    const hit = categories.find((c) => c.name.trim().toLowerCase() === wanted);
    if (hit) return hit;
  }
  return null;
}

export function categoryByName(categories: readonly ExpenseCategory[], name: string | null | undefined) {
  const wanted = name?.trim().toLowerCase();
  if (!wanted) return null;
  return categories.find((c) => c.name.trim().toLowerCase() === wanted) ?? null;
}

export function buildSmsDraft({
  sms,
  accounts,
  categories,
  today,
}: {
  sms: ParsedBankSms;
  accounts: readonly BankAccount[];
  categories: readonly ExpenseCategory[];
  today: IsoDate;
}): SmsExpenseDraft {
  const match = matchSmsAccount(sms, accounts);
  const keyword = sms.counterparty == null ? null : suggestCategoryForText(sms.counterparty, categories);
  const fallback = fallbackCategory(categories);
  return {
    amount: sms.amount ?? 0,
    date: sms.date ?? today,
    merchant: sms.counterparty,
    categoryId: keyword?.value.id ?? fallback?.id ?? null,
    categorySource: keyword ? 'keyword' : fallback ? 'fallback' : 'none',
    categoryReason: keyword?.reason ?? null,
    bankAccountId: match?.account.id ?? null,
    accountMatch: match,
    reference: sms.reference,
  };
}

/** Whether the assistant's `classify` is worth asking — only the payee is ever sent. */
export function shouldAskAssistant(draft: SmsExpenseDraft, categories: readonly ExpenseCategory[]): boolean {
  return draft.merchant != null && draft.categorySource !== 'keyword' && categories.length > 0;
}

/** Applies an assistant suggestion, but only if it names one of the user's own categories. */
export function applyAssistantCategory(
  draft: SmsExpenseDraft,
  categories: readonly ExpenseCategory[],
  suggestedName: string | null,
): SmsExpenseDraft {
  const suggested = categoryByName(categories, suggestedName);
  if (!suggested || draft.merchant == null) return draft;
  return {
    ...draft,
    categoryId: suggested.id,
    categorySource: 'assistant',
    categoryReason: `suggested for "${draft.merchant}"`,
  };
}

/** The reference is stored in `notes` in this fixed format, which the duplicate check searches for. */
export const SMS_REFERENCE_PREFIX = 'Bank SMS ref';
export const smsReferenceNote = (reference: string) => `${SMS_REFERENCE_PREFIX} ${reference}`;

export function describeUnmatchedAccount(sms: ParsedBankSms): string {
  if (sms.bankName == null && sms.last4 == null) return 'The message';
  return `${sms.bankName ?? 'The bank'}${sms.last4 == null ? '' : ` ••••${sms.last4}`}`;
}
