/// Builds each of the six reports as an [ExportDataset].
///
/// Every method here is pure: domain objects in, a dataset out, no database
/// and no rendering. That is what makes the figures in an exported report
/// testable — including the guarantee that a transfer between the user's own
/// accounts never lands in a spending total.
///
/// **Why transfers cannot leak into the spending reports.** A transfer writes
/// two ledger rows and no expense and no income row at all. Reports B–F are
/// built from `expenses` and `income`, so a transfer is absent from them by
/// construction rather than by a filter someone has to remember to apply.
/// Report A is a bank statement, where both legs *must* appear — that is what
/// a statement is — and they are labelled "Money Transfer" so a reader can
/// tell them from spending.
library;

import '../../core/utils/formatters.dart';
import '../../models/analytics.dart';
import '../../models/bank_account.dart';
import '../../models/expense.dart';
import '../../models/expense_category.dart';
import '../../models/income.dart';
import '../../models/ledger_entry.dart';
import '../../models/money_transfer.dart';
import '../../models/payment_method.dart';
import 'export_models.dart';

/// Lookups and formatting shared by every builder.
class ExportContext {
  ExportContext({
    required this.currencyCode,
    List<BankAccount> accounts = const <BankAccount>[],
    List<ExpenseCategory> categories = const <ExpenseCategory>[],
    List<PaymentMethod> paymentMethods = const <PaymentMethod>[],
  })  : _accounts = <String, BankAccount>{
          for (final BankAccount a in accounts) a.id: a,
        },
        _categories = <String, ExpenseCategory>{
          for (final ExpenseCategory c in categories) c.id: c,
        },
        _paymentMethods = <String, PaymentMethod>{
          for (final PaymentMethod p in paymentMethods) p.id: p,
        };

  final String currencyCode;
  final Map<String, BankAccount> _accounts;
  final Map<String, ExpenseCategory> _categories;
  final Map<String, PaymentMethod> _paymentMethods;

  String money(double amount) =>
      Formatters.currency(amount, currencyCode: currencyCode);

  String date(DateTime value) => Formatters.dayMonthYear(value);

  /// A null account id means Cash, which is a real answer rather than a gap —
  /// it is how the app records spending that touches no bank balance.
  String accountName(String? id) =>
      id == null ? 'Cash' : (_accounts[id]?.displayLabel ?? 'Closed account');

  String categoryName(String? id) =>
      id == null ? 'Uncategorised' : (_categories[id]?.name ?? 'Uncategorised');

  String paymentMethodName(String? id) =>
      id == null ? '' : (_paymentMethods[id]?.name ?? '');
}

class ExportDatasetBuilder {
  const ExportDatasetBuilder();

  /// Printed at the foot of every spending report, because "where are my
  /// transfers?" is the first question a reconciling user asks.
  static const String _transferNote =
      'Transfers between your own accounts are not income or expense, so '
      'they are excluded from these figures. They appear on the bank '
      'statement of each account as "$moneyTransferLabel".';

  // ===================================================================
  // A. Bank statement
  // ===================================================================

