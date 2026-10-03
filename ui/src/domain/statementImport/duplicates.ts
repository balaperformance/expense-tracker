/**
 * Duplicate protection.
 *
 * Fingerprint — deterministic, readable, portable:
 *   account | date | amount in cents | debit/credit | normalised description
 *
 * The checks, strongest first:
 *
 * 1. Overlapping statements in one session (weekly inside fortnightly inside
 *    monthly). The same real row appears once in every statement that covers
 *    its date, so rows are matched by fingerprint *and occurrence*: the second
 *    ₹20 tea on the 5th is only a duplicate if an earlier statement also had a
 *    second one. Two genuine identical purchases are never collapsed.
 *    A payment app's statement (Paytm) and a bank's own statement word the
 *    same payment differently, so between those two the match is by account,
 *    amount, direction and day — or by the payment's reference.
 *
 * 2. Already recorded. Every bank-linked expense, income, manual movement and
 *    transfer is a row in the ledger, and the ledger stores exactly the
 *    account, date, amount and direction a statement prints. A row with a
 *    reference (a UPI reference number) recorded on the same account, amount
 *    and direction is the same payment whatever the date or wording — that is
 *    checked first. Otherwise rows are matched one-to-one by that shape (a
 *    multiset match, so counts are respected); where the descriptions also
 *    agree the match is 'exact', else 'likely' — the user may have typed
 *    "Swiggy" for "UPI/DR/…/SWIGGY".
 *
 * 3. Nearby — same amount and direction within a couple of days (a card
 *    payment posted a day later). Advisory only: flagged, never deselected.
 */
import { daysBetween, type IsoDate } from '@/lib/dates';

import type { DuplicateMatch, ExistingMovement, NormalizedTransaction, TransactionType } from './model';
import { normalizeDescription, toCents } from './parsing';

export const NEARBY_DAYS = 2;

export function shapeKey(accountId: string, date: IsoDate, amount: number, type: TransactionType): string {
  return `${accountId}|${date}|${toCents(amount)}|${type}`;
}

export function fingerprintOf(t: {
  bankAccountId: string;
  transactionDate: IsoDate;
  amount: number;
  transactionType: TransactionType;
  rawDescription: string;
}): string {
  return `${shapeKey(t.bankAccountId, t.transactionDate, t.amount, t.transactionType)}|${normalizeDescription(t.rawDescription)}`;
}

/**
 * A reference reduced to what identifies it: letters and digits, upper case,
 * leading zeros dropped (a bank may pad a 12-digit UPI reference to 16).
 * Null when too short, or all zeros, to identify anything.
 */
export function referenceKey(reference: string | null | undefined): string | null {
  const key = (reference ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '').replace(/^0+/, '');
  return key.length >= 6 ? key : null;
}

/**
 * A UPI reference number, known to be one: 12 digits printed by a UPI
 * statement (the row names a UPI ID). Unique to one payment across every bank
 * and app, so two different ones are two different payments.
 */
function upiReference(reference: string | null | undefined, upiId: string | null | undefined): string | null {
  const key = referenceKey(reference);
  return upiId?.trim() && key && /^\d{12}$/.test(key) ? key : null;
}

/** Two rows whose UPI reference numbers prove they are different payments. */
function provenDifferent(t: Pick<NormalizedTransaction, 'reference' | 'upiId'>, m: Pick<ExistingMovement, 'reference' | 'upiId'>): boolean {
  const a = upiReference(t.reference, t.upiId);
  const b = upiReference(m.reference, m.upiId);
  return a != null && b != null && a !== b;
}

/** Duplicates that should not be imported unless the user insists. */
export const isBlockingDuplicate = (match: DuplicateMatch | null) => match != null && match.type !== 'nearby';

/** The same payment in a payment app's statement and a bank's: same account, amount, direction — and day, or reference. */
function samePaymentAcrossSources(t: NormalizedTransaction, other: NormalizedTransaction): boolean {
  if (!t.bankAccountId || t.bankAccountId !== other.bankAccountId) return false;
  if (t.transactionType !== other.transactionType || toCents(t.amount) !== toCents(other.amount)) return false;
  if (provenDifferent(t, other)) return false;
  const a = referenceKey(t.reference);
  return t.transactionDate === other.transactionDate || (a != null && a === referenceKey(other.reference));
}

/**
 * Marks each transaction's duplicate status. [transactions] are in upload
 * order — statement by statement — so the first statement to contain a row
 * owns it. Returns new objects; the input is not modified.
 */
