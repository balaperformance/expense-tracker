/**
 * ParsedStatement → NormalizedTransaction[]. Identical for every bank: this
 * is where printed text becomes dates, amounts and directions, and where the
 * running balance is used to confirm (or work out) each row's direction.
 */
import { daysBetween, type IsoDate } from '@/lib/dates';

import { fingerprintOf } from './duplicates';
import type {
  NormalizedTransaction,
  ParsedStatement,
  StatementPeriod,
  StatementPeriodKind,
  StatementWarning,
  TransactionChannel,
  TransactionType,
} from './model';
import { cleanDescription, inferDayFirst, parseStatementAmount, parseStatementDate, parseStatementTime, toCents } from './parsing';

export type NormalizeContext = { bankAccountId: string; statementId: string };

export type NormalizedStatement = {
  transactions: NormalizedTransaction[];
  warnings: StatementWarning[];
  /** The printed period, else the span of the transactions. */
  period: StatementPeriod | null;
  periodKind: StatementPeriodKind;
};

/** What some statements print besides the figures (a payment app's note, tags, UPI ID, account) — passed through as is. */
type Extras = Pick<NormalizedTransaction, 'transactionTime' | 'notes' | 'tags' | 'upiId' | 'sourceAccount' | 'counterpartyAccount'>;

const text = (value: string | null | undefined) => (value?.trim() ? value.replace(/\s+/g, ' ').trim() : null);

/** Only the extras the row has, so a bank statement's rows look exactly as they always did. */
function extrasOf(row: ParsedStatement['rows'][number]): Extras {
  const extras: Extras = {};
  if (row.timeText !== undefined) extras.transactionTime = parseStatementTime(row.timeText);
  if (row.notes !== undefined) extras.notes = text(row.notes);
  if (row.tags !== undefined) extras.tags = row.tags.map((t) => t.trim()).filter(Boolean);
  if (row.upiId !== undefined) extras.upiId = text(row.upiId);
  if (row.sourceAccount !== undefined) extras.sourceAccount = text(row.sourceAccount);
  if (row.counterpartyAccount !== undefined) extras.counterpartyAccount = text(row.counterpartyAccount);
  return extras;
}

type Draft = {
  index: number;
  lineIndex: number;
  date: IsoDate;
  dateText: string;
  description: string;
  rawDescription: string;
  amount: number;
  type: TransactionType | null;
  balance: number | null;
  reference: string | null;
  counterparty: string | null;
  channel: TransactionChannel | null;
  issues: string[];
  confidence: number;
  extras: Extras;
};

const NUMERIC_DATE = /^(\d{1,2})[/.-](\d{1,2})[/.-]\d{2,4}$/;

function signedBalance(text: string | null | undefined): number | null {
  const parsed = parseStatementAmount(text);
  if (!parsed) return null;
  // An overdrawn balance is printed negative or marked Dr.
  return parsed.negative || parsed.marker === 'debit' ? -parsed.value : parsed.value;
}

export function periodKindOf(period: StatementPeriod | null): StatementPeriodKind {
  if (!period) return 'custom';
  const days = daysBetween(period.from, period.to) + 1;
  if (days >= 6 && days <= 8) return 'weekly';
  if (days >= 13 && days <= 16) return 'fortnightly';
  if (days >= 28 && days <= 31) return 'monthly';
  return 'custom';
}