  /// One account, every movement, with a running balance.
  ///
  /// [statement] is the same value object the on-screen statement renders, so
  /// the exported running balance is the one the user was just looking at
  /// rather than a second implementation of the same walk.
  ExportDataset bankStatement({
    required BankAccount account,
    required AccountStatement statement,
    required ExportDateRange range,
    required ExportContext context,
  }) {
    final List<List<ExportCell>> rows = <List<ExportCell>>[];

    // The on-screen statement is newest-first; a printed statement reads
    // oldest-first, the way the running balance accumulates.
    for (final StatementRow row in statement.rows.reversed) {
      final LedgerEntry entry = row.entry;
      rows.add(<ExportCell>[
        ExportCell.date(context.date(entry.txnDate)),
        ExportCell(_statementDescription(entry, context)),
        ExportCell(entry.categoryLabel ?? ''),
        entry.isDebit
            ? ExportCell.money(context.money(entry.amount), entry.amount)
            : const ExportCell.blank(),
        entry.isCredit
            ? ExportCell.money(context.money(entry.amount), entry.amount)
            : const ExportCell.blank(),
        ExportCell.money(
          context.money(row.balanceAfter),
          row.balanceAfter,
        ),
      ]);
    }

    return ExportDataset(
      title: 'Bank statement',
      subtitle: '${account.bankName} — ${account.displayLabel}',
      periodLabel: _periodLabel(range),
      summary: <ExportSummaryItem>[
        ExportSummaryItem(
          'Opening balance',
          context.money(statement.openingBalance),
        ),
        ExportSummaryItem('Total credits', context.money(statement.totalCredits)),
        ExportSummaryItem('Total debits', context.money(statement.totalDebits)),
        ExportSummaryItem(
          'Closing balance',
          context.money(statement.closingBalance),
          emphasis: true,
        ),
      ],
      sections: <ExportSection>[
        ExportSection(
          title: 'Transactions',
          note: 'Balance brought forward '
              '${context.money(statement.openingBalance)}',
          columns: const <ExportColumn>[
            ExportColumn('Date', width: 1.1),
            ExportColumn('Description', width: 2.6),
            ExportColumn('Category', width: 1.4),
            ExportColumn.number('Debit', width: 1.2),
            ExportColumn.number('Credit', width: 1.2),
            ExportColumn.number('Balance', width: 1.3),
          ],
          rows: rows,
          totalRow: <ExportCell>[
            const ExportCell('Closing balance'),
            const ExportCell.blank(),
            const ExportCell.blank(),
            ExportCell.money(
              context.money(statement.totalDebits),
              statement.totalDebits,
            ),
            ExportCell.money(
              context.money(statement.totalCredits),
              statement.totalCredits,
            ),
            ExportCell.money(
              context.money(statement.closingBalance),
              statement.closingBalance,
            ),
          ],
          emptyMessage: 'No movements on this account in this period.',
        ),
      ],
      footnote: 'Balances are derived from the transaction ledger. '
          'Account opening balance ${context.money(account.openingBalance)}.',
    );
  }

  /// A transfer leg says which account it faced, so a printed statement is
  /// readable without cross-referencing the other account.
  String _statementDescription(LedgerEntry entry, ExportContext context) {
    if (!entry.isTransfer) return entry.title;

    final String? other = entry.counterpartyAccountId;
    if (other == null) return entry.title;

    final String name = context.accountName(other);
    return entry.isDebit ? '${entry.title} to $name' : '${entry.title} from $name';
  }

  // ===================================================================
  // B. Expenses
  // ===================================================================

  ExportDataset expenses({
    required List<Expense> expenses,
    required ExportDateRange range,
    required ExportContext context,
    String? filterNote,
  }) {
    final List<Expense> ordered = List<Expense>.of(expenses)
      ..sort((Expense a, Expense b) => a.expenseDate.compareTo(b.expenseDate));

    final double total = _sum(ordered, (Expense e) => e.amount);

    return ExportDataset(
      title: 'Expenses',
      subtitle: filterNote,
      periodLabel: _periodLabel(range),
      summary: <ExportSummaryItem>[
        ExportSummaryItem('Total spent', context.money(total), emphasis: true),
        ExportSummaryItem('Transactions', '${ordered.length}'),
        ExportSummaryItem(
          'Average',
          context.money(ordered.isEmpty ? 0 : total / ordered.length),
        ),
      ],
      sections: <ExportSection>[
        ExportSection(
          title: 'Expenses',
          columns: const <ExportColumn>[
            ExportColumn('Date', width: 1.1),
            ExportColumn('Category', width: 1.2),
            ExportColumn('Merchant', width: 1.5),
            ExportColumn('Description', width: 1.8),
            ExportColumn('Paid from', width: 1.4),
            ExportColumn('Payment method', width: 1.2),
            ExportColumn('Notes', width: 1.5),
            ExportColumn.number('Amount', width: 1.2),
          ],
          rows: <List<ExportCell>>[
            for (final Expense e in ordered)
              <ExportCell>[
                ExportCell.date(context.date(e.expenseDate)),
                ExportCell(context.categoryName(e.categoryId)),
                ExportCell(e.merchant ?? ''),
                ExportCell(e.description ?? ''),
                ExportCell(context.accountName(e.bankAccountId)),
                ExportCell(context.paymentMethodName(e.paymentMethodId)),
                ExportCell(e.notes ?? ''),
                ExportCell.money(context.money(e.amount), e.amount),
              ],
          ],
          totalRow: <ExportCell>[
            const ExportCell('Total'),
            const ExportCell.blank(),
            const ExportCell.blank(),
            const ExportCell.blank(),
            const ExportCell.blank(),
            const ExportCell.blank(),
            const ExportCell.blank(),
            ExportCell.money(context.money(total), total),
          ],
          emptyMessage: 'No expenses in this period.',
        ),
      ],
      footnote: _transferNote,
    );
  }

