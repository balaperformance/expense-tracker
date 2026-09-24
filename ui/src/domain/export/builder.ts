/**
 * Builds export datasets from domain rows. Port of
 * `services/export/export_dataset_builder.dart` — same sections, columns,
 * totals and wording.
 */
import { dayMonthYear, formatCurrency, formatPercent, monthYear } from '@/lib/format';

import { buildCategoryBreakdown, bucketByMonth, sumBy, type CategorySpend } from '../analytics';
import {
  accountLabel,
  isTransfer,
  ledgerCategoryLabel,
  ledgerTitle,
  MONEY_TRANSFER_LABEL,
  type BankAccount,
  type Expense,
  type ExpenseCategory,
  type Income,
  type LedgerEntry,
  type PaymentMethod,
} from '../models';
import { closingBalance, type AccountStatement } from '../statement';

import {
  blank,
  cell,
  col,
  countCell,
  dateCell,
  isWholeMonth,
  moneyCell,
  numCol,
  percentCell,
  rangeDayCount,
  type ExportCell,
  type ExportDataset,
  type ExportDateRange,
  type ExportSection,
} from './model';

export class ExportContext {
  private readonly accounts: Map<string, BankAccount>;
  private readonly categories: Map<string, ExpenseCategory>;
  private readonly methods: Map<string, PaymentMethod>;

  constructor(
    readonly currencyCode: string,
    accounts: readonly BankAccount[] = [],
    categories: readonly ExpenseCategory[] = [],
    paymentMethods: readonly PaymentMethod[] = [],
  ) {
    this.accounts = new Map(accounts.map((a) => [a.id, a]));
    this.categories = new Map(categories.map((c) => [c.id, c]));
    this.methods = new Map(paymentMethods.map((p) => [p.id, p]));
  }

  money = (amount: number) => formatCurrency(amount, this.currencyCode);
  date = (iso: string) => dayMonthYear(iso);
  accountName = (id: string | null) => {
    if (id == null) return 'Cash';
    const account = this.accounts.get(id);
    return account ? accountLabel(account) : 'Closed account';
  };
  categoryName = (id: string | null) => (id == null ? 'Uncategorised' : (this.categories.get(id)?.name ?? 'Uncategorised'));
  paymentMethodName = (id: string | null) => (id == null ? '' : (this.methods.get(id)?.name ?? ''));
}

const TRANSFER_NOTE =
  'Transfers between your own accounts are not income or expense, so they are excluded from these ' +
  `figures. They appear on the bank statement of each account as "${MONEY_TRANSFER_LABEL}".`;

function periodLabel(range: ExportDateRange): string {
  if (isWholeMonth(range)) return monthYear(range.start);
  return `${dayMonthYear(range.start)} – ${dayMonthYear(range.endInclusive)}`;
}

const monthLabel = (key: string) => monthYear(`${key}-01`);

function statementDescription(entry: LedgerEntry, context: ExportContext): string {
  const title = ledgerTitle(entry);
  if (!isTransfer(entry) || entry.counterpartyAccountId == null) return title;
  const name = context.accountName(entry.counterpartyAccountId);
  return entry.direction === 'debit' ? `${title} to ${name}` : `${title} from ${name}`;
}

export function bankStatementDataset({
  account,
  statement,
  range,
  context,
}: {
  account: BankAccount;
  statement: AccountStatement;
  range: ExportDateRange;
  context: ExportContext;
}): ExportDataset {
  const rows: ExportCell[][] = [...statement.rows].reverse().map(({ entry, balanceAfter }) => [
    dateCell(context.date(entry.txnDate)),
    cell(statementDescription(entry, context)),
    cell(ledgerCategoryLabel(entry) ?? ''),
    entry.direction === 'debit' ? moneyCell(context.money(entry.amount), entry.amount) : blank(),
    entry.direction === 'credit' ? moneyCell(context.money(entry.amount), entry.amount) : blank(),
    moneyCell(context.money(balanceAfter), balanceAfter),
  ]);
  const closing = closingBalance(statement);

  return {
    title: 'Bank statement',
    subtitle: `${account.bankName} — ${accountLabel(account)}`,
    periodLabel: periodLabel(range),
    summary: [
      { label: 'Opening balance', value: context.money(statement.openingBalance) },
      { label: 'Total credits', value: context.money(statement.totalCredits) },
      { label: 'Total debits', value: context.money(statement.totalDebits) },
      { label: 'Closing balance', value: context.money(closing), emphasis: true },
    ],
    sections: [
      {
        title: 'Transactions',
        note: `Balance brought forward ${context.money(statement.openingBalance)}`,
        columns: [col('Date', 1.1), col('Description', 2.6), col('Category', 1.4), numCol('Debit', 1.2), numCol('Credit', 1.2), numCol('Balance', 1.3)],
        rows,
        totalRow: [
          cell('Closing balance'),
          blank(),
          blank(),
          moneyCell(context.money(statement.totalDebits), statement.totalDebits),
          moneyCell(context.money(statement.totalCredits), statement.totalCredits),
          moneyCell(context.money(closing), closing),
        ],
        emptyMessage: 'No movements on this account in this period.',
      },
    ],
    footnote: `Balances are derived from the transaction ledger. Account opening balance ${context.money(account.openingBalance)}.`,
    generatedAt: new Date(),
  };
}

