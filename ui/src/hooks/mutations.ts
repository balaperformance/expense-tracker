/**
 * Write hooks. Every successful write marks the affected figures stale, the
 * way the Flutter screens call invalidate() on the dashboard, budgets and
 * reports after a save.
 */
import { useMutation, useQueryClient } from '@tanstack/react-query';

import type { BankAccount } from '@/domain/models';
import { checkTransfer, transferProblemMessage, type TransferDraft } from '@/domain/transfer';
import { AppError } from '@/lib/errors';
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
import { createExpense, deleteExpense, updateExpense, type ExpenseDraft } from '@/services/expenses';
import { createIncome, deleteIncome, updateIncome, type IncomeDraft } from '@/services/income';
import { deleteEntry, deleteTransfer, netFor, recordMovement, transfer } from '@/services/ledger';
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

export const useSaveExpense = () =>
  useFinanceMutation((userId, { id, draft }: { id?: string; draft: ExpenseDraft }) =>
    id ? updateExpense(userId, id, draft) : createExpense(userId, draft),
  );

export const useDeleteExpense = () => useFinanceMutation((userId, id: string) => deleteExpense(userId, id));

export const useSaveIncome = () =>
  useFinanceMutation((userId, { id, draft }: { id?: string; draft: IncomeDraft }) =>
    id ? updateIncome(userId, id, draft) : createIncome(userId, draft),
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
