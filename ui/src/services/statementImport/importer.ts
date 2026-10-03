/**
 * The only place a statement import touches the database — and only after
 * the user confirms. It reuses the app's own write paths, so every imported
 * row is exactly what adding it by hand would have produced (expense or
 * income row, its ledger movement, row-level security, the user_id filter).
 * A row with a treatment (a transfer to one of your accounts, money lent, a
 * repayment) is saved with `record_bank_movement`, which writes the movement
 * and its link or claim in one transaction.
 */
import { addDays, type IsoDate } from '@/lib/dates';
import { AppError, errorMessage } from '@/lib/errors';
import { NEARBY_DAYS } from '@/domain/statementImport/duplicates';
import {
  countOperations,
  withoutNewlyRecorded,
  type ImportOperation,
  type ImportPlan,
  type PlanCounts,
  type SkippedItem,
} from '@/domain/statementImport/importPlan';
import type { ExistingMovement } from '@/domain/statementImport/model';
import type { ReviewItem } from '@/domain/statementImport/review';
import { findTransferMatches, isPlainMovement, TRANSFER_MATCH_DAYS, treatmentPayload } from '@/domain/treatment';
import type { LedgerEntry } from '@/domain/models';

import type { TagKind } from '@/domain/tags';

import { capabilities, phase2Ready, resolveCapabilities } from '../capabilities';
import { createExpense } from '../expenses';
import { createIncome } from '../income';
import { fetchForAccount, recordCardPayment, recordMovement, recordTransferPair, setMovementDetails } from '../ledger';
import { recordBankMovement } from '../receivables';
import { documentsOfEntry, setTags } from '../tags';

/** How long the ledger read for duplicate checking may take. */
const CHECK_TIMEOUT_MS = 15_000;

/**
 * What is already recorded for the account around [from, to] — every
 * expense, income, manual movement and transfer leg, since all of them are
 * ledger rows. Widened by the nearby window on both sides.
 */
export async function fetchExistingMovements(userId: string, accountId: string, from: IsoDate, to: IsoDate): Promise<ExistingMovement[]> {
  const request = fetchForAccount({
    userId,
    accountId,
    from: addDays(from, -NEARBY_DAYS),
    toExclusive: addDays(to, NEARBY_DAYS + 1),
  });
  // A stalled connection must not leave the screen on "Checking…": give up and let the user retry.
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new AppError('The duplicate check timed out. Check your connection and try again.')), CHECK_TIMEOUT_MS);
  });
  const entries = await Promise.race([request, timeout]).finally(() => clearTimeout(timer));
  return entries.map((entry) => ({
    accountId: entry.accountId,
    date: entry.txnDate,
    amount: entry.amount,
    direction: entry.direction,
    description: entry.description,
    creditCardId: entry.creditCardId,
    reference: entry.reference ?? null,
    upiId: entry.upiId ?? null,
  }));
}

/** Every account's recorded movements around [from, to], for the accounts a session's rows are on. */
export async function fetchExistingForAccounts(userId: string, accountIds: Iterable<string>, from: IsoDate, to: IsoDate): Promise<ExistingMovement[]> {
  const ids = [...new Set(accountIds)].filter(Boolean);
  const lists = await Promise.all(ids.map((id) => fetchExistingMovements(userId, id, from, to)));
  return lists.flat();
}

export type ImportFailure = { itemId: string; message: string };

export type ImportResult = {
  imported: PlanCounts;
  skipped: SkippedItem[];
  failed: ImportFailure[];
  /** Operations not attempted because writes kept failing (e.g. the connection dropped). */
  notAttempted: number;
  /** Rows that were saved, but whose tags or statement details (UPI reference, UPI ID) could not be. */
  partial: number;
};

/** After this many failures in a row the problem is not the data; stop rather than fail every row. */
const MAX_CONSECUTIVE_FAILURES = 3;

/**
 * For transfers whose other leg was left to the import: a plain row on the
 * other account with the opposite direction and the same amount within a few
 * days — the same movement, already there from that account's statement — is
 * linked instead of adding a second one. Only a single, unclaimed match is
 * used; expense or income rows are only ever linked when the user chose them.
 */