export function markDuplicates(
  transactions: readonly NormalizedTransaction[],
  existing: readonly ExistingMovement[],
  nearbyDays = NEARBY_DAYS,
): NormalizedTransaction[] {
  const result = transactions.map((t) => ({ ...t, duplicate: null as DuplicateMatch | null }));

  // 1. Overlap between statements of this session.
  const owners = new Map<string, { id: string; statement: string }>();
  const occurrences = new Map<string, number>();
  for (const t of result) {
    const perStatement = `${t.sourceStatementId}#${t.fingerprint}`;
    const n = (occurrences.get(perStatement) ?? 0) + 1;
    occurrences.set(perStatement, n);
    const key = `${t.fingerprint}#${n}`;
    const owner = owners.get(key);
    if (owner && owner.statement !== t.sourceStatementId) t.duplicate = { type: 'overlap', ofId: owner.id };
    else if (!owner) owners.set(key, { id: t.id, statement: t.sourceStatementId });
  }

  // 1b. A payment app's row and a bank's row for the same payment (different wording, so
  // different fingerprints). Only between a multi-account statement and another statement,
  // so bank-only sessions are matched exactly as before. One row explains at most one other.
  if (result.some((t) => t.sourceAccount != null)) {
    const claimed = new Set<string>();
    result.forEach((t, index) => {
      if (t.duplicate) return;
      const owner = result.slice(0, index).find(
        (o) =>
          o.sourceStatementId !== t.sourceStatementId &&
          o.duplicate == null &&
          !claimed.has(o.id) &&
          (o.sourceAccount != null) !== (t.sourceAccount != null) &&
          samePaymentAcrossSources(t, o),
      );
      if (!owner) return;
      claimed.add(owner.id);
      t.duplicate = { type: 'overlap', ofId: owner.id };
    });
  }

  // 2. Already in the ledger — one existing row can explain at most one incoming row.
  const all = existing.map((movement) => ({ movement, used: false }));
  const pool = new Map<string, { movement: ExistingMovement; used: boolean }[]>();
  for (const entry of all) {
    const key = shapeKey(entry.movement.accountId, entry.movement.date, entry.movement.amount, entry.movement.direction);
    const list = pool.get(key) ?? [];
    list.push(entry);
    pool.set(key, list);
  }
  const fresh = result.filter((t) => t.duplicate == null);
  const label = (m: ExistingMovement) => m.description?.trim() || (m.direction === 'credit' ? 'a credit' : 'a debit');

  // 2a. The same reference already recorded: the same payment, on whatever date it was recorded.
  for (const t of fresh) {
    const key = referenceKey(t.reference);
    if (!key || !t.bankAccountId) continue;
    const cents = toCents(t.amount);
    const hit = all.find(
      (c) =>
        !c.used &&
        c.movement.accountId === t.bankAccountId &&
        c.movement.direction === t.transactionType &&
        toCents(c.movement.amount) === cents &&
        referenceKey(c.movement.reference) === key,
    );
    if (!hit) continue;
    hit.used = true;
    t.duplicate = { type: 'existing', strength: 'exact', existingLabel: label(hit.movement), sameReference: true, existingDate: hit.movement.date };
  }

  for (const pass of ['exact', 'likely'] as const) {
    for (const t of fresh) {
      if (t.duplicate) continue;
      const candidates = pool.get(shapeKey(t.bankAccountId, t.transactionDate, t.amount, t.transactionType));
      // A recorded row may carry the full narration, the cleaned description or just the payee
      // (an imported expense's ledger row is labelled with its merchant).
      const wanted = new Set([t.rawDescription, t.description, t.counterparty].map(normalizeDescription).filter(Boolean));
      const hit = candidates?.find(
        (c) => !c.used && !provenDifferent(t, c.movement) && (pass === 'likely' || wanted.has(normalizeDescription(c.movement.description))),
      );
      if (!hit) continue;
      hit.used = true;
      t.duplicate = { type: 'existing', strength: pass, existingLabel: label(hit.movement) };
    }
  }

  // 3. Nearby dates — only existing rows no exact-date match has claimed.
  const leftovers = all.filter((c) => !c.used);
  for (const t of fresh) {
    if (t.duplicate) continue;
    const cents = toCents(t.amount);
    const hit = leftovers.find(
      (c) =>
        !c.used &&
        c.movement.accountId === t.bankAccountId &&
        c.movement.direction === t.transactionType &&
        toCents(c.movement.amount) === cents &&
        !provenDifferent(t, c.movement) &&
        Math.abs(daysBetween(c.movement.date, t.transactionDate)) <= nearbyDays,
    );
    if (!hit) continue;
    hit.used = true;
    // A card bill recorded by hand is often posted by the bank a day or two
    // later. Bill payments are not routine repeats, so this one blocks: importing
    // it would take the money out of the account — and pay the card — twice.
    t.duplicate =
      hit.movement.creditCardId != null && t.transactionType === 'debit'
        ? { type: 'existing', strength: 'likely', existingLabel: label(hit.movement) }
        : { type: 'nearby', existingLabel: label(hit.movement), existingDate: hit.movement.date };
  }

  return result;
}