  // ===================================================================
  // C. Income
  // ===================================================================

  ExportDataset income({
    required List<Income> income,
    required ExportDateRange range,
    required ExportContext context,
  }) {
    final List<Income> ordered = List<Income>.of(income)
      ..sort((Income a, Income b) => a.incomeDate.compareTo(b.incomeDate));

    final double total = _sum(ordered, (Income i) => i.amount);

    return ExportDataset(
      title: 'Income',
      periodLabel: _periodLabel(range),
      summary: <ExportSummaryItem>[
        ExportSummaryItem(
          'Total received',
          context.money(total),
          emphasis: true,
        ),
        ExportSummaryItem('Entries', '${ordered.length}'),
      ],
      sections: <ExportSection>[
        ExportSection(
          title: 'Income',
          columns: const <ExportColumn>[
            ExportColumn('Date', width: 1.1),
            ExportColumn('Source', width: 1.8),
            ExportColumn('Description', width: 2.2),
            ExportColumn('Paid into', width: 1.5),
            ExportColumn.number('Amount', width: 1.2),
          ],
          rows: <List<ExportCell>>[
            for (final Income i in ordered)
              <ExportCell>[
                ExportCell.date(context.date(i.incomeDate)),
                ExportCell(i.source ?? ''),
                ExportCell(i.description ?? ''),
                ExportCell(
                  i.bankAccountId == null
                      ? 'Not tracked'
                      : context.accountName(i.bankAccountId),
                ),
                ExportCell.money(context.money(i.amount), i.amount),
              ],
          ],
          totalRow: <ExportCell>[
            const ExportCell('Total'),
            const ExportCell.blank(),
            const ExportCell.blank(),
            const ExportCell.blank(),
            ExportCell.money(context.money(total), total),
          ],
          emptyMessage: 'No income in this period.',
        ),
      ],
      footnote: _transferNote,
    );
  }

  // ===================================================================
  // D. Spending report
  // ===================================================================

  ExportDataset spendingReport({
    required List<Expense> expenses,
    required List<ExpenseCategory> categories,
    required ExportDateRange range,
    required ExportContext context,
    String? filterNote,
  }) {
    final double total = _sum(expenses, (Expense e) => e.amount);
    final List<CategorySpend> byCategory =
        buildCategoryBreakdown(expenses, categories);

    return ExportDataset(
      title: 'Spending report',
      subtitle: filterNote,
      periodLabel: _periodLabel(range),
      summary: <ExportSummaryItem>[
        ExportSummaryItem('Total spending', context.money(total),
            emphasis: true),
        ExportSummaryItem('Transactions', '${expenses.length}'),
        ExportSummaryItem('Categories used', '${byCategory.length}'),
        ExportSummaryItem(
          'Daily average',
          context.money(range.dayCount == 0 ? 0 : total / range.dayCount),
        ),
      ],
      sections: <ExportSection>[
        _categorySection(byCategory, total, context),
        _sourceSection(expenses, total, context),
        _monthlySpendSection(expenses, context),
      ],
      footnote: _transferNote,
    );
  }

  // ===================================================================
  // E. Category-wise report
  // ===================================================================