async function autoMatches(userId: string, operations: readonly ImportOperation[]): Promise<Map<string, string>> {
  const wanted = operations.filter(
    (op): op is Extract<ImportOperation, { type: 'treatment' }> =>
      op.type === 'treatment' && op.autoMatch === true && op.request.transferTarget?.type === 'account',
  );
  const byAccount = new Map<string, IsoDate[]>();
  for (const op of wanted) {
    const target = op.request.transferTarget;
    if (target?.type !== 'account') continue;
    byAccount.set(target.accountId, [...(byAccount.get(target.accountId) ?? []), op.date]);
  }
  const entries = new Map<string, LedgerEntry[]>();
  for (const [accountId, dates] of byAccount) {
    const sorted = [...dates].sort();
    entries.set(
      accountId,
      await fetchForAccount({
        userId,
        accountId,
        from: addDays(sorted[0] ?? '', -TRANSFER_MATCH_DAYS),
        toExclusive: addDays(sorted[sorted.length - 1] ?? '', TRANSFER_MATCH_DAYS + 1),
      }),
    );
  }
  const claimed = new Set<string>();
  const result = new Map<string, string>();
  for (const op of wanted) {
    const target = op.request.transferTarget;
    if (target?.type !== 'account') continue;
    const matches = findTransferMatches(entries.get(target.accountId) ?? [], { direction: op.direction, amount: op.amount, date: op.date }).filter(
      (e) => isPlainMovement(e) && !claimed.has(e.id),
    );
    const [only] = matches;
    if (matches.length === 1 && only) {
      claimed.add(only.id);
      result.set(op.itemId, only.id);
    }
  }
  return result;
}

/**
 * Tags are their own write, after the row they belong to: a failure leaves the
 * row saved (it is reported, not retried, so nothing is written twice).
 */
async function withTags(kind: TagKind, documentId: string | null, tags: readonly string[] | undefined): Promise<boolean> {
  if (!tags?.length) return true;
  if (!documentId || !capabilities().tags) return false;
  try {
    await setTags(kind, documentId, tags);
    return true;
  } catch {
    return false;
  }
}

type Written = { id: string | null; complete: boolean };

/** Writes one operation; returns the saved movement's id when there is one to refer back to. */
async function write(userId: string, op: ImportOperation, saved: ReadonlyMap<string, string>, matches: ReadonlyMap<string, string>): Promise<Written> {
  switch (op.type) {
    case 'expense': {
      const expense = await createExpense(
        userId,
        {
          amount: op.amount,
          expenseDate: op.date,
          categoryId: op.categoryId,
          paymentMethodId: op.paymentMethodId,
          bankAccountId: op.bankAccountId,
          creditCardId: null,
          merchant: op.merchant,
          description: op.description,
          notes: op.notes,
        },
        { details: op.details },
      );
      return { id: null, complete: await withTags('expense', expense.id, op.tags) };
    }
    case 'income': {
      const income = await createIncome(
        userId,
        {
          amount: op.amount,
          incomeDate: op.date,
          source: op.source,
          description: op.description,
          bankAccountId: op.bankAccountId,
        },
        { details: op.details },
      );
      return { id: null, complete: await withTags('income', income.id, op.tags) };
    }
    case 'movement':
      if (op.creditCardId) {
        // One bank debit that is also the card's payment — the same row both sides read.
        await recordCardPayment({
          userId,
          accountId: op.bankAccountId,
          cardId: op.creditCardId,
          amount: op.amount,
          date: op.date,
          description: op.description,
          details: op.details,
        });
        return { id: null, complete: true };
      }
      await recordMovement({
        userId,
        accountId: op.bankAccountId,
        direction: op.direction,
        amount: op.amount,
        date: op.date,
        description: op.description,
        details: op.details,
      });
      return { id: null, complete: true };
    case 'transfer':
      await recordTransferPair({
        userId,
        accountId: op.bankAccountId,
        counterpartyAccountId: op.counterpartyAccountId,
        direction: op.direction,
        amount: op.amount,
        date: op.date,
        description: op.description,
        counterpartDescription: op.counterpartDescription,
        details: op.details,
      });
      return { id: null, complete: true };
    case 'treatment': {
      let request = op.request;
      if (op.settlesItemId) {
        const entryId = saved.get(op.settlesItemId);
        if (!entryId) throw new AppError('What this pays back could not be saved, so it was left out.');
        request = { ...request, settles: { entryId } };
      }
      const match = matches.get(op.itemId);
      if (match) request = { ...request, matchEntryId: match };
      const entryId = await recordBankMovement({
        accountId: op.bankAccountId,
        direction: op.direction,
        amount: op.amount,
        date: op.date,
        description: op.description,
        treatment: treatmentPayload(request),
      });
      // The database function saves the movement and its treatment; the statement's details follow it.
      let complete = true;
      if (op.details) {
        try {
          await setMovementDetails(userId, entryId, op.details);
        } catch {
          complete = false;
        }
      }
      if (op.tags?.length) {
        const linked = await documentsOfEntry(userId, entryId).catch(() => null);
        complete = (await withTags('expense', linked?.expenseId ?? null, op.tags)) && complete;
      }
      return { id: entryId, complete };
    }
  }
}

