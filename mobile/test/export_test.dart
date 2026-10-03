/// Tests for report building and rendering.
///
/// The figures in an export are the whole point of it, so these assert the
/// arithmetic — totals, shares, running balances, monthly buckets — rather
/// than that a file was produced. The two properties that matter most get
/// their own groups: a transfer never appears as spending, and a date range
/// includes exactly the days it says it does.
library;

import 'dart:convert';

import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/income.dart';
import 'package:expense_tracker/models/ledger_entry.dart';
import 'package:expense_tracker/models/payment_method.dart';
import 'package:expense_tracker/services/export/csv_export_service.dart';
import 'package:expense_tracker/services/export/export_dataset_builder.dart';
import 'package:expense_tracker/services/export/export_models.dart';
import 'package:expense_tracker/services/export/export_service.dart';
import 'package:expense_tracker/services/export/pdf_export_service.dart';
import 'package:flutter_test/flutter_test.dart';

const ExportDatasetBuilder builder = ExportDatasetBuilder();
const CsvExportService csv = CsvExportService();
const PdfExportService pdf = PdfExportService();

final ExportDateRange september = ExportDateRange(
  DateTime(2026, 9, 1),
  DateTime(2026, 9, 30),
);

final List<ExpenseCategory> categories = <ExpenseCategory>[
  const ExpenseCategory(id: 'food', userId: 'u1', name: 'Food'),
  const ExpenseCategory(id: 'travel', userId: 'u1', name: 'Travel'),
];

final List<BankAccount> accounts = <BankAccount>[
  const BankAccount(
    id: 'a1',
    userId: 'u1',
    bankName: 'HDFC',
    nickname: 'Salary',
    last4: '4821',
    openingBalance: 10000,
  ),
  const BankAccount(
    id: 'a2',
    userId: 'u1',
    bankName: 'ICICI',
    nickname: 'Savings',
    last4: '9930',
  ),
];

ExportContext context() => ExportContext(
      currencyCode: 'INR',
      accounts: accounts,
      categories: categories,
      paymentMethods: <PaymentMethod>[
        const PaymentMethod(id: 'pm1', userId: 'u1', name: 'UPI'),
      ],
    );

Expense expense({
  required String id,
  required double amount,
  required DateTime date,
  String? categoryId = 'food',
  String? accountId = 'a1',
  String? merchant,
}) =>
    Expense(
      id: id,
      userId: 'u1',
      amount: amount,
      expenseDate: date,
      categoryId: categoryId,
      bankAccountId: accountId,
      merchant: merchant,
    );

Income income({
  required String id,
  required double amount,
  required DateTime date,
  String? source = 'Salary',
}) =>
    Income(
      id: id,
      userId: 'u1',
      amount: amount,
      incomeDate: date,
      source: source,
      bankAccountId: 'a1',
    );

LedgerEntry entry({
  required String id,
  required LedgerDirection direction,
  required double amount,
  required DateTime date,
  String? description,
  String? transferGroupId,
  String? counterparty,
}) =>
    LedgerEntry(
      id: id,
      userId: 'u1',
      accountId: 'a1',
      direction: direction,
      amount: amount,
      txnDate: date,
      description: description,
      transferGroupId: transferGroupId,
      counterpartyAccountId: counterparty,
      createdAt: date,
    );

/// Every cell of a dataset as one searchable string.
String flatten(ExportDataset dataset) {
  final StringBuffer out = StringBuffer()
    ..write(dataset.title)
    ..write(dataset.subtitle ?? '')
    ..write(dataset.periodLabel)
    ..write(dataset.footnote ?? '');
  for (final ExportSummaryItem item in dataset.summary) {
    out.write('${item.label}=${item.value};');
  }
  for (final ExportSection section in dataset.sections) {
    out.write(section.title);
    for (final List<ExportCell> row in section.rows) {
      for (final ExportCell cell in row) {
        out.write('${cell.text}|');
      }
    }
  }
  return out.toString();
}

ExportSection sectionNamed(ExportDataset dataset, String title) =>
    dataset.sections.firstWhere((ExportSection s) => s.title == title);

