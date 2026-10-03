/**
 * Deterministic classification — no AI, no network.
 *
 *   own-account transfer, cash withdrawal, card bill  → transfer (not spending)
 *   credit + refund / reversal wording                → refund   (not income)
 *   other credits                                     → income, with a source when obvious
 *   other debits                                      → expense, category by keyword, else "Other"
 *
 * The merchant keywords are the same table the receipt scanner and SMS import
 * use, so a payee is categorised the same way wherever it comes from.
 * Categories are only ever the user's own, matched by name.
 */
import type { ExpenseCategory } from '../models';
import { suggestCategoryForText } from '../receipt/suggester';
import { categoryByName, fallbackCategory } from '../sms/smsDraft';
import type { TransferTarget } from '../treatment';

import type { CategorySource, TransactionChannel, TransactionKind, TransactionType } from './model';

export type ClassifyContext = {
  categories: readonly ExpenseCategory[];
  /** Last digits of the user's *other* accounts, for spotting self-transfers. */
  otherAccountLast4: readonly string[];
  /** The same other accounts with their ids, so a self-transfer can name its other side. */
  otherAccounts?: readonly { id: string; last4: string | null }[];
  /** The user's active credit cards, for recognising a bill payment by the card's digits. */
  cards?: readonly { id: string; last4: string | null }[];
};

export type Classification = {
  kind: TransactionKind;
  category: string | null;
  categorySource: CategorySource;
  categoryReason: string | null;
  /** Set when the debit pays one of the user's cards: imported as that card's bill payment. */
  creditCardId?: string | null;
  /** For a transfer, the other side when the narration makes it certain. */
  transferTarget?: TransferTarget | null;
};

const CASH: TransferTarget = { type: 'cash' };

/** The one other account ending in [digits]; two accounts sharing them is no answer. */
function accountWithDigits(digits: string, accounts: ClassifyContext['otherAccounts']): TransferTarget | null {
  const hits = (accounts ?? []).filter((a) => (a.last4 ?? '').replace(/[^0-9]/g, '') === digits);
  const [only] = hits;
  return hits.length === 1 && only ? { type: 'account', accountId: only.id } : null;
}

const SELF_TRANSFER = /\b(self|to self|from self|own a ?\/? ?c|own account|sweep ?(in|out)?|linked a ?\/? ?c)\b/;
const CASH_WITHDRAWAL = /\b(atm|cash wdl|cash withdrawal|cash wd|nwd|awd|atw|cwdr)\b/;
const CARD_BILL = /\b(credit card|cc)\b.*\b(payment|pymt|pay|bill)\b|\bcard ?bill\b/;
const REFUND = /\b(refund|refunded|reversal|reversed|rev|chargeback|cashback|rfnd)\b/;
const BANK_CHARGE = /\b(charges?|chrgs?|chgs|fee|fees|gst|amc|penalty|sms alert|annual maint)\b/;

const INCOME_SOURCES: ReadonlyArray<readonly [string, RegExp]> = [
  ['Salary', /\b(salary|sal cr|payroll|sal for)\b/],
  ['Interest', /\b(interest|int pd|int paid|int cr|sb int|int credit)\b/],
  ['Dividend', /\b(dividend|div)\b/],
];

const CARD_WORDING = /\b(credit ?cards?|cards?|cc)\b/;

/**
 * The one card a debit pays: card wording plus the card's last four digits.
 * Digits alone could be an amount or a reference, so both are required, and
 * two cards matching is no match.
 */
function paidCard(text: string, cards: ClassifyContext['cards']): { id: string; digits: string } | null {
  if (!cards?.length || !CARD_WORDING.test(text)) return null;
  const hits = cards.filter((c) => {
    const digits = (c.last4 ?? '').replace(/[^0-9]/g, '');
    return digits.length === 4 && new RegExp(`(^|[^0-9])${digits}([^0-9]|$)`).test(text);
  });
  const [only] = hits;
  return hits.length === 1 && only ? { id: only.id, digits: (only.last4 ?? '').replace(/[^0-9]/g, '') } : null;
}

function mentionsOwnAccount(text: string, last4s: readonly string[]): string | null {
  for (const digits of last4s) {
    if (digits.length >= 4 && new RegExp(`(^|[^0-9])${digits}([^0-9]|$)`).test(text)) return digits;
  }
  return null;
}

/**
 * What a channel settles on its own. Channels come from bank parsers that
 * understand their bank's narration codes; rows without one fall through to
 * the wording rules below, exactly as before.
 */