function count(counts: PlanCounts, op: ImportOperation): void {
  const one = countOperations([op]);
  for (const key of Object.keys(counts) as (keyof PlanCounts)[]) counts[key] += one[key];
}

export async function executeImport(
  userId: string,
  {
    plan,
    items,
    onProgress,
  }: { plan: ImportPlan; items: readonly ReviewItem[]; onProgress?: (done: number, total: number) => void },
): Promise<ImportResult> {
  // The import links every row to an account, which needs the Phase 2 schema.
  const caps = await resolveCapabilities();
  if (!phase2Ready(caps)) {
    throw new AppError('Statement import needs bank accounts. Run the Phase 2 migrations, then try again.');
  }
  if (plan.operations.some((op) => op.type === 'transfer') && !capabilities().transfers) {
    throw new AppError('Transfers between accounts need the 003 migration. Run supabase/003_phase2_transfers.sql, then try again.');
  }
  if (plan.operations.some((op) => op.type === 'treatment') && !capabilities().treatments) {
    throw new AppError('Transfers between accounts, loans and reimbursements need the 005 migration. Run ui/supabase/005_transaction_treatments.sql, then try again.');
  }

  // Re-check against the ledger as it is now, not as it was when review began.
  const byAccount = new Map<string, IsoDate[]>();
  for (const op of plan.operations) byAccount.set(op.bankAccountId, [...(byAccount.get(op.bankAccountId) ?? []), op.date]);
  const fresh: ExistingMovement[] = [];
  for (const [accountId, dates] of byAccount) {
    const sorted = [...dates].sort();
    fresh.push(...(await fetchExistingMovements(userId, accountId, sorted[0] ?? '', sorted[sorted.length - 1] ?? '')));
  }
  const finalPlan = withoutNewlyRecorded(plan, items, fresh);
  const matches = await autoMatches(userId, finalPlan.operations);

  const result: ImportResult = {
    imported: { expenses: 0, paidFor: 0, income: 0, movements: 0, transfers: 0, lent: 0, repaid: 0 },
    skipped: finalPlan.skipped,
    failed: [],
    notAttempted: 0,
    partial: 0,
  };
  const saved = new Map<string, string>();
  let consecutive = 0;
  const total = finalPlan.operations.length;
  for (const [index, op] of finalPlan.operations.entries()) {
    if (consecutive >= MAX_CONSECUTIVE_FAILURES) {
      result.notAttempted = total - index;
      break;
    }
    try {
      const { id, complete } = await write(userId, op, saved, matches);
      if (id) saved.set(op.itemId, id);
      if (!complete) result.partial += 1;
      consecutive = 0;
      count(result.imported, op);
    } catch (error) {
      // A row that pays back another row of this import fails on its own, not the connection.
      if (!(op.type === 'treatment' && op.settlesItemId && !saved.has(op.settlesItemId))) consecutive += 1;
      result.failed.push({ itemId: op.itemId, message: errorMessage(error, 'Could not save this row.') });
    }
    onProgress?.(index + 1, total);
  }
  return result;
}
