/**
 * Write hooks. Every successful write marks the affected figures stale, the
 * way the Flutter screens call invalidate() on the dashboard, budgets and
 * reports after a save.
 */
import { useMutation, useQueryClient } from '@tanstack/react-query';

import {
  cardPaymentDescription,
  cardPaymentProblemMessage,
  checkCardPayment,
  type CardEntry,
  type CardPaymentDraft,
} from '@/domain/creditCards';
import type { BankAccount, CreditCard, Expense, Income } from '@/domain/models';
import type { TagKind } from '@/domain/tags';
import { checkTransfer, transferProblemMessage, type TransferDraft } from '@/domain/transfer';
import { treatmentPayload, type TreatmentRequest } from '@/domain/treatment';
import { AppError, errorMessage } from '@/lib/errors';
import { formatCurrency } from '@/lib/format';
import { createAccount, deleteAccount, updateAccount, type AccountDraft } from '@/services/accounts';
import { copyBudgetsFromPreviousMonth, deleteBudget, setBudget } from '@/services/budgets';
import { capabilities } from '@/services/capabilities';
import {
  createCategory,
  createPaymentMethod,
  deleteCategory,
  deletePaymentMethod,
  updateCategory,
  type CategoryDraft,
} from '@/services/catalog';
import {
  createCard,
  deleteCard,
  deleteCardTransaction,
  recordCardTransaction,
  updateCard,
  type CardDraft,
} from '@/services/creditCards';
import { createExpense, deleteExpense, updateExpense, type ExpenseDraft } from '@/services/expenses';
import { createIncome, deleteIncome, updateIncome, type IncomeDraft } from '@/services/income';
import { deleteEntry, deleteTransfer, linkToCard, netFor, recordCardPayment, recordMovement, transfer } from '@/services/ledger';
import { applyTreatment, setExpensePaidFor } from '@/services/receivables';
import { documentsOfEntry, setTags } from '@/services/tags';
import { useUserId } from '@/state/auth';
import { invalidateFinance, keys } from '@/state/queryClient';

function useFinanceMutation<TArgs, TResult>(fn: (userId: string, args: TArgs) => Promise<TResult>, extraKeys?: (userId: string) => readonly unknown[][]) {
  const userId = useUserId();
  const client = useQueryClient();
  return useMutation({
    mutationFn: (args: TArgs) => fn(userId, args),
    onSuccess: async () => {
      await Promise.all([
        invalidateFinance(client),
        ...(extraKeys?.(userId) ?? []).map((queryKey) => client.invalidateQueries({ queryKey })),
      ]);
    },
  });
}

// ---- Expenses & income ----------------------------------------------------

/** What "Paid for someone else" says on save: who, or null to clear it; undefined leaves it alone. */
export type PaidForDraft = { person: string; dueDate: string | null; note: string | null } | null | undefined;

/**
 * Sets a transaction's tags once it is saved. They are their own write: if it
 * fails the transaction is still saved, so the failure is reported back
 * instead of thrown — throwing would invite a second save of the same expense.
 * `undefined` leaves the tags as they are.
 */
async function saveTags(kind: TagKind, id: string, tags: readonly string[] | undefined): Promise<string | null> {
  if (tags === undefined || !capabilities().tags) return null;
  try {
    await setTags(kind, id, tags);
    return null;
  } catch (failure) {
    return errorMessage(failure, 'Could not save the tags.');
  }
}

/** A saved transaction and, when its tags could not be saved, why. */
export type SaveResult<T> = { saved: T; tagError: string | null };

export const useSaveExpense = () =>
  useFinanceMutation(
    async (
      userId,
      { id, draft, paidFor, tags }: { id?: string; draft: ExpenseDraft; paidFor?: PaidForDraft; tags?: readonly string[] },
    ): Promise<SaveResult<Expense>> => {
      const saved = id ? await updateExpense(userId, id, draft) : await createExpense(userId, draft);
      // One statement on its own: if it fails the expense is still saved, as the user's own spending.
      if (paidFor !== undefined && capabilities().treatments) await setExpensePaidFor(userId, saved.id, paidFor);
      return { saved, tagError: await saveTags('expense', saved.id, tags) };
    },
  );

export const useDeleteExpense = () => useFinanceMutation((userId, id: string) => deleteExpense(userId, id));