export function expensesDataset({
  expenses,
  range,
  context,
  filterNote,
}: {
  expenses: readonly Expense[];
  range: ExportDateRange;
  context: ExportContext;
  filterNote?: string | null;
}): ExportDataset {
  const ordered = [...expenses].sort((a, b) => (a.expenseDate < b.expenseDate ? -1 : a.expenseDate > b.expenseDate ? 1 : 0));
  const total = sumBy(ordered, (e) => e.amount);
  return {
    title: 'Expenses',
    subtitle: filterNote ?? null,
    periodLabel: periodLabel(range),
    summary: [
      { label: 'Total spent', value: context.money(total), emphasis: true },
      { label: 'Transactions', value: String(ordered.length) },
      { label: 'Average', value: context.money(ordered.length ? total / ordered.length : 0) },
    ],
    sections: [
      {
        title: 'Expenses',
        columns: [
          col('Date', 1.1),
          col('Category', 1.2),
          col('Merchant', 1.5),
          col('Description', 1.8),
          col('Paid from', 1.4),
          col('Payment method', 1.2),
          col('Notes', 1.5),
          numCol('Amount', 1.2),
        ],
        rows: ordered.map((e) => [
          dateCell(context.date(e.expenseDate)),
          cell(context.categoryName(e.categoryId)),
          cell(e.merchant ?? ''),
          cell(e.description ?? ''),
          cell(context.accountName(e.bankAccountId)),
          cell(context.paymentMethodName(e.paymentMethodId)),
          cell(e.notes ?? ''),
          moneyCell(context.money(e.amount), e.amount),
        ]),
        totalRow: [cell('Total'), blank(), blank(), blank(), blank(), blank(), blank(), moneyCell(context.money(total), total)],
        emptyMessage: 'No expenses in this period.',
      },
    ],
    footnote: TRANSFER_NOTE,
    generatedAt: new Date(),
  };
}

export function incomeDataset({
  income,
  range,
  context,
}: {
  income: readonly Income[];
  range: ExportDateRange;
  context: ExportContext;
}): ExportDataset {
  const ordered = [...income].sort((a, b) => (a.incomeDate < b.incomeDate ? -1 : a.incomeDate > b.incomeDate ? 1 : 0));
  const total = sumBy(ordered, (i) => i.amount);
  return {
    title: 'Income',
    periodLabel: periodLabel(range),
    summary: [
      { label: 'Total received', value: context.money(total), emphasis: true },
      { label: 'Entries', value: String(ordered.length) },
    ],
    sections: [
      {
        title: 'Income',
        columns: [col('Date', 1.1), col('Source', 1.8), col('Description', 2.2), col('Paid into', 1.5), numCol('Amount', 1.2)],
        rows: ordered.map((i) => [
          dateCell(context.date(i.incomeDate)),
          cell(i.source ?? ''),
          cell(i.description ?? ''),
          cell(i.bankAccountId == null ? 'Not tracked' : context.accountName(i.bankAccountId)),
          moneyCell(context.money(i.amount), i.amount),
        ]),
        totalRow: [cell('Total'), blank(), blank(), blank(), moneyCell(context.money(total), total)],
        emptyMessage: 'No income in this period.',
      },
    ],
    footnote: TRANSFER_NOTE,
    generatedAt: new Date(),
  };
}

function categorySection(byCategory: CategorySpend[], total: number, context: ExportContext): ExportSection {
  const count = byCategory.reduce((s, c) => s + c.transactionCount, 0);
  return {
    title: 'By category',
    columns: [col('Category', 2), numCol('Transactions'), numCol('Amount', 1.3), numCol('Share')],
    rows: byCategory.map((spend) => [
      cell(spend.name),
      countCell(spend.transactionCount),
      moneyCell(context.money(spend.total), spend.total),
      percentCell(total <= 0 ? '—' : formatPercent(spend.total / total), total <= 0 ? null : spend.total / total),
    ]),
    totalRow: [cell('Total'), countCell(count), moneyCell(context.money(total), total), percentCell(total <= 0 ? '—' : '100%', null)],
    emptyMessage: 'No spending to break down in this period.',
  };
}

function sourceSection(expenses: readonly Expense[], total: number, context: ExportContext): ExportSection {
  const totals = new Map<string | null, { amount: number; count: number }>();
  for (const e of expenses) {
    const bucket = totals.get(e.bankAccountId) ?? { amount: 0, count: 0 };
    bucket.amount += e.amount;
    bucket.count += 1;
    totals.set(e.bankAccountId, bucket);
  }
  const ordered = [...totals.entries()].sort((a, b) => b[1].amount - a[1].amount);
  return {
    title: 'By payment source',
    columns: [col('Source', 2), numCol('Transactions'), numCol('Amount', 1.3), numCol('Share')],
    rows: ordered.map(([id, { amount, count }]) => [
      cell(context.accountName(id)),
      countCell(count),
      moneyCell(context.money(amount), amount),
      percentCell(total <= 0 ? '—' : formatPercent(amount / total), total <= 0 ? null : amount / total),
    ]),
    emptyMessage: 'No spending to attribute in this period.',
  };
}

