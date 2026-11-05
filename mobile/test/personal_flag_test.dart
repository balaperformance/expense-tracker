// Personal and non-personal entries (migration 019): an income or expense can
// be someone else's money — a friend's money received, or spent on their
// behalf. It stays in the lists, marked, and every personal figure leaves it
// out; account balances still count it, since the money really moved.
//
// Rows read before the migration have no `is_personal` column and are the
// user's own, so nothing that exists today changes. Nothing here reaches the
// network: the repositories are fakes, and every figure is invented.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/analytics.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/income.dart';
import 'package:expense_tracker/providers/dashboard_provider.dart';
import 'package:expense_tracker/providers/reports_provider.dart';
import 'package:expense_tracker/repositories/export_repository.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/income_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/services/export/export_models.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';
import 'package:expense_tracker/widgets/stat_tiles.dart';
import 'package:expense_tracker/widgets/transaction_tile.dart';

final DateTime day = DateTime(2026, 10, 12);

Expense spent(String id, double amount, {bool personal = true, String? account}) => Expense(
      id: id,
      userId: 'u1',
      amount: amount,
      expenseDate: day,
      categoryId: 'food',
      bankAccountId: account,
      description: id,
      isPersonal: personal,
    );

Income received(String id, double amount, {bool personal = true, String? account}) => Income(
      id: id,
      userId: 'u1',
      amount: amount,
      incomeDate: day,
      source: id,
      bankAccountId: account,
      isPersonal: personal,
    );

/// The month: ₹300 of the user's own spending, ₹1,000 bought for a friend
/// with their money, ₹200 paid for someone (owed back).
final List<Expense> monthExpenses = <Expense>[
  spent('own', 300),
  spent('gift', 1000, personal: false),
  spent('lunch', 200),
];

/// ₹50,000 salary and ₹1,000 a friend sent to buy the gift.
final List<Income> monthIncome = <Income>[
  received('salary', 50000),
  received('friend', 1000, personal: false),
];

class Expenses extends ExpenseRepository {
  Expenses(super.client);

  @override
  Future<Set<String>> fetchPaidForExpenseIds({required String userId}) async => <String>{'lunch'};

  @override
  Future<List<Expense>> fetchForMonth({required String userId, required DateTime month}) async =>
      monthExpenses;

  @override
  Future<Map<String, double>> fetchMonthlyTotals({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
    Set<String> exclude = const <String>{},
  }) async =>
      <String, double>{};

  @override
  Future<List<Expense>> fetchRange({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
    Set<String> categoryIds = const <String>{},
    int limit = 0,
  }) async =>
      monthExpenses;
}

class Received extends IncomeRepository {
  Received(super.client);

  @override
  Future<List<Income>> fetchForMonth({required String userId, required DateTime month}) async =>
      monthIncome;

  @override
  Future<Map<String, double>> fetchMonthlyTotals({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
  }) async =>
      <String, double>{};

  @override
  Future<List<Income>> fetchRange({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
    int limit = 0,
  }) async =>
      monthIncome;
}