  ExportDataset categoryReport({
    required List<Expense> expenses,
    required List<ExpenseCategory> categories,
    required ExportDateRange range,
    required ExportContext context,
    String? filterNote,
  }) {
    final double total = _sum(expenses, (Expense e) => e.amount);
    final List<CategorySpend> byCategory =
        buildCategoryBreakdown(expenses, categories);

    return ExportDataset(
      title: 'Category breakdown',
      subtitle: filterNote,
      periodLabel: _periodLabel(range),
      summary: <ExportSummaryItem>[
        ExportSummaryItem('Total spending', context.money(total),
            emphasis: true),
        ExportSummaryItem('Categories', '${byCategory.length}'),
        if (byCategory.isNotEmpty)
          ExportSummaryItem('Largest', byCategory.first.name),
      ],
      sections: <ExportSection>[_categorySection(byCategory, total, context)],
      footnote: _transferNote,
    );
  }

  // ===================================================================
  // F. Income vs expense
  // ===================================================================

  ExportDataset incomeVsExpense({
    required List<Expense> expenses,
    required List<Income> income,
    required ExportDateRange range,
    required ExportContext context,
  }) {
    final double spent = _sum(expenses, (Expense e) => e.amount);
    final double received = _sum(income, (Income i) => i.amount);
    final double net = received - spent;

    final Map<String, double> expenseByMonth =
        _bucket(expenses, (Expense e) => e.expenseDate, (Expense e) => e.amount);
    final Map<String, double> incomeByMonth =
        _bucket(income, (Income i) => i.incomeDate, (Income i) => i.amount);

    final List<String> months = <String>{
      ...expenseByMonth.keys,
      ...incomeByMonth.keys,
    }.toList()
      ..sort();

    return ExportDataset(
      title: 'Income vs expense',
      periodLabel: _periodLabel(range),
      summary: <ExportSummaryItem>[
        ExportSummaryItem('Total income', context.money(received)),
        ExportSummaryItem('Total expenses', context.money(spent)),
        ExportSummaryItem('Net balance', context.money(net), emphasis: true),
        ExportSummaryItem(
          'Savings rate',
          received <= 0 ? '—' : Formatters.percent(net / received),
        ),
      ],
      sections: <ExportSection>[
        ExportSection(
          title: 'Monthly breakdown',
          columns: const <ExportColumn>[
            ExportColumn('Month', width: 1.6),
            ExportColumn.number('Income'),
            ExportColumn.number('Expenses'),
            ExportColumn.number('Net'),
          ],
          rows: <List<ExportCell>>[
            for (final String key in months)
              _monthRow(key, incomeByMonth[key] ?? 0, expenseByMonth[key] ?? 0,
                  context),
          ],
          totalRow: <ExportCell>[
            const ExportCell('Total'),
            ExportCell.money(context.money(received), received),
            ExportCell.money(context.money(spent), spent),
            ExportCell.money(context.money(net), net),
          ],
          emptyMessage: 'No income or expenses in this period.',
        ),
      ],
      footnote: _transferNote,
    );
  }

  // ===================================================================
  // Shared sections
  // ===================================================================

  ExportSection _categorySection(
    List<CategorySpend> byCategory,
    double total,
    ExportContext context,
  ) {
    return ExportSection(
      title: 'By category',
      columns: const <ExportColumn>[
        ExportColumn('Category', width: 2),
        ExportColumn.number('Transactions'),
        ExportColumn.number('Amount', width: 1.3),
        ExportColumn.number('Share'),
      ],
      rows: <List<ExportCell>>[
        for (final CategorySpend spend in byCategory)
          <ExportCell>[
            ExportCell(spend.name),
            ExportCell.count(
              '${spend.transactionCount}',
              spend.transactionCount,
            ),
            ExportCell.money(context.money(spend.total), spend.total),
            ExportCell(
              total <= 0 ? '—' : Formatters.percent(spend.total / total),
              kind: ExportCellKind.percent,
              raw: total <= 0 ? null : spend.total / total,
            ),
          ],
      ],
      totalRow: <ExportCell>[
        const ExportCell('Total'),
        ExportCell.count(
          '${byCategory.fold<int>(0, (int s, CategorySpend c) => s + c.transactionCount)}',
          byCategory.fold<int>(
              0, (int s, CategorySpend c) => s + c.transactionCount),
        ),
        ExportCell.money(context.money(total), total),
        ExportCell(total <= 0 ? '—' : '100%', kind: ExportCellKind.percent),
      ],
      emptyMessage: 'No spending to break down in this period.',
    );
  }