export function normalizeStatement(parsed: ParsedStatement, ctx: NormalizeContext): NormalizedStatement {
  const warnings: StatementWarning[] = [...parsed.warnings];
  const detected = parsed.dayFirst ?? inferDayFirst(parsed.rows.map((r) => r.dateText));
  const dayFirst = detected ?? true;
  const drafts: Draft[] = [];

  parsed.rows.forEach((row, index) => {
    const date = parseStatementDate(row.dateText, dayFirst);
    if (!date) {
      warnings.push({ lineIndex: row.lineIndex, code: 'unparseableDate', message: `Unreadable date "${row.dateText}"` });
      return;
    }

    const debit = parseStatementAmount(row.debitText);
    const credit = parseStatementAmount(row.creditText);
    const single = parseStatementAmount(row.amountText);
    let amount: number | null = null;
    let type: TransactionType | null = null;
    const issues: string[] = [];
    let confidence = 1;

    if (debit && debit.value > 0 && !(credit && credit.value > 0)) {
      amount = debit.value;
      type = 'debit';
    } else if (credit && credit.value > 0 && !(debit && debit.value > 0)) {
      amount = credit.value;
      type = 'credit';
    } else if (single && single.value > 0) {
      amount = single.value;
      type = row.directionHint ?? single.marker ?? (single.negative ? 'debit' : null);
    }

    if (amount == null || amount <= 0) {
      warnings.push({ lineIndex: row.lineIndex, code: 'unparseableAmount', message: `No usable amount on the line dated ${row.dateText}` });
      return;
    }

    const rawDescription = row.description.trim();
    const description = cleanDescription(rawDescription);
    if (!description) {
      issues.push('No description on the statement');
      confidence -= 0.1;
    }

    const numeric = NUMERIC_DATE.exec(row.dateText.trim());
    if (detected == null && numeric && numeric[1] !== numeric[2]) {
      issues.push('Day and month could be read either way');
      confidence -= 0.1;
    }

    drafts.push({
      index,
      lineIndex: row.lineIndex,
      date,
      dateText: row.dateText,
      description,
      rawDescription,
      amount,
      type,
      balance: signedBalance(row.balanceText),
      reference: row.reference?.trim() ? row.reference.trim() : null,
      counterparty: row.counterparty?.trim() ? cleanDescription(row.counterparty) : null,
      channel: row.channel ?? null,
      issues,
      confidence,
      extras: extrasOf(row),
    });
  });

  // Newest-first statements are walked oldest-first, so each balance follows the one before it.
  const first = drafts[0];
  const lastDraft = drafts[drafts.length - 1];
  const chronological = first && lastDraft && first.date > lastDraft.date ? [...drafts].reverse() : drafts;

  let previous: number | null = parsed.openingBalance;
  for (const draft of chronological) {
    if (draft.type == null && draft.balance != null && previous != null) {
      const delta = draft.balance - previous;
      if (Math.abs(toCents(Math.abs(delta)) - toCents(draft.amount)) <= 1) {
        draft.type = delta > 0 ? 'credit' : 'debit';
        draft.issues.push('Debit or credit worked out from the balance');
        draft.confidence -= 0.15;
      }
    }
    if (draft.type == null) {
      draft.type = 'debit';
      draft.issues.push('Could not tell whether money went out or came in');
      draft.confidence -= 0.5;
      warnings.push({ lineIndex: draft.lineIndex, code: 'unknownDirection', message: `Direction unclear for ${draft.dateText}` });
    }
    const expected = previous == null ? null : previous + (draft.type === 'credit' ? draft.amount : -draft.amount);
    if (draft.balance != null && expected != null && Math.abs(toCents(draft.balance) - toCents(expected)) > 1) {
      draft.issues.push('The running balance does not add up here');
      draft.confidence -= 0.25;
      warnings.push({ lineIndex: draft.lineIndex, code: 'balanceMismatch', message: `Balance mismatch on ${draft.dateText}` });
    }
    previous = draft.balance ?? expected;
  }

  const transactions: NormalizedTransaction[] = chronological.map((draft) => {
    const type = draft.type ?? 'debit';
    const description = draft.description || (type === 'credit' ? 'Deposit' : 'Withdrawal');
    const base = {
      transactionDate: draft.date,
      amount: draft.amount,
      transactionType: type,
      rawDescription: draft.rawDescription,
      bankAccountId: ctx.bankAccountId,
    };
    return {
      ...base,
      id: `${ctx.statementId}:${draft.index}`,
      description,
      balance: draft.balance,
      kind: type === 'credit' ? 'income' : 'expense',
      category: null,
      categorySource: 'none',
      categoryReason: null,
      sourceStatementId: ctx.statementId,
      reference: draft.reference,
      counterparty: draft.counterparty,
      channel: draft.channel,
      confidence: Math.max(0, Math.round(draft.confidence * 100) / 100),
      issues: draft.issues,
      fingerprint: fingerprintOf(base),
      duplicate: null,
      ...draft.extras,
    };
  });

  const dates = transactions.map((t) => t.transactionDate).sort();
  const span = dates.length ? { from: dates[0] ?? '', to: dates[dates.length - 1] ?? '' } : null;
  const period = parsed.period ?? span;
  return { transactions, warnings, period, periodKind: periodKindOf(period) };
}