void main() {
  late SupabaseClient client;

  setUp(() {
    client = SupabaseClient('http://localhost:54321', 'test-anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    SchemaCapabilities.debugReset();
    SchemaCapabilities.debugOverride(treatments: true);
  });
  tearDown(SchemaCapabilities.debugReset);

  group('rows', () {
    Map<String, dynamic> expenseRow([Map<String, dynamic> extra = const <String, dynamic>{}]) =>
        <String, dynamic>{
          'id': 'e1',
          'user_id': 'u1',
          'amount': 10,
          'expense_date': '2026-10-12',
          ...extra,
        };
    Map<String, dynamic> incomeRow([Map<String, dynamic> extra = const <String, dynamic>{}]) =>
        <String, dynamic>{
          'id': 'i1',
          'user_id': 'u1',
          'amount': 10,
          'income_date': '2026-10-12',
          ...extra,
        };

    test('are personal unless the column says false', () {
      expect(Expense.fromMap(expenseRow()).isPersonal, isTrue, reason: 'before 019');
      expect(Expense.fromMap(expenseRow(<String, dynamic>{'is_personal': null})).isPersonal, isTrue);
      expect(Expense.fromMap(expenseRow(<String, dynamic>{'is_personal': true})).isPersonal, isTrue);
      expect(Expense.fromMap(expenseRow(<String, dynamic>{'is_personal': false})).isPersonal, isFalse);
      expect(Income.fromMap(incomeRow()).isPersonal, isTrue, reason: 'before 019');
      expect(Income.fromMap(incomeRow(<String, dynamic>{'is_personal': false})).isPersonal, isFalse);
    });

    test('write the column only once migration 019 is in place', () {
      final Expense gift = spent('gift', 1000, personal: false);
      expect(gift.toInsertMap(includeMerchant: true, includeBankLink: true), isNot(contains('is_personal')));
      expect(gift.toUpdateMap(includeMerchant: true, includeBankLink: true), isNot(contains('is_personal')));
      expect(
        gift.toInsertMap(includeMerchant: true, includeBankLink: true, includePersonal: true)['is_personal'],
        isFalse,
      );
      expect(
        gift.toUpdateMap(includeMerchant: true, includeBankLink: true, includePersonal: true)['is_personal'],
        isFalse,
      );
      expect(gift.copyWith(amount: 5).isPersonal, isFalse);

      final Income friend = received('friend', 1000, personal: false);
      expect(friend.toInsertMap(includeBankLink: true), isNot(contains('is_personal')));
      expect(friend.toInsertMap(includeBankLink: true, includePersonal: true)['is_personal'], isFalse);
      expect(friend.toUpdateMap(includeBankLink: true, includePersonal: true)['is_personal'], isFalse);
      expect(friend.copyWith(amount: 5).isPersonal, isFalse);
    });
  });

  group('personal figures', () {
    test('spending leaves out paid-for and non-personal expenses; income leaves out non-personal', () {
      expect(personalSpending(monthExpenses, <String>{'lunch'}).map((Expense e) => e.id), <String>['own']);
      expect(personalSpending(monthExpenses, const <String>{}).map((Expense e) => e.id),
          <String>['own', 'lunch']);
      expect(personalIncome(monthIncome).map((Income i) => i.id), <String>['salary']);
    });

    test('Home counts only the user\'s own money, but still lists the purchase', () async {
      final DashboardProvider dashboard = DashboardProvider(expenses: Expenses(client), income: Received(client));
      await dashboard.load(userId: 'u1', categories: const <ExpenseCategory>[]);

      final DashboardData data = dashboard.data!;
      expect(data.totalExpense, 300);
      expect(data.totalIncome, 50000);
      expect(data.categoryBreakdown.single.total, 300);
      expect(data.recentExpenses.map((Expense e) => e.id), <String>['own', 'gift'],
          reason: 'listed, marked; the paid-for purchase stays out as before');
    });

    test('reports count only the user\'s own money', () async {
      final ReportsProvider reports = ReportsProvider(expenses: Expenses(client), income: Received(client));
      await reports.load(userId: 'u1', categories: const <ExpenseCategory>[]);

      final ReportData report = reports.report!;
      expect(report.totalExpense, 300);
      expect(report.totalIncome, 50000);
      expect(report.transactionCount, 1);
    });

    test('exports leave someone else\'s money out, and say so', () async {
      final ExportRepository exports = ExportRepository(
        expenses: Expenses(client),
        income: Received(client),
        ledger: LedgerRepository(client),
      );
      ExportRequest request(ExportReportType type) => ExportRequest(
            type: type,
            range: ExportDateRange.month(day),
            format: ExportFormat.csv,
          );

      final ExportSource spending = await exports.load(userId: 'u1', request: request(ExportReportType.expenses));
      expect(spending.expenses.map((Expense e) => e.id), <String>['own']);
      expect(spending.paidForLeftOut, 1);
      expect(spending.othersLeftOut, 1);

      final ExportSource income = await exports.load(userId: 'u1', request: request(ExportReportType.income));
      expect(income.income.map((Income i) => i.id), <String>['salary']);
      expect(income.othersLeftOut, 1);

      final ExportSource both = await exports.load(userId: 'u1', request: request(ExportReportType.incomeVsExpense));
      expect(both.expenses.map((Expense e) => e.id), <String>['own']);
      expect(both.income.map((Income i) => i.id), <String>['salary']);
    });
  });

  group('available balance', () {
    testWidgets('is the actual money in the accounts, with nothing set aside', (WidgetTester tester) async {
      // Non-personal income and expenses move the ledger like any other, so
      // the accounts' total is shown as it is.
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(
          body: SingleChildScrollView(
            child: BalanceCard(
              income: 50000,
              expense: 300,
              currency: 'INR',
              monthLabel: 'Oct',
              bankTotal: 10000,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('₹10,000.00'), findsOneWidget);
      expect(find.textContaining('for others'), findsNothing);
    });
  });

  group('lists', () {
    Future<void> pumpRows(WidgetTester tester, List<Widget> rows) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: Column(children: rows)),
      ));
      await tester.pumpAndSettle();
    }

    MoneyText amountOf(WidgetTester tester, String title) => tester.widget<MoneyText>(find.descendant(
          of: find.ancestor(of: find.text(title), matching: find.byType(TransactionRow)),
          matching: find.byType(MoneyText),
        ));

    testWidgets('mark someone else\'s money, in a neutral colour', (WidgetTester tester) async {
      await pumpRows(tester, <Widget>[
        ExpenseTile(expense: spent('own', 300), currency: 'INR'),
        ExpenseTile(expense: spent('gift', 1000, personal: false), currency: 'INR'),
        IncomeTile(income: received('salary', 50000), currency: 'INR'),
        IncomeTile(income: received('friend', 1000, personal: false), currency: 'INR'),
      ]);
      expect(find.text(nonPersonalBadge), findsNWidgets(2));
      expect(amountOf(tester, 'own').tone, AmountTone.negative);
      expect(amountOf(tester, 'gift').tone, AmountTone.neutral);
      expect(amountOf(tester, 'salary').tone, AmountTone.positive);
      expect(amountOf(tester, 'friend').tone, AmountTone.neutral);
      expect(tester.takeException(), isNull);
    });
  });
}