  /// Spending grouped by where the money came from — each bank account, plus
  /// Cash.
  ExportSection _sourceSection(
    List<Expense> expenses,
    double total,
    ExportContext context,
  ) {
    final Map<String?, double> totals = <String?, double>{};
    final Map<String?, int> counts = <String?, int>{};
    for (final Expense e in expenses) {
      totals[e.bankAccountId] = (totals[e.bankAccountId] ?? 0) + e.amount;
      counts[e.bankAccountId] = (counts[e.bankAccountId] ?? 0) + 1;
    }

    final List<MapEntry<String?, double>> ordered = totals.entries.toList()
      ..sort((MapEntry<String?, double> a, MapEntry<String?, double> b) =>
          b.value.compareTo(a.value));

    return ExportSection(
      title: 'By payment source',
      columns: const <ExportColumn>[
        ExportColumn('Source', width: 2),
        ExportColumn.number('Transactions'),
        ExportColumn.number('Amount', width: 1.3),
        ExportColumn.number('Share'),
      ],
      rows: <List<ExportCell>>[
        for (final MapEntry<String?, double> entry in ordered)
          <ExportCell>[
            ExportCell(context.accountName(entry.key)),
            ExportCell.count('${counts[entry.key] ?? 0}', counts[entry.key] ?? 0),
            ExportCell.money(context.money(entry.value), entry.value),
            ExportCell(
              total <= 0 ? '—' : Formatters.percent(entry.value / total),
              kind: ExportCellKind.percent,
              raw: total <= 0 ? null : entry.value / total,
            ),
          ],
      ],
      emptyMessage: 'No spending to attribute in this period.',
    );
  }

  ExportSection _monthlySpendSection(
    List<Expense> expenses,
    ExportContext context,
  ) {
    final Map<String, double> byMonth =
        _bucket(expenses, (Expense e) => e.expenseDate, (Expense e) => e.amount);
    final Map<String, int> counts = <String, int>{};
    for (final Expense e in expenses) {
      final String key = _monthKey(e.expenseDate);
      counts[key] = (counts[key] ?? 0) + 1;
    }

    final List<String> months = byMonth.keys.toList()..sort();

    return ExportSection(
      title: 'By month',
      columns: const <ExportColumn>[
        ExportColumn('Month', width: 2),
        ExportColumn.number('Transactions'),
        ExportColumn.number('Amount', width: 1.3),
      ],
      rows: <List<ExportCell>>[
        for (final String key in months)
          <ExportCell>[
            ExportCell(_monthLabel(key)),
            ExportCell.count('${counts[key] ?? 0}', counts[key] ?? 0),
            ExportCell.money(context.money(byMonth[key]!), byMonth[key]!),
          ],
      ],
      emptyMessage: 'No monthly totals in this period.',
    );
  }

  List<ExportCell> _monthRow(
    String key,
    double income,
    double expense,
    ExportContext context,
  ) {
    final double net = income - expense;
    return <ExportCell>[
      ExportCell(_monthLabel(key)),
      ExportCell.money(context.money(income), income),
      ExportCell.money(context.money(expense), expense),
      ExportCell.money(context.money(net), net),
    ];
  }

  // ===================================================================
  // Helpers
  // ===================================================================

  static double _sum<T>(List<T> items, double Function(T) value) =>
      items.fold<double>(0, (double sum, T item) => sum + value(item));

  static Map<String, double> _bucket<T>(
    List<T> items,
    DateTime Function(T) date,
    double Function(T) value,
  ) {
    final Map<String, double> out = <String, double>{};
    for (final T item in items) {
      final String key = _monthKey(date(item));
      out[key] = (out[key] ?? 0) + value(item);
    }
    return out;
  }

  static String _monthKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';

  static String _monthLabel(String key) {
    final List<String> parts = key.split('-');
    return Formatters.monthYear(
      DateTime(int.parse(parts[0]), int.parse(parts[1]), 1),
    );
  }

  static String _periodLabel(ExportDateRange range) {
    if (range.isWholeMonth) return Formatters.monthYear(range.start);
    return '${Formatters.dayMonthYear(range.start)} – '
        '${Formatters.dayMonthYear(range.endInclusive)}';
  }
}
