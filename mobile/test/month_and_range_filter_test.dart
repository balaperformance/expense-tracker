// The dashboard's month (‹ Month Year ▾ ›, with a year-at-a-time picker) and
// the Income list's date range. Nothing here reaches the network: the
// repositories are fakes, and every figure is invented.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/core/utils/date_utils.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/income.dart';
import 'package:expense_tracker/providers/dashboard_provider.dart';
import 'package:expense_tracker/providers/income_provider.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/income_repository.dart';
import 'package:expense_tracker/widgets/date_range_fields.dart';
import 'package:expense_tracker/widgets/month_picker.dart';
import 'package:expense_tracker/widgets/stat_tiles.dart';

final DateTime thisMonth = AppDateUtils.firstDayOf(DateTime.now());

/// Spending by month: whatever month is asked for gets one ₹100 expense,
/// dated in it, and the months asked for are kept.
class MonthlyExpenses extends ExpenseRepository {
  MonthlyExpenses(super.client);

  final List<DateTime> asked = <DateTime>[];
  Map<String, double> totals = <String, double>{};
  ({DateTime from, DateTime toExclusive})? trend;

  @override
  Future<Set<String>> fetchPaidForExpenseIds({required String userId}) async => <String>{};

  @override
  Future<List<Expense>> fetchForMonth({required String userId, required DateTime month}) async {
    asked.add(month);
    return <Expense>[
      Expense(id: 'e-${month.month}', userId: 'u1', amount: 100, expenseDate: month, categoryId: 'food'),
    ];
  }

  @override
  Future<Map<String, double>> fetchMonthlyTotals({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
    Set<String> exclude = const <String>{},
  }) async {
    trend = (from: from, toExclusive: toExclusive);
    return totals;
  }

  @override
  Future<DateTime?> fetchEarliestDate({required String userId}) async => DateTime(2024, 3, 9);
}

class MonthlyIncome extends IncomeRepository {
  MonthlyIncome(super.client);

  @override
  Future<List<Income>> fetchForMonth({required String userId, required DateTime month}) async =>
      <Income>[Income(id: 'i-${month.month}', userId: 'u1', amount: 5000, incomeDate: month)];

  @override
  Future<Map<String, double>> fetchMonthlyTotals({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
  }) async =>
      <String, double>{};

  @override
  Future<DateTime?> fetchEarliestDate({required String userId}) async => DateTime(2025, 1, 2);
}

/// Income for the range tests: the page and range reads are recorded.
class RangedIncome extends IncomeRepository {
  RangedIncome(super.client);

  ({DateTime? from, DateTime? to, String search})? lastPage;
  ({DateTime from, DateTime toExclusive})? lastRange;

  static final List<Income> rows = <Income>[
    Income(id: 'salary', userId: 'u1', amount: 50000, incomeDate: DateTime(2026, 10, 1), source: 'Salary'),
    Income(id: 'friend', userId: 'u1', amount: 1500, incomeDate: DateTime(2026, 10, 3), source: 'Arun', isPersonal: false),
    Income(id: 'gig', userId: 'u1', amount: 7000, incomeDate: DateTime(2026, 10, 9), source: 'Freelance'),
  ];

  @override
  Future<List<Income>> fetchPage({
    required String userId,
    required int page,
    String search = '',
    DateTime? from,
    DateTime? to,
    int pageSize = 20,
  }) async {
    lastPage = (from: from, to: to, search: search);
    return rows;
  }

