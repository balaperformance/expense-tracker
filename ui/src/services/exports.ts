/**
 * Loads what one export needs and turns it into a dataset. Port of
 * `repositories/export_repository.dart` + the provider's build step.
 */
import { EXPORT_ROW_LIMIT } from '@/domain/defaults';
import {
  bankStatementDataset,
  categoryReportDataset,
  ExportContext,
  expensesDataset,
  incomeDataset,
  incomeVsExpenseDataset,
  spendingReportDataset,
} from '@/domain/export/builder';
import { rangeEndExclusive, type ExportDataset, type ExportRequest } from '@/domain/export/model';
import type { BankAccount, ExpenseCategory, PaymentMethod } from '@/domain/models';
import { buildStatement } from '@/domain/statement';
import { AppError } from '@/lib/errors';

import { fetchRange } from './expenses';
import { fetchIncomeRange } from './income';
import { fetchForAccount, netBefore } from './ledger';

export type ExportPreview = { dataset: ExportDataset; truncated: boolean };

const atCap = (rows: number) => rows >= EXPORT_ROW_LIMIT;

export async function buildExport({
  userId,
  request,
  currency,
  accounts,
  categories,
  paymentMethods,
}: {
  userId: string;
  request: ExportRequest;
  currency: string;
  accounts: readonly BankAccount[];
  categories: readonly ExpenseCategory[];
  paymentMethods: readonly PaymentMethod[];
}): Promise<ExportPreview> {
  const context = new ExportContext(currency, accounts, categories, paymentMethods);
  const { range } = request;
  const toExclusive = rangeEndExclusive(range);
  const filterNote =
    request.categoryIds.length > 0
      ? `Categories: ${request.categoryIds
          .map((id) => categories.find((c) => c.id === id)?.name)
          .filter(Boolean)
          .join(', ')}`
      : null;

  switch (request.type) {
    case 'bankStatement': {
      const account = accounts.find((a) => a.id === request.accountId);
      if (!account) throw new AppError('That account is no longer available. Choose another one.');
      const [entries, priorNet] = await Promise.all([
        fetchForAccount({ userId, accountId: account.id, from: range.start, toExclusive }),
        netBefore(userId, account.id, range.start),
      ]);
      const statement = buildStatement({ openingBalance: account.openingBalance + priorNet, entries });
      return { dataset: bankStatementDataset({ account, statement, range, context }), truncated: false };
    }
    case 'expenses':
    case 'spendingReport':
    case 'categoryReport': {
      const expenses = await fetchRange(userId, range.start, toExclusive, request.categoryIds);
      const dataset =
        request.type === 'expenses'
          ? expensesDataset({ expenses, range, context, filterNote })
          : request.type === 'spendingReport'
            ? spendingReportDataset({ expenses, categories, range, context, filterNote })
            : categoryReportDataset({ expenses, categories, range, context, filterNote });
      return { dataset, truncated: atCap(expenses.length) };
    }
    case 'income': {
      const income = await fetchIncomeRange(userId, range.start, toExclusive);
      return { dataset: incomeDataset({ income, range, context }), truncated: atCap(income.length) };
    }
    case 'incomeVsExpense': {
      const [expenses, income] = await Promise.all([
        fetchRange(userId, range.start, toExclusive),
        fetchIncomeRange(userId, range.start, toExclusive),
      ]);
      return {
        dataset: incomeVsExpenseDataset({ expenses, income, range, context }),
        truncated: atCap(expenses.length) || atCap(income.length),
      };
    }
  }
}