export const useSaveIncome = () =>
  useFinanceMutation(
    async (userId, { id, draft, tags }: { id?: string; draft: IncomeDraft; tags?: readonly string[] }): Promise<SaveResult<Income>> => {
      const saved = id ? await updateIncome(userId, id, draft) : await createIncome(userId, draft);
      return { saved, tagError: await saveTags('income', saved.id, tags) };
    },
  );

export const useDeleteIncome = () => useFinanceMutation((userId, id: string) => deleteIncome(userId, id));

// ---- Accounts & ledger ------------------------------------------------------

export const useSaveAccount = () =>
  useFinanceMutation((userId, { id, draft }: { id?: string; draft: AccountDraft }) =>
    id ? updateAccount(userId, id, draft) : createAccount(userId, draft),
  );

export const useDeleteAccount = () => useFinanceMutation((userId, id: string) => deleteAccount(userId, id));

export const useRecordMovement = () =>
  useFinanceMutation(
    (
      userId,
      args: { accountId: string; direction: 'debit' | 'credit'; amount: number; date: string; description: string | null },
    ) => recordMovement({ userId, ...args }),
  );

export const useDeleteLedgerEntry = () =>
  useFinanceMutation((userId, entry: { id: string; transferGroupId: string | null }) =>
    entry.transferGroupId ? deleteTransfer(userId, entry.transferGroupId) : deleteEntry(userId, entry.id),
  );

/**
 * Moves money between two of the user's accounts. The sufficient-funds check
 * is made against a balance re-derived from the ledger a moment before the
 * write — not the figure on screen, which may predate an expense recorded
 * since — and compared in whole cents.
 */
export const useTransfer = () =>
  useFinanceMutation(
    async (userId, { draft, accounts, currency }: { draft: TransferDraft; accounts: readonly BankAccount[]; currency: string }) => {
      if (!capabilities().transfers) {
        throw new AppError('Transfers need the 003 migration. Run supabase/003_phase2_transfers.sql, then try again.');
      }
      // Shape rules first: they need no round trip.
      const shape = checkTransfer(draft, null);
      if (shape) throw new AppError(transferProblemMessage(shape));
      const from = accounts.find((a) => a.id === draft.fromAccountId);
      const to = accounts.find((a) => a.id === draft.toAccountId);
      if (!from) throw new AppError(transferProblemMessage('noSource'));
      if (!to) throw new AppError(transferProblemMessage('noDestination'));

      const available = from.openingBalance + (await netFor(userId, from.id));
      const problem = checkTransfer(draft, available);
      if (problem) {
        throw new AppError(
          transferProblemMessage(problem, { sourceLabel: from.nickname, availableText: formatCurrency(available, currency) }),
        );
      }
      return transfer({
        userId,
        fromAccountId: from.id,
        toAccountId: to.id,
        fromLabel: from.nickname,
        toLabel: to.nickname,
        amount: draft.amount ?? 0,
        date: draft.date,
        note: draft.note?.trim() ? draft.note.trim() : null,
      });
    },
  );

// ---- Credit cards -----------------------------------------------------------

export const useSaveCard = () =>
  useFinanceMutation((userId, { id, draft }: { id?: string; draft: CardDraft }) =>
    id ? updateCard(userId, id, draft) : createCard(userId, draft),
  );

export const useDeleteCard = () => useFinanceMutation((userId, id: string) => deleteCard(userId, id));

export const useRecordCardTransaction = () =>
  useFinanceMutation((userId, args: Omit<Parameters<typeof recordCardTransaction>[0], 'userId'>) =>
    recordCardTransaction({ userId, ...args }),
  );

/** Removes a card movement from the table it lives in. A purchase is an expense and is deleted there. */
export const useDeleteCardEntry = () =>
  useFinanceMutation(async (userId, entry: CardEntry) => {
    if (entry.source === 'card') return deleteCardTransaction(userId, entry.id);
    if (entry.source === 'account') return deleteEntry(userId, entry.id);
    throw new AppError('This purchase is an expense. Open it to edit or delete it.');
  });

/** Recognises an existing bank debit as a card's bill payment (or, with null, undoes that). */
export const useLinkToCard = () =>
  useFinanceMutation((userId, { entryId, cardId }: { entryId: string; cardId: string | null }) => linkToCard(userId, entryId, cardId));