  @override
  Future<List<Income>> fetchRange({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
    int limit = 0,
  }) async {
    lastRange = (from: from, toExclusive: toExclusive);
    return rows;
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late SupabaseClient client;

  setUp(() {
    client = SupabaseClient('http://localhost:54321', 'test-anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false));
  });

  group('dashboard month', () {
    test('starts on the current month', () {
      final DashboardProvider dashboard = DashboardProvider(expenses: MonthlyExpenses(client), income: MonthlyIncome(client));
      expect(dashboard.month, thisMonth);
      expect(dashboard.isCurrentMonth, isTrue);
    });

    test('every figure is for the chosen month, and the trend ends with it', () async {
      final MonthlyExpenses expenses = MonthlyExpenses(client);
      final DashboardProvider dashboard = DashboardProvider(expenses: expenses, income: MonthlyIncome(client));
      final DateTime march = DateTime(2025, 3, 1);

      dashboard.setMonth(DateTime(2025, 3, 17));
      await dashboard.load(userId: 'u1', categories: const <ExpenseCategory>[]);

      expect(dashboard.month, march);
      expect(dashboard.isCurrentMonth, isFalse);
      expect(expenses.asked.single, march);
      expect(dashboard.data!.month, march);
      expect(dashboard.data!.totalExpense, 100);
      expect(dashboard.data!.totalIncome, 5000);
      expect(dashboard.data!.trend.last.month, march);
      expect(dashboard.data!.trend.first.month, DateTime(2024, 10, 1));
      expect(expenses.trend!.toExclusive, DateTime(2025, 4, 1));
    });

    test('changing month reloads; the same month again does not', () async {
      final MonthlyExpenses expenses = MonthlyExpenses(client);
      final DashboardProvider dashboard = DashboardProvider(expenses: expenses, income: MonthlyIncome(client));
      await dashboard.load(userId: 'u1', categories: const <ExpenseCategory>[]);
      dashboard.setMonth(AppDateUtils.addMonths(thisMonth, -1));
      await dashboard.load(userId: 'u1', categories: const <ExpenseCategory>[]);
      dashboard.setMonth(AppDateUtils.addMonths(thisMonth, -1));
      await dashboard.load(userId: 'u1', categories: const <ExpenseCategory>[]);
      expect(expenses.asked, <DateTime>[thisMonth, AppDateUtils.addMonths(thisMonth, -1)]);
    });

    test('a month after the current one is never chosen', () {
      final DashboardProvider dashboard = DashboardProvider(expenses: MonthlyExpenses(client), income: MonthlyIncome(client));
      dashboard.setMonth(AppDateUtils.addMonths(thisMonth, 3));
      expect(dashboard.month, thisMonth);
    });

    test('the picker starts at the first month with any data', () async {
      final DashboardProvider dashboard = DashboardProvider(expenses: MonthlyExpenses(client), income: MonthlyIncome(client));
      expect(await dashboard.earliestMonth(userId: 'u1'), DateTime(2024, 3, 1));
    });

    test('reset goes back to the current month', () {
      final DashboardProvider dashboard = DashboardProvider(expenses: MonthlyExpenses(client), income: MonthlyIncome(client));
      dashboard.setMonth(DateTime(2025, 1, 1));
      dashboard.reset();
      expect(dashboard.month, thisMonth);
    });
  });

  group('month switcher', () {
    Future<List<DateTime>> pump(WidgetTester tester, DateTime month) async {
      final List<DateTime> changes = <DateTime>[];
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: MonthSwitcher(
            month: month,
            onChanged: changes.add,
            earliest: () async => DateTime(2020, 6, 1),
          ),
        ),
      ));
      return changes;
    }

    testWidgets('steps back; Next is off on the current month', (WidgetTester tester) async {
      final List<DateTime> changes = await pump(tester, thisMonth);
      expect(find.text('Today'), findsNothing);
      await tester.tap(find.byTooltip('Next month'));
      expect(changes, isEmpty);
      await tester.tap(find.byTooltip('Previous month'));
      expect(changes, <DateTime>[AppDateUtils.addMonths(thisMonth, -1)]);
    });

    testWidgets('a past month steps forward, and Today returns to now', (WidgetTester tester) async {
      final DateTime past = AppDateUtils.addMonths(thisMonth, -4);
      final List<DateTime> changes = await pump(tester, past);
      await tester.tap(find.byTooltip('Next month'));
      await tester.tap(find.text('Today'));
      expect(changes, <DateTime>[AppDateUtils.addMonths(past, 1), thisMonth]);
    });

    testWidgets('the label opens a year of months; picking one chooses it', (WidgetTester tester) async {
      final List<DateTime> changes = await pump(tester, thisMonth);
      await tester.tap(find.bySemanticsLabel(RegExp('Choose month')));
      await tester.pumpAndSettle();

      expect(find.text('Choose month'), findsOneWidget);
      expect(find.text('${thisMonth.year}'), findsOneWidget);
      // Back a year, then January.
      await tester.tap(find.byTooltip('Previous year'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Jan'));
      await tester.pumpAndSettle();
      expect(changes, <DateTime>[DateTime(thisMonth.year - 1, 1, 1)]);
    });
  });

  group('month picker', () {
    Future<DateTime?> open(WidgetTester tester, {required DateTime selected, DateTime? earliest}) async {
      DateTime? picked;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                picked = await showMonthPickerSheet(context: context, selected: selected, earliest: earliest);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return picked;
    }

    testWidgets('months after this one, and before the first data, cannot be picked', (WidgetTester tester) async {
      await open(tester, selected: DateTime(2025, 2, 1), earliest: DateTime(2025, 2, 1));
      // 2025: January is before the data; February is the selection.
      expect(find.text('2025'), findsOneWidget);
      await tester.tap(find.text('Jan'));
      await tester.pumpAndSettle();
      expect(find.text('Choose month'), findsOneWidget, reason: 'nothing was picked');
      // The year before the data is not offered at all.
      final IconButton back = tester.widget(find.widgetWithIcon(IconButton, Icons.chevron_left_rounded));
      expect(back.onPressed, isNull);
    });

    testWidgets('the current year stops at the current month', (WidgetTester tester) async {
      if (thisMonth.month == 12) return; // nothing after December to check
      await open(tester, selected: thisMonth);
      final IconButton forward = tester.widget(find.widgetWithIcon(IconButton, Icons.chevron_right_rounded));
      expect(forward.onPressed, isNull, reason: 'no year after this one');
    });
  });

  group('hero for a past month', () {
    testWidgets('says the figures are the whole month', (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(
          body: BalanceCard(
            income: 5000,
            expense: 100,
            currency: 'INR',
            monthLabel: 'Mar',
            bankTotal: 1000,
            currentMonth: false,
          ),
        ),
      ));
      expect(find.text('For the month'), findsOneWidget);
      expect(find.text('Spent'), findsOneWidget);
      expect(find.text('So far this month'), findsNothing);
    });

    testWidgets('the current month reads as before', (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(
          body: BalanceCard(income: 5000, expense: 100, currency: 'INR', monthLabel: 'Nov', bankTotal: 1000),
        ),
      ));
      expect(find.text('So far this month'), findsOneWidget);
      expect(find.text('Spent this month'), findsOneWidget);
    });
  });

  group('income date range', () {
    test('narrows the list and totals the whole range, leaving out someone else\'s money', () async {
      final RangedIncome repo = RangedIncome(client);
      final IncomeProvider income = IncomeProvider(repo);
      income.attachUser('u1');
      await settle();
      expect(income.hasRange, isFalse);
      expect(repo.lastPage!.from, isNull);

      await income.setRange(DateTime(2026, 10, 1), DateTime(2026, 10, 31));
      await settle();

      expect(income.hasRange, isTrue);
      expect(repo.lastPage!.from, DateTime(2026, 10, 1));
      expect(repo.lastPage!.to, DateTime(2026, 10, 31));
      expect(repo.lastRange!.toExclusive, DateTime(2026, 11, 1));
      expect(income.rangeSummary!.total, 57000);
      expect(income.rangeSummary!.count, 3);
    });

    test('the total follows the search too', () async {
      final RangedIncome repo = RangedIncome(client);
      final IncomeProvider income = IncomeProvider(repo);
      income.attachUser('u1');
      await settle();
      await income.setRange(DateTime(2026, 10, 1), DateTime(2026, 10, 31));
      income.setSearch('free');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await settle();
      expect(repo.lastPage!.search, 'free');
      expect(income.rangeSummary!.total, 7000);
      expect(income.rangeSummary!.count, 1);
    });

    test('clearing shows everything again and drops the total', () async {
      final RangedIncome repo = RangedIncome(client);
      final IncomeProvider income = IncomeProvider(repo);
      income.attachUser('u1');
      await settle();
      await income.setRange(DateTime(2026, 10, 1), null);
      await settle();
      expect(income.rangeSummary, isNotNull);
      await income.clearRange();
      expect(income.hasRange, isFalse);
      expect(income.rangeSummary, isNull);
      expect(repo.lastPage!.from, isNull);
      expect(repo.lastPage!.to, isNull);
    });

    test('describes the range', () {
      expect(dateRangeLabel(DateTime(2026, 10, 1), DateTime(2026, 10, 31)), '1 Oct – 31 Oct 2026');
      expect(dateRangeLabel(DateTime(2025, 12, 20), DateTime(2026, 1, 5)), '20 Dec 2025 – 5 Jan 2026');
      expect(dateRangeLabel(DateTime(2026, 10, 1), null), 'From 1 Oct 2026');
      expect(dateRangeLabel(null, DateTime(2026, 10, 31)), 'Until 31 Oct 2026');
      expect(dateRangeLabel(null, null), isNull);
    });
  });
}