void main() {
  // =================================================================
  group('date range', () {
    test('an inclusive end becomes an exclusive query bound', () {
      expect(september.endExclusive, DateTime(2026, 10, 1));
    });

    test('counts every day it covers', () {
      expect(september.dayCount, 30);
      expect(
        ExportDateRange(DateTime(2026, 9, 1), DateTime(2026, 9, 1)).dayCount,
        1,
      );
    });

    test('recognises a whole calendar month', () {
      expect(september.isWholeMonth, isTrue);
      expect(ExportDateRange.month(DateTime(2026, 2, 14)).isWholeMonth, isTrue);
      expect(
        ExportDateRange(DateTime(2026, 9, 1), DateTime(2026, 9, 29))
            .isWholeMonth,
        isFalse,
      );
    });

    test('handles February in a leap year', () {
      final ExportDateRange feb = ExportDateRange.month(DateTime(2028, 2, 1));
      expect(feb.endInclusive, DateTime(2028, 2, 29));
      expect(feb.dayCount, 29);
    });

    test('includes both endpoints', () {
      expect(september.contains(DateTime(2026, 9, 1)), isTrue);
      expect(september.contains(DateTime(2026, 9, 30)), isTrue);
      expect(september.contains(DateTime(2026, 8, 31)), isFalse);
      expect(september.contains(DateTime(2026, 10, 1)), isFalse);
    });

    test('lastDays counts today as one of them', () {
      final ExportDateRange range =
          ExportDateRange.lastDays(30, now: DateTime(2026, 9, 30));
      expect(range.endInclusive, DateTime(2026, 9, 30));
      expect(range.start, DateTime(2026, 9, 1));
      expect(range.dayCount, 30);
    });
  });

  // =================================================================
  group('filenames', () {
    test('a whole month collapses to yyyy-MM', () {
      expect(
        ExportService.fileNameFor(
          type: ExportReportType.spendingReport,
          range: september,
          format: ExportFormat.pdf,
        ),
        'spending_report_2026-09.pdf',
      );
    });

    test('a partial range spells both ends out', () {
      expect(
        ExportService.fileNameFor(
          type: ExportReportType.expenses,
          range: ExportDateRange(DateTime(2026, 9, 1), DateTime(2026, 9, 14)),
          format: ExportFormat.csv,
        ),
        'expenses_2026-09-01_to_2026-09-14.csv',
      );
    });

    test('a statement carries the bank name', () {
      expect(
        ExportService.fileNameFor(
          type: ExportReportType.bankStatement,
          range: september,
          format: ExportFormat.csv,
          qualifier: 'HDFC',
        ),
        'bank_statement_hdfc_2026-09.csv',
      );
    });

    test('a category report is named as the brief asked', () {
      expect(
        ExportService.fileNameFor(
          type: ExportReportType.categoryReport,
          range: september,
          format: ExportFormat.pdf,
        ),
        'category_spending_2026-09.pdf',
      );
    });

    test('slugify keeps a filename safe', () {
      expect(ExportService.slugify('State Bank of India'), 'state_bank_of_india');
      expect(ExportService.slugify('HDFC •••• 4821'), 'hdfc_4821');
      expect(ExportService.slugify('  /../etc/passwd  '), 'etc_passwd');
      expect(ExportService.slugify('...'), '');
    });

    test('slugify truncates rather than producing an unwieldy name', () {
      expect(
        ExportService.slugify('a very long bank name that keeps going on')
            .length,
        lessThanOrEqualTo(24),
      );
    });
  });

  // =================================================================
  group('A. bank statement', () {
    AccountStatement statement() => buildStatement(
          openingBalance: 10000,
          entries: <LedgerEntry>[
            entry(
              id: 'l1',
              direction: LedgerDirection.credit,
              amount: 5000,
              date: DateTime(2026, 9, 5),
              description: 'Deposit',
            ),
            entry(
              id: 'l2',
              direction: LedgerDirection.debit,
              amount: 1200,
              date: DateTime(2026, 9, 10),
              description: 'Groceries',
            ),
          ],
        );

    test('opening, totals and closing reconcile', () {
      final ExportDataset dataset = builder.bankStatement(
        account: accounts.first,
        statement: statement(),
        range: september,
        context: context(),
      );

      final Map<String, String> summary = <String, String>{
        for (final ExportSummaryItem i in dataset.summary) i.label: i.value,
      };

      expect(summary['Opening balance'], contains('10,000'));
      expect(summary['Total credits'], contains('5,000'));
      expect(summary['Total debits'], contains('1,200'));
      // 10000 + 5000 - 1200
      expect(summary['Closing balance'], contains('13,800'));
    });

    test('rows read oldest first so the running balance climbs', () {
      final ExportDataset dataset = builder.bankStatement(
        account: accounts.first,
        statement: statement(),
        range: september,
        context: context(),
      );

      final List<List<ExportCell>> rows =
          sectionNamed(dataset, 'Transactions').rows;

      expect(rows.first[1].text, 'Deposit');
      expect(rows.last[1].text, 'Groceries');
      // Balance column, after each movement.
      expect(rows.first.last.raw, 15000);
      expect(rows.last.last.raw, 13800);
    });

    test('a debit fills the debit column and leaves credit blank', () {
      final ExportDataset dataset = builder.bankStatement(
        account: accounts.first,
        statement: statement(),
        range: september,
        context: context(),
      );

      final List<List<ExportCell>> rows =
          sectionNamed(dataset, 'Transactions').rows;

      // Credit row: debit blank, credit filled.
      expect(rows.first[3].isBlank, isTrue);
      expect(rows.first[4].raw, 5000);
      // Debit row: the other way round.
      expect(rows.last[3].raw, 1200);
      expect(rows.last[4].isBlank, isTrue);
    });

    test('a transfer leg names the account on the other side', () {
      final ExportDataset dataset = builder.bankStatement(
        account: accounts.first,
        statement: buildStatement(
          openingBalance: 10000,
          entries: <LedgerEntry>[
            entry(
              id: 't1',
              direction: LedgerDirection.debit,
              amount: 2000,
              date: DateTime(2026, 9, 12),
              transferGroupId: 'g1',
              counterparty: 'a2',
            ),
          ],
        ),
        range: september,
        context: context(),
      );

      final List<ExportCell> row = sectionNamed(dataset, 'Transactions').rows.single;

      expect(row[1].text, 'Money Transfer to Savings •••• 9930');
      expect(row[2].text, 'Money Transfer');
    });

    test('a transfer leg survives its counterparty being deleted', () {
      final ExportDataset dataset = builder.bankStatement(
        account: accounts.first,
        statement: buildStatement(
          openingBalance: 0,
          entries: <LedgerEntry>[
            entry(
              id: 't1',
              direction: LedgerDirection.credit,
              amount: 2000,
              date: DateTime(2026, 9, 12),
              transferGroupId: 'g1',
              counterparty: 'gone',
            ),
          ],
        ),
        range: september,
        context: context(),
      );

      final List<ExportCell> row =
          sectionNamed(dataset, 'Transactions').rows.single;

      expect(row[1].text, contains('Closed account'));
      // The money still moved, so the balance must still be right.
      expect(row.last.raw, 2000);
    });

    test('an account with no movements exports an empty statement', () {
      final ExportDataset dataset = builder.bankStatement(
        account: accounts.first,
        statement: buildStatement(
          openingBalance: 10000,
          entries: const <LedgerEntry>[],
        ),
        range: september,
        context: context(),
      );

      expect(dataset.hasRows, isFalse);
      expect(sectionNamed(dataset, 'Transactions').isEmpty, isTrue);
      // The balances are still correct and still worth exporting.
      expect(
        dataset.summary.last.value,
        contains('10,000'),
      );
    });
  });

  // =================================================================
  group('B. expenses', () {
    final List<Expense> rows = <Expense>[
      expense(
        id: 'e1',
        amount: 450,
        date: DateTime(2026, 9, 3),
        merchant: 'Green Leaf',
      ),
      expense(
        id: 'e2',
        amount: 1200,
        date: DateTime(2026, 9, 18),
        categoryId: 'travel',
        accountId: null,
      ),
    ];

    test('totals and averages', () {
      final ExportDataset dataset = builder.expenses(
        expenses: rows,
        range: september,
        context: context(),
      );

      final Map<String, String> summary = <String, String>{
        for (final ExportSummaryItem i in dataset.summary) i.label: i.value,
      };

      expect(summary['Total spent'], contains('1,650'));
      expect(summary['Transactions'], '2');
      expect(summary['Average'], contains('825'));
    });

    test('a cash expense names Cash rather than showing a gap', () {
      final ExportDataset dataset = builder.expenses(
        expenses: rows,
        range: september,
        context: context(),
      );

      final List<List<ExportCell>> out = dataset.sections.single.rows;
      expect(out[0][4].text, 'Salary •••• 4821');
      expect(out[1][4].text, 'Cash');
    });

    test('the total row matches the sum of the rows', () {
      final ExportDataset dataset = builder.expenses(
        expenses: rows,
        range: september,
        context: context(),
      );

      final ExportSection section = dataset.sections.single;
      final double rowSum = section.rows.fold<double>(
        0,
        (double sum, List<ExportCell> r) => sum + (r.last.raw ?? 0),
      );

      expect(section.totalRow!.last.raw, rowSum);
    });

    test('a filter says so on the report itself', () {
      final ExportDataset dataset = builder.expenses(
        expenses: rows,
        range: september,
        context: context(),
        filterNote: 'Filtered to Food',
      );

      expect(dataset.subtitle, 'Filtered to Food');
    });

    test('no expenses is an empty report, not a broken one', () {
      final ExportDataset dataset = builder.expenses(
        expenses: const <Expense>[],
        range: september,
        context: context(),
      );

      expect(dataset.hasRows, isFalse);
      expect(dataset.sections.single.emptyMessage, isNotEmpty);
      expect(csv.renderString(dataset), contains('No expenses in this period'));
    });
  });

  // =================================================================
  group('C. income', () {
    test('totals and untracked accounts', () {
      final ExportDataset dataset = builder.income(
        income: <Income>[
          income(id: 'i1', amount: 50000, date: DateTime(2026, 9, 1)),
          Income(
            id: 'i2',
            userId: 'u1',
            amount: 2500,
            incomeDate: DateTime(2026, 9, 20),
            source: 'Refund',
          ),
        ],
        range: september,
        context: context(),
      );

      expect(dataset.summary.first.value, contains('52,500'));
      expect(dataset.sections.single.rows[0][3].text, 'Salary •••• 4821');
      expect(dataset.sections.single.rows[1][3].text, 'Not tracked');
    });

    test('no income is an empty report', () {
      final ExportDataset dataset = builder.income(
        income: const <Income>[],
        range: september,
        context: context(),
      );
      expect(dataset.hasRows, isFalse);
    });
  });

  // =================================================================
  group('D. spending report', () {
    final List<Expense> rows = <Expense>[
      expense(id: 'e1', amount: 600, date: DateTime(2026, 9, 2)),
      expense(id: 'e2', amount: 400, date: DateTime(2026, 9, 9)),
      expense(
        id: 'e3',
        amount: 1000,
        date: DateTime(2026, 10, 4),
        categoryId: 'travel',
        accountId: null,
      ),
    ];

    test('has all three breakdowns the brief asked for', () {
      final ExportDataset dataset = builder.spendingReport(
        expenses: rows,
        categories: categories,
        range: september,
        context: context(),
      );

      expect(
        dataset.sections.map((ExportSection s) => s.title),
        <String>['By category', 'By payment source', 'By month'],
      );
    });

    test('category shares add up to the whole', () {
      final ExportDataset dataset = builder.spendingReport(
        expenses: rows,
        categories: categories,
        range: september,
        context: context(),
      );

      final ExportSection section = sectionNamed(dataset, 'By category');
      final double shareSum = section.rows.fold<double>(
        0,
        (double sum, List<ExportCell> r) => sum + ((r[3].raw ?? 0).toDouble()),
      );

      expect(shareSum, closeTo(1.0, 0.0001));
      // Food 1000 of 2000.
      expect(section.rows.first[2].raw, 1000);
      expect(section.rows.first[3].text, '50%');
    });

    test('splits by payment source, Cash included', () {
      final ExportSection section = sectionNamed(
        builder.spendingReport(
          expenses: rows,
          categories: categories,
          range: september,
          context: context(),
        ),
        'By payment source',
      );

      final Map<String, num?> byName = <String, num?>{
        for (final List<ExportCell> r in section.rows) r[0].text: r[2].raw,
      };

      expect(byName['Salary •••• 4821'], 1000);
      expect(byName['Cash'], 1000);
    });

    test('buckets by month', () {
      final ExportSection section = sectionNamed(
        builder.spendingReport(
          expenses: rows,
          categories: categories,
          range: september,
          context: context(),
        ),
        'By month',
      );

      expect(section.rows.length, 2);
      expect(section.rows.first[0].text, 'September 2026');
      expect(section.rows.first[2].raw, 1000);
      expect(section.rows.last[0].text, 'October 2026');
    });

    test('a daily average uses the period, not the number of rows', () {
      final ExportDataset dataset = builder.spendingReport(
        expenses: rows,
        categories: categories,
        range: september,
        context: context(),
      );

      final ExportSummaryItem daily = dataset.summary.firstWhere(
        (ExportSummaryItem i) => i.label == 'Daily average',
      );
      // 2000 over 30 days.
      expect(daily.value, contains('66.67'));
    });

    test('no spending does not divide by zero', () {
      final ExportDataset dataset = builder.spendingReport(
        expenses: const <Expense>[],
        categories: categories,
        range: september,
        context: context(),
      );

      expect(dataset.hasRows, isFalse);
      expect(() => csv.renderString(dataset), returnsNormally);
    });
  });

  // =================================================================
  group('E. category report', () {
    test('category, count, amount and share', () {
      final ExportDataset dataset = builder.categoryReport(
        expenses: <Expense>[
          expense(id: 'e1', amount: 750, date: DateTime(2026, 9, 2)),
          expense(id: 'e2', amount: 250, date: DateTime(2026, 9, 4)),
          expense(
            id: 'e3',
            amount: 1000,
            date: DateTime(2026, 9, 6),
            categoryId: 'travel',
          ),
        ],
        categories: categories,
        range: september,
        context: context(),
      );

      final ExportSection section = sectionNamed(dataset, 'By category');
      expect(section.columns.map((ExportColumn c) => c.label),
          <String>['Category', 'Transactions', 'Amount', 'Share']);

      // Sorted by amount, so Travel's single 1000 leads Food's 1000 only if
      // it is larger; here they tie at 1000 and both must be present.
      final Map<String, List<ExportCell>> byName =
          <String, List<ExportCell>>{
        for (final List<ExportCell> r in section.rows) r[0].text: r,
      };

      expect(byName['Food']![1].raw, 2);
      expect(byName['Food']![2].raw, 1000);
      expect(byName['Travel']![1].raw, 1);
      expect(section.totalRow![1].raw, 3);
      expect(section.totalRow![2].raw, 2000);
    });

    test('an uncategorised expense is named, not dropped', () {
      final ExportDataset dataset = builder.categoryReport(
        expenses: <Expense>[
          expense(
            id: 'e1',
            amount: 100,
            date: DateTime(2026, 9, 2),
            categoryId: null,
          ),
        ],
        categories: categories,
        range: september,
        context: context(),
      );

      expect(flatten(dataset), contains('Uncategorised'));
      expect(sectionNamed(dataset, 'By category').totalRow![2].raw, 100);
    });
  });

  // =================================================================
  group('F. income vs expense', () {
    test('net, savings rate and monthly breakdown', () {
      final ExportDataset dataset = builder.incomeVsExpense(
        expenses: <Expense>[
          expense(id: 'e1', amount: 20000, date: DateTime(2026, 9, 5)),
          expense(id: 'e2', amount: 10000, date: DateTime(2026, 10, 5)),
        ],
        income: <Income>[
          income(id: 'i1', amount: 50000, date: DateTime(2026, 9, 1)),
          income(id: 'i2', amount: 50000, date: DateTime(2026, 10, 1)),
        ],
        range: ExportDateRange(DateTime(2026, 9, 1), DateTime(2026, 10, 31)),
        context: context(),
      );

      final Map<String, String> summary = <String, String>{
        for (final ExportSummaryItem i in dataset.summary) i.label: i.value,
      };

      expect(summary['Total income'], contains('1,00,000'));
      expect(summary['Total expenses'], contains('30,000'));
      expect(summary['Net balance'], contains('70,000'));
      expect(summary['Savings rate'], '70%');

      final ExportSection section = sectionNamed(dataset, 'Monthly breakdown');
      expect(section.rows.length, 2);
      expect(section.rows.first[0].text, 'September 2026');
      expect(section.rows.first[3].raw, 30000);
      expect(section.rows.last[3].raw, 40000);
    });

    test('a month with expenses but no income still appears', () {
      final ExportDataset dataset = builder.incomeVsExpense(
        expenses: <Expense>[
          expense(id: 'e1', amount: 500, date: DateTime(2026, 9, 5)),
        ],
        income: const <Income>[],
        range: september,
        context: context(),
      );

      final ExportSection section = sectionNamed(dataset, 'Monthly breakdown');
      expect(section.rows.single[1].raw, 0);
      expect(section.rows.single[2].raw, 500);
      expect(section.rows.single[3].raw, -500);
    });

    test('zero income does not divide by zero', () {
      final ExportDataset dataset = builder.incomeVsExpense(
        expenses: <Expense>[
          expense(id: 'e1', amount: 500, date: DateTime(2026, 9, 5)),
        ],
        income: const <Income>[],
        range: september,
        context: context(),
      );

      final ExportSummaryItem rate = dataset.summary.firstWhere(
        (ExportSummaryItem i) => i.label == 'Savings rate',
      );
      expect(rate.value, '—');
    });

    test('nothing at all is an empty report', () {
      final ExportDataset dataset = builder.incomeVsExpense(
        expenses: const <Expense>[],
        income: const <Income>[],
        range: september,
        context: context(),
      );
      expect(dataset.hasRows, isFalse);
    });
  });

  // =================================================================
  group('transfers stay out of spending', () {
    // A transfer writes two ledger rows and no expense and no income row.
    // These assert the consequence: every report built from expenses and
    // income is blind to it, and only the statement shows it.
    final List<LedgerEntry> transferLegs = <LedgerEntry>[
      entry(
        id: 't1',
        direction: LedgerDirection.debit,
        amount: 10000,
        date: DateTime(2026, 9, 15),
        transferGroupId: 'g1',
        counterparty: 'a2',
      ),
    ];

    final List<Expense> spending = <Expense>[
      expense(id: 'e1', amount: 1500, date: DateTime(2026, 9, 3)),
    ];

    test('a spending report totals only the expense', () {
      final ExportDataset dataset = builder.spendingReport(
        expenses: spending,
        categories: categories,
        range: september,
        context: context(),
      );

      expect(dataset.summary.first.value, contains('1,500'));
      expect(flatten(dataset), isNot(contains('10,000')));
      expect(flatten(dataset), isNot(contains('Money Transfer to')));
    });

    test('a category report never lists Money Transfer as a category', () {
      final ExportDataset dataset = builder.categoryReport(
        expenses: spending,
        categories: categories,
        range: september,
        context: context(),
      );

      final List<String> names = <String>[
        for (final List<ExportCell> r
            in sectionNamed(dataset, 'By category').rows)
          r[0].text,
      ];

      expect(names, <String>['Food']);
      expect(names, isNot(contains('Money Transfer')));
    });

    test('income vs expense is unmoved by a transfer', () {
      final ExportDataset dataset = builder.incomeVsExpense(
        expenses: spending,
        income: <Income>[
          income(id: 'i1', amount: 50000, date: DateTime(2026, 9, 1)),
        ],
        range: september,
        context: context(),
      );

      final Map<String, String> summary = <String, String>{
        for (final ExportSummaryItem i in dataset.summary) i.label: i.value,
      };

      expect(summary['Total expenses'], contains('1,500'));
      expect(summary['Net balance'], contains('48,500'));
    });

    test('every spending report says where transfers went', () {
      for (final ExportDataset dataset in <ExportDataset>[
        builder.expenses(
          expenses: spending,
          range: september,
          context: context(),
        ),
        builder.spendingReport(
          expenses: spending,
          categories: categories,
          range: september,
          context: context(),
        ),
        builder.categoryReport(
          expenses: spending,
          categories: categories,
          range: september,
          context: context(),
        ),
        builder.incomeVsExpense(
          expenses: spending,
          income: const <Income>[],
          range: september,
          context: context(),
        ),
      ]) {
        expect(
          dataset.footnote,
          contains('not income or expense'),
          reason: '${dataset.title} must explain the omission',
        );
      }
    });

    test('but the statement shows both the transfer and the spending', () {
      final ExportDataset dataset = builder.bankStatement(
        account: accounts.first,
        statement: buildStatement(
          openingBalance: 20000,
          entries: <LedgerEntry>[
            ...transferLegs,
            entry(
              id: 'l1',
              direction: LedgerDirection.debit,
              amount: 1500,
              date: DateTime(2026, 9, 3),
              description: 'Green Leaf',
            ),
          ],
        ),
        range: september,
        context: context(),
      );

      final String text = flatten(dataset);
      expect(text, contains('Money Transfer'));
      expect(text, contains('Green Leaf'));
      // 20000 - 10000 - 1500
      expect(
        sectionNamed(dataset, 'Transactions').totalRow!.last.raw,
        8500,
      );
    });
  });

  // =================================================================
  group('CSV', () {
    ExportDataset sample() => builder.expenses(
          expenses: <Expense>[
            expense(
              id: 'e1',
              amount: 450.5,
              date: DateTime(2026, 9, 3),
              merchant: 'Green Leaf',
            ),
          ],
          range: september,
          context: context(),
        );

    test('carries the header, the figures and the table', () {
      final String out = csv.renderString(sample());

      expect(out, contains('Expenses'));
      expect(out, contains('Period,September 2026'));
      expect(out, contains('Date,Category,Merchant'));
      expect(out, contains('Green Leaf'));
    });

    test('money is written as a bare number a spreadsheet can sum', () {
      final String out = csv.renderString(sample());

      expect(out, contains('450.50'));
      expect(
        out,
        isNot(contains('Rs 450.50')),
        reason: 'a formatted string cannot be summed',
      );
    });

    test('uses CRLF line endings', () {
      expect(csv.renderString(sample()), contains('\r\n'));
    });

    test('quotes a field containing a comma', () {
      final ExportDataset dataset = builder.expenses(
        expenses: <Expense>[
          expense(
            id: 'e1',
            amount: 10,
            date: DateTime(2026, 9, 3),
            merchant: 'Smith, Jones & Co',
          ),
        ],
        range: september,
        context: context(),
      );

      expect(csv.renderString(dataset), contains('"Smith, Jones & Co"'));
    });

    test('escapes an embedded quote by doubling it', () {
      final ExportDataset dataset = builder.expenses(
        expenses: <Expense>[
          expense(
            id: 'e1',
            amount: 10,
            date: DateTime(2026, 9, 3),
            merchant: 'The "Blue" Door',
          ),
        ],
        range: september,
        context: context(),
      );

      expect(csv.renderString(dataset), contains('"The ""Blue"" Door"'));
    });

    test('neutralises a formula injected through a merchant name', () {
      final ExportDataset dataset = builder.expenses(
        expenses: <Expense>[
          expense(
            id: 'e1',
            amount: 10,
            date: DateTime(2026, 9, 3),
            merchant: '=HYPERLINK("http://evil","click")',
          ),
        ],
        range: september,
        context: context(),
      );

      final String out = csv.renderString(dataset);
      expect(out, contains("'=HYPERLINK"));
      expect(
        out.contains(',=HYPERLINK'),
        isFalse,
        reason: 'must never begin a cell with a bare =',
      );
    });

    test('a negative amount stays a number, not a quoted string', () {
      // The formula guard triggers on a leading '-', so a negative net must be
      // exempted or every income-vs-expense CSV loses its arithmetic.
      final ExportDataset dataset = builder.incomeVsExpense(
        expenses: <Expense>[
          expense(id: 'e1', amount: 500, date: DateTime(2026, 9, 5)),
        ],
        income: const <Income>[],
        range: september,
        context: context(),
      );

      final String out = csv.renderString(dataset);
      expect(out, contains('-500.00'));
      expect(out, isNot(contains("'-500.00")));
    });

    test('a newline inside a note cannot break the row structure', () {
      final ExportDataset dataset = builder.expenses(
        expenses: <Expense>[
          Expense(
            id: 'e1',
            userId: 'u1',
            amount: 10,
            expenseDate: DateTime(2026, 9, 3),
            categoryId: 'food',
            notes: 'line one\nline two',
          ),
        ],
        range: september,
        context: context(),
      );

      final String out = csv.renderString(dataset);
      // Header block + summary + section + header row + data + total + note.
      final List<String> dataRows = out
          .split('\r\n')
          .where((String l) => l.startsWith('3 Sep 2026'))
          .toList();
      expect(dataRows.length, 1);
      expect(dataRows.single, contains('line one line two'));
    });

    test('renders to UTF-8 bytes', () async {
      final List<int> bytes = await csv.render(sample());
      expect(utf8.decode(bytes), csv.renderString(sample()));
    });

    test('an empty report still produces a readable file', () {
      final String out = csv.renderString(
        builder.income(
          income: const <Income>[],
          range: september,
          context: context(),
        ),
      );

      expect(out, contains('Income'));
      expect(out, contains('No income in this period'));
    });
  });

  // =================================================================
  group('PDF', () {
    test('produces a real PDF document', () async {
      final List<int> bytes = await pdf.render(
        builder.expenses(
          expenses: <Expense>[
            expense(id: 'e1', amount: 450, date: DateTime(2026, 9, 3)),
          ],
          range: september,
          context: context(),
        ),
      );

      expect(bytes.length, greaterThan(1000));
      // Every PDF begins with the version header and ends with %%EOF.
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(
        String.fromCharCodes(bytes.skip(bytes.length - 8)),
        contains('%%EOF'),
      );
    });

    test('renders every report type without throwing', () async {
      final List<ExportDataset> all = <ExportDataset>[
        builder.bankStatement(
          account: accounts.first,
          statement: buildStatement(
            openingBalance: 100,
            entries: <LedgerEntry>[
              entry(
                id: 'l1',
                direction: LedgerDirection.credit,
                amount: 50,
                date: DateTime(2026, 9, 2),
              ),
            ],
          ),
          range: september,
          context: context(),
        ),
        builder.expenses(
          expenses: <Expense>[
            expense(id: 'e1', amount: 10, date: DateTime(2026, 9, 2)),
          ],
          range: september,
          context: context(),
        ),
        builder.income(
          income: <Income>[
            income(id: 'i1', amount: 10, date: DateTime(2026, 9, 2)),
          ],
          range: september,
          context: context(),
        ),
        builder.spendingReport(
          expenses: <Expense>[
            expense(id: 'e1', amount: 10, date: DateTime(2026, 9, 2)),
          ],
          categories: categories,
          range: september,
          context: context(),
        ),
        builder.categoryReport(
          expenses: <Expense>[
            expense(id: 'e1', amount: 10, date: DateTime(2026, 9, 2)),
          ],
          categories: categories,
          range: september,
          context: context(),
        ),
        builder.incomeVsExpense(
          expenses: <Expense>[
            expense(id: 'e1', amount: 10, date: DateTime(2026, 9, 2)),
          ],
          income: <Income>[
            income(id: 'i1', amount: 20, date: DateTime(2026, 9, 2)),
          ],
          range: september,
          context: context(),
        ),
      ];

      for (final ExportDataset dataset in all) {
        final List<int> bytes = await pdf.render(dataset);
        expect(bytes.length, greaterThan(500), reason: dataset.title);
      }
    });

    test('an empty report renders rather than failing', () async {
      final List<int> bytes = await pdf.render(
        builder.expenses(
          expenses: const <Expense>[],
          range: september,
          context: context(),
        ),
      );
      expect(bytes.length, greaterThan(500));
    });

    test('a long statement paginates', () async {
      final List<LedgerEntry> many = <LedgerEntry>[
        for (int i = 1; i <= 120; i++)
          entry(
            id: 'l$i',
            direction: i.isEven
                ? LedgerDirection.credit
                : LedgerDirection.debit,
            amount: (100 + i).toDouble(),
            date: DateTime(2026, 9, 1 + (i % 29)),
            description: 'Movement number $i',
          ),
      ];

      final List<int> bytes = await pdf.render(
        builder.bankStatement(
          account: accounts.first,
          statement: buildStatement(openingBalance: 50000, entries: many),
          range: september,
          context: context(),
        ),
      );

      expect(bytes.length, greaterThan(5000));
    });

    test('the rupee sign becomes readable text, not a missing glyph', () {
      // Helvetica has no glyph for U+20B9, and a blank where an amount should
      // be is the worst possible failure on a financial document.
      expect(PdfExportService.printable('₹1,234.56'), 'Rs 1,234.56');
    });

    test('typographic characters Helvetica lacks get ASCII stand-ins', () {
      // The built-in font cannot draw these either, so a masked account
      // number and a dashed heading would both come out with holes in them.
      expect(PdfExportService.printable('HDFC •••• 4821'), 'HDFC **** 4821');
      expect(PdfExportService.printable('1 – 30 Sep'), '1 - 30 Sep');
      expect(PdfExportService.printable('Report — HDFC'), 'Report - HDFC');
    });

    test('Latin-1 characters pass through untouched', () {
      expect(PdfExportService.printable(r'$100 £50 ¥25'), r'$100 £50 ¥25');
      expect(PdfExportService.printable('Café Noël'), 'Café Noël');
    });

    test('an unrepresentable character becomes a space, not a run-on', () {
      expect(PdfExportService.printable('ab\u{1F600}cd'), 'ab cd');
    });

    test('a rendered PDF contains no undrawable characters', () async {
      // Belt and braces: the real defence is `printable`, but a future report
      // that forgets to call it would fail here rather than in the user's
      // hands.
      final ExportDataset dataset = builder.bankStatement(
        account: accounts.first,
        statement: buildStatement(
          openingBalance: 1000,
          entries: <LedgerEntry>[
            entry(
              id: 'l1',
              direction: LedgerDirection.debit,
              amount: 250,
              date: DateTime(2026, 9, 4),
              transferGroupId: 'g1',
              counterparty: 'a2',
            ),
          ],
        ),
        range: september,
        context: context(),
      );

      for (final String field in <String>[
        dataset.title,
        dataset.subtitle ?? '',
        dataset.periodLabel,
        dataset.footnote ?? '',
        for (final ExportSummaryItem i in dataset.summary) i.value,
        for (final ExportSection s in dataset.sections)
          for (final List<ExportCell> r in s.rows)
            for (final ExportCell c in r) c.text,
      ]) {
        final String safe = PdfExportService.printable(field);
        expect(
          safe.runes.every((int r) => r <= 0xFF),
          isTrue,
          reason: 'not drawable: $field',
        );
      }

      expect((await pdf.render(dataset)).length, greaterThan(500));
    });
  });

  // =================================================================
  group('request validity', () {
    test('a statement needs an account, other reports do not', () {
      final ExportRequest noAccount = ExportRequest(
        type: ExportReportType.bankStatement,
        range: september,
        format: ExportFormat.pdf,
      );
      expect(noAccount.isRunnable, isFalse);

      expect(
        noAccount.copyWith(accountId: 'a1').isRunnable,
        isTrue,
      );
      expect(
        ExportRequest(
          type: ExportReportType.expenses,
          range: september,
          format: ExportFormat.csv,
        ).isRunnable,
        isTrue,
      );
    });

    test('an inverted range is not runnable', () {
      final ExportRequest inverted = ExportRequest(
        type: ExportReportType.expenses,
        range: ExportDateRange(DateTime(2026, 9, 30), DateTime(2026, 9, 1)),
        format: ExportFormat.csv,
      );
      expect(inverted.isRunnable, isFalse);
    });

    test('only the reports that can be filtered say they can be', () {
      expect(ExportReportType.expenses.supportsCategoryFilter, isTrue);
      expect(ExportReportType.categoryReport.supportsCategoryFilter, isTrue);
      expect(ExportReportType.income.supportsCategoryFilter, isFalse);
      expect(ExportReportType.bankStatement.supportsCategoryFilter, isFalse);
      expect(ExportReportType.bankStatement.needsAccount, isTrue);
      expect(ExportReportType.expenses.needsAccount, isFalse);
    });
  });
}