function monthlySpendSection(expenses: readonly Expense[], context: ExportContext): ExportSection {
  const byMonth = bucketByMonth(expenses, (e) => e.expenseDate, (e) => e.amount);
  const counts = bucketByMonth(expenses, (e) => e.expenseDate, () => 1);
  const months = [...byMonth.keys()].sort();
  return {
    title: 'By month',
    columns: [col('Month', 2), numCol('Transactions'), numCol('Amount', 1.3)],
    rows: months.map((key) => {
      const amount = byMonth.get(key) ?? 0;
      return [cell(monthLabel(key)), countCell(counts.get(key) ?? 0), moneyCell(context.money(amount), amount)];
    }),
    emptyMessage: 'No monthly totals in this period.',
  };
}

export function spendingReportDataset({
  expenses,
  categories,
  range,
  context,
  filterNote,
}: {
  expenses: readonly Expense[];
  categories: readonly ExpenseCategory[];
  range: ExportDateRange;
  context: ExportContext;
  filterNote?: string | null;
}): ExportDataset {
  const total = sumBy(expenses, (e) => e.amount);
  const byCategory = buildCategoryBreakdown(expenses, categories);
  const days = rangeDayCount(range);
  return {
    title: 'Spending report',
    subtitle: filterNote ?? null,
    periodLabel: periodLabel(range),
    summary: [
      { label: 'Total spending', value: context.money(total), emphasis: true },
      { label: 'Transactions', value: String(expenses.length) },
      { label: 'Categories used', value: String(byCategory.length) },
      { label: 'Daily average', value: context.money(days === 0 ? 0 : total / days) },
    ],
    sections: [categorySection(byCategory, total, context), sourceSection(expenses, total, context), monthlySpendSection(expenses, context)],
    footnote: TRANSFER_NOTE,
    generatedAt: new Date(),
  };
}

export function categoryReportDataset({
  expenses,
  categories,
  range,
  context,
  filterNote,
}: {
  expenses: readonly Expense[];
  categories: readonly ExpenseCategory[];
  range: ExportDateRange;
  context: ExportContext;
  filterNote?: string | null;
}): ExportDataset {
  const total = sumBy(expenses, (e) => e.amount);
  const byCategory = buildCategoryBreakdown(expenses, categories);
  const largest = byCategory[0];
  return {
    title: 'Category breakdown',
    subtitle: filterNote ?? null,
    periodLabel: periodLabel(range),
    summary: [
      { label: 'Total spending', value: context.money(total), emphasis: true },
      { label: 'Categories', value: String(byCategory.length) },
      ...(largest ? [{ label: 'Largest', value: largest.name }] : []),
    ],
    sections: [categorySection(byCategory, total, context)],
    footnote: TRANSFER_NOTE,
    generatedAt: new Date(),
  };
}

export function incomeVsExpenseDataset({
  expenses,
  income,
  range,
  context,
}: {
  expenses: readonly Expense[];
  income: readonly Income[];
  range: ExportDateRange;
  context: ExportContext;
}): ExportDataset {
  const spent = sumBy(expenses, (e) => e.amount);
  const received = sumBy(income, (i) => i.amount);
  const net = received - spent;
  const expenseByMonth = bucketByMonth(expenses, (e) => e.expenseDate, (e) => e.amount);
  const incomeByMonth = bucketByMonth(income, (i) => i.incomeDate, (i) => i.amount);
  const months = [...new Set([...expenseByMonth.keys(), ...incomeByMonth.keys()])].sort();

  return {
    title: 'Income vs expense',
    periodLabel: periodLabel(range),
    summary: [
      { label: 'Total income', value: context.money(received) },
      { label: 'Total expenses', value: context.money(spent) },
      { label: 'Net balance', value: context.money(net), emphasis: true },
      { label: 'Savings rate', value: received <= 0 ? '—' : formatPercent(net / received) },
    ],
    sections: [
      {
        title: 'Monthly breakdown',
        columns: [col('Month', 1.6), numCol('Income'), numCol('Expenses'), numCol('Net')],
        rows: months.map((key) => {
          const inc = incomeByMonth.get(key) ?? 0;
          const exp = expenseByMonth.get(key) ?? 0;
          return [
            cell(monthLabel(key)),
            moneyCell(context.money(inc), inc),
            moneyCell(context.money(exp), exp),
            moneyCell(context.money(inc - exp), inc - exp),
          ];
        }),
        totalRow: [
          cell('Total'),
          moneyCell(context.money(received), received),
          moneyCell(context.money(spent), spent),
          moneyCell(context.money(net), net),
        ],
        emptyMessage: 'No income or expenses in this period.',
      },
    ],
    footnote: TRANSFER_NOTE,
    generatedAt: new Date(),
  };
}