/**
 * Changes how a saved bank movement is recorded — expense, income, transfer,
 * money lent, repayment… Every write it takes (removing an expense, adding
 * the other transfer leg, creating a claim) happens in one database
 * transaction, so a failure leaves the movement exactly as it was.
 */
export const useApplyTreatment = () =>
  useFinanceMutation(
    async (
      userId,
      { entryId, request, tags }: { entryId: string; request: TreatmentRequest; tags?: { kind: TagKind; names: readonly string[] } },
    ): Promise<{ tagError: string | null }> => {
      if (!capabilities().treatments) {
        throw new AppError('This needs the 005 migration. Run ui/supabase/005_transaction_treatments.sql, then try again.');
      }
      await applyTreatment(entryId, treatmentPayload(request));
      if (!tags || !capabilities().tags) return { tagError: null };
      // The treatment may have just created the expense or income row: read which it is linked to now.
      const linked = await documentsOfEntry(userId, entryId).catch(() => null);
      const documentId = tags.kind === 'expense' ? linked?.expenseId : linked?.incomeId;
      if (!documentId) return { tagError: 'Could not save the tags.' };
      return { tagError: await saveTags(tags.kind, documentId, tags.names) };
    },
  );

/**
 * Pays a card bill. From an account it is one debit on that account naming
 * the card, checked against a balance re-derived from the ledger a moment
 * before the write, as a transfer is. In cash it is one card transaction.
 * Either way it is never an expense.
 */
export const useCardPayment = () =>
  useFinanceMutation(
    async (
      userId,
      { draft, card, accounts, currency }: { draft: CardPaymentDraft; card: CreditCard; accounts: readonly BankAccount[]; currency: string },
    ) => {
      if (!capabilities().creditCards) {
        throw new AppError('Credit cards need the 004 migration. Run supabase/004_credit_cards.sql, then try again.');
      }
      const shape = checkCardPayment(draft, null);
      if (shape) throw new AppError(cardPaymentProblemMessage(shape));
      const amount = draft.amount ?? 0;
      const description = cardPaymentDescription(card, draft.note);
      const source = draft.source;
      if (source?.kind !== 'account') {
        return recordCardTransaction({ userId, cardId: card.id, kind: 'payment', direction: 'credit', amount, date: draft.date, description });
      }
      const account = accounts.find((a) => a.id === source.accountId);
      if (!account) throw new AppError(cardPaymentProblemMessage('noSource'));
      const available = account.openingBalance + (await netFor(userId, account.id));
      const problem = checkCardPayment(draft, available);
      if (problem) {
        throw new AppError(
          cardPaymentProblemMessage(problem, { sourceLabel: account.nickname, availableText: formatCurrency(available, currency) }),
        );
      }
      return recordCardPayment({ userId, accountId: account.id, cardId: card.id, amount, date: draft.date, description });
    },
  );

// ---- Budgets ----------------------------------------------------------------

export const useSetBudget = () =>
  useFinanceMutation((userId, args: { categoryId: string | null; month: string; amount: number }) => setBudget({ userId, ...args }));

export const useDeleteBudget = () => useFinanceMutation((userId, id: string) => deleteBudget(userId, id));

export const useCopyBudgets = () => useFinanceMutation((userId, month: string) => copyBudgetsFromPreviousMonth(userId, month));

// ---- Catalog ----------------------------------------------------------------

export const useSaveCategory = () =>
  useFinanceMutation(
    (userId, { id, draft }: { id?: string; draft: CategoryDraft }) =>
      id ? updateCategory(userId, id, draft) : createCategory(userId, draft),
    (userId) => [[...keys.categories(userId)]],
  );

export const useDeleteCategory = () =>
  useFinanceMutation((userId, id: string) => deleteCategory(userId, id), (userId) => [[...keys.categories(userId)]]);

export const useCreatePaymentMethod = () =>
  useFinanceMutation((userId, name: string) => createPaymentMethod(userId, name), (userId) => [[...keys.paymentMethods(userId)]]);

export const useDeletePaymentMethod = () =>
  useFinanceMutation((userId, id: string) => deletePaymentMethod(userId, id), (userId) => [[...keys.paymentMethods(userId)]]);