function byChannel(channel: TransactionChannel, type: TransactionType, ctx: ClassifyContext): Classification | null {
  const none = { category: null, categorySource: 'none' as const };
  const bills = () => {
    const category = categoryByName(ctx.categories, 'Bills') ?? fallbackCategory(ctx.categories);
    return category ? { category: category.name, categorySource: 'rule' as const } : none;
  };
  switch (channel) {
    case 'atm':
      return type === 'debit'
        ? { kind: 'transfer', ...none, categoryReason: 'cash withdrawal — record cash spending separately', transferTarget: CASH }
        : null;
    case 'cardBill':
      return type === 'debit' ? { kind: 'transfer', ...none, categoryReason: 'credit card bill — the card spending is recorded on its own' } : null;
    case 'reversal':
      return type === 'credit' ? { kind: 'refund', ...none, categoryReason: 'reversal' } : null;
    case 'interest':
      return type === 'credit' ? { kind: 'income', category: 'Interest', categorySource: 'rule', categoryReason: 'interest credit' } : null;
    case 'loan':
      return type === 'debit' ? { kind: 'expense', ...bills(), categoryReason: 'loan repayment' } : null;
    case 'charges':
      return type === 'debit' ? { kind: 'expense', ...bills(), categoryReason: 'bank charge' } : null;
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// Tags and notes
// ---------------------------------------------------------------------------

/**
 * Category names a statement's tag usually means, in the order to try them.
 * Only ever matched to categories the user already has — never created. A tag
 * not listed here still finds a category of its own name. Groceries and fuel
 * fall back to Food and Transport, as the receipt keywords already do.
 */
const TAG_CATEGORY_NAMES: ReadonlyArray<readonly [RegExp, readonly string[]]> = [
  [/^(bills?|bill payments?|utilit(y|ies)|recharges?|mobile recharge|electricity|broadband|internet|dth)$/, ['Bills', 'Utilities', 'Bill Payments']],
  [/^grocer(y|ies)$/, ['Groceries', 'Grocery', 'Food']],
  [/^(food|food (and|&) (drinks?|dining)|dining|dining out|eating out|restaurants?)$/, ['Food', 'Dining', 'Food & Dining']],
  [/^(fuel|petrol|diesel)$/, ['Fuel', 'Transport', 'Transportation']],
  [/^(transport|transportation|commute|cabs?|taxi)$/, ['Transport', 'Transportation']],
  [/^(travel|trips?|holidays?)$/, ['Travel']],
  [/^(entertainment|movies?)$/, ['Entertainment']],
  [/^shopping$/, ['Shopping']],
  [/^(health|healthcare|medical|medicines?|pharmacy)$/, ['Health', 'Medical', 'Healthcare']],
  [/^(education|fees|school fees|tuition)$/, ['Education']],
  [/^(rent|house rent)$/, ['Rent', 'Housing']],
];

const escapeRegExp = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** The one category a note names outright ("…Broadband Bill Payment" names Bills), singular or plural. */
function categoryNamedIn(note: string, categories: readonly ExpenseCategory[], except: string | null): ExpenseCategory | null {
  const text = note.toLowerCase();
  const hits = categories.filter((c) => {
    if (c.id === except) return false;
    const name = c.name.trim().toLowerCase();
    if (name.length < 3) return false;
    const forms = new Set([name, name.endsWith('s') ? name.slice(0, -1) : `${name}s`]);
    return [...forms].some((form) => new RegExp(`(^|[^a-z0-9])${escapeRegExp(form)}([^a-z0-9]|$)`).test(text));
  });
  const [only] = hits;
  return hits.length === 1 && only ? only : null;
}

/**
 * A category from what the statement itself says a payment was for: its tag
 * first (the user chose it), then its note. Null when neither names one of the
 * user's categories safely — the row is then categorised as before, and left
 * for review if nothing fits.
 */
export function categoryFromTagsAndNotes(
  tags: readonly string[],
  notes: string | null,
  categories: readonly ExpenseCategory[],
): { category: ExpenseCategory; reason: string } | null {
  if (!categories.length) return null;
  const fallback = fallbackCategory(categories);
  // The catch-all category is what an unrecognised row gets anyway: never a match.
  const usable = (c: ExpenseCategory | null | undefined) => (c && c.id !== fallback?.id ? c : null);
  for (const tag of tags) {
    const exact = usable(categoryByName(categories, tag));
    if (exact) return { category: exact, reason: `tagged "${tag}"` };
  }
  for (const tag of tags) {
    const key = tag.toLowerCase().replace(/\s+/g, ' ').trim();
    const names = TAG_CATEGORY_NAMES.find(([pattern]) => pattern.test(key))?.[1] ?? [];
    for (const name of names) {
      const hit = usable(categoryByName(categories, name));
      if (hit) return { category: hit, reason: `tagged "${tag}"` };
    }
  }
  if (notes?.trim()) {
    const named = categoryNamedIn(notes, categories, fallback?.id ?? null);
    if (named) return { category: named, reason: `the note mentions ${named.name.toLowerCase()}` };
  }
  for (const tag of tags) {
    const keyword = suggestCategoryForText(` ${tag.toLowerCase()} `, categories);
    const hit = usable(keyword?.value);
    if (keyword && hit) return { category: hit, reason: `tagged "${tag}" — ${keyword.reason}` };
  }
  if (notes?.trim()) {
    const keyword = suggestCategoryForText(` ${notes.toLowerCase()} `, categories);
    const hit = usable(keyword?.value);
    if (keyword && hit) return { category: hit, reason: `note ${keyword.reason}` };
  }
  return null;
}

export function classifyTransaction(
  t: {
    description: string;
    rawDescription: string;
    transactionType: TransactionType;
    counterparty?: string | null;
    channel?: TransactionChannel | null;
    /** The statement's own tags and note on the row (a payment app's statement), if any. */
    tags?: readonly string[] | null;
    notes?: string | null;
  },
  ctx: ClassifyContext,
): Classification {
  const text = `${t.rawDescription} ${t.description}`.toLowerCase().replace(/\s+/g, ' ');
  const none = { category: null, categorySource: 'none' as const, categoryReason: null };

  const own = mentionsOwnAccount(text, ctx.otherAccountLast4);
  if (own) {
    return { kind: 'transfer', ...none, categoryReason: `mentions your account ending ${own}`, transferTarget: accountWithDigits(own, ctx.otherAccounts) };
  }
  if (SELF_TRANSFER.test(text)) return { kind: 'transfer', ...none, categoryReason: 'a transfer to or from yourself' };

  // Paying one of the user's own cards is never spending: the purchases already are.
  if (t.transactionType === 'debit') {
    const card = paidCard(text, ctx.cards);
    if (card) {
      return {
        kind: 'transfer',
        ...none,
        categoryReason: `pays your credit card ending ${card.digits} — linked as its bill payment`,
        creditCardId: card.id,
        transferTarget: { type: 'card', cardId: card.id },
      };
    }
  }

  if (t.channel) {
    const settled = byChannel(t.channel, t.transactionType, ctx);
    if (settled) return settled;
  }
  // With a known payee, match merchants on the payee alone: handles, IFSCs and
  // reference numbers in a narration only produce false keyword hits.
  const merchantText = t.counterparty?.trim() ? ` ${t.counterparty.toLowerCase()} ` : text;

  if (t.transactionType === 'debit') {
    if (CASH_WITHDRAWAL.test(text)) {
      return { kind: 'transfer', ...none, categoryReason: 'cash withdrawal — record cash spending separately', transferTarget: CASH };
    }
    if (CARD_BILL.test(text)) return { kind: 'transfer', ...none, categoryReason: 'credit card bill — the card spending is recorded on its own' };
  }

  if (t.transactionType === 'credit') {
    if (REFUND.test(text)) return { kind: 'refund', ...none, categoryReason: 'refund or reversal' };
    for (const [source, pattern] of INCOME_SOURCES) {
      if (pattern.test(text)) return { kind: 'income', category: source, categorySource: 'rule', categoryReason: `matched '${source.toLowerCase()}'` };
    }
    return { kind: 'income', ...none };
  }

  // What the statement says the payment was for outranks guessing from the payee.
  if (t.tags?.length || t.notes?.trim()) {
    const tagged = categoryFromTagsAndNotes(t.tags ?? [], t.notes ?? null, ctx.categories);
    if (tagged) return { kind: 'expense', category: tagged.category.name, categorySource: 'rule', categoryReason: tagged.reason };
  }

  if (BANK_CHARGE.test(text)) {
    const bills = categoryByName(ctx.categories, 'Bills');
    if (bills) return { kind: 'expense', category: bills.name, categorySource: 'rule', categoryReason: 'bank charge' };
  }
  const keyword = suggestCategoryForText(merchantText, ctx.categories);
  if (keyword) return { kind: 'expense', category: keyword.value.name, categorySource: 'rule', categoryReason: keyword.reason };

  const fallback = fallbackCategory(ctx.categories);
  return fallback
    ? { kind: 'expense', category: fallback.name, categorySource: 'fallback', categoryReason: 'not recognised' }
    : { kind: 'expense', ...none };
}

/**
 * The optional AI hook, for later. Given descriptions the rules could not
 * categorise, returns a category name per description (or null). An
 * implementation would send descriptions only — never amounts, dates,
 * balances or the statement — through the existing `ai-chat` Edge Function,
 * one small batch at a time. Nothing calls this yet.
 */
export type CategoryAssistant = (descriptions: readonly string[]) => Promise<ReadonlyMap<string, string | null>>;
