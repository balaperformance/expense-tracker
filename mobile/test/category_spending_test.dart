// Category-wise monthly spending: the screens behind the dashboard's
// "Where it went" card. The figures must be the dashboard's own, per month.
//
// Nothing here reaches the network: the repositories are fakes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/core/utils/formatters.dart';
import 'package:expense_tracker/models/analytics.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/income.dart';
import 'package:expense_tracker/providers/auth_provider.dart';
import 'package:expense_tracker/providers/category_provider.dart';
import 'package:expense_tracker/providers/category_spending_provider.dart';
import 'package:expense_tracker/providers/dashboard_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/repositories/auth_repository.dart';
import 'package:expense_tracker/repositories/category_repository.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/income_repository.dart';
import 'package:expense_tracker/repositories/profile_repository.dart';
import 'package:expense_tracker/screens/dashboard/dashboard_screen.dart';
import 'package:expense_tracker/screens/reports/category_spending_screen.dart';
import 'package:expense_tracker/services/preferences_service.dart';
import 'package:expense_tracker/widgets/charts/category_breakdown.dart';

const List<ExpenseCategory> categories = <ExpenseCategory>[
  ExpenseCategory(id: 'food', userId: 'u1', name: 'Food', icon: 'restaurant', color: '#FF7043'),
  ExpenseCategory(id: 'fuel', userId: 'u1', name: 'Fuel', icon: 'local_gas_station', color: '#42A5F5'),
  ExpenseCategory(id: 'home', userId: 'u1', name: 'Groceries', icon: 'shopping_cart', color: '#66BB6A'),
];

final DateTime thisMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);
final DateTime lastMonth = DateTime(thisMonth.year, thisMonth.month - 1, 1);

Expense expense(String id, double amount, DateTime day, String? categoryId, {bool personal = true}) => Expense(
      id: id,
      userId: 'u1',
      amount: amount,
      expenseDate: day,
      categoryId: categoryId,
      description: 'Expense $id',
      isPersonal: personal,
      category: categories.where((ExpenseCategory c) => c.id == categoryId).firstOrNull,
    );

/// This month: Food 300 (two rows), Fuel 200, one uncategorised 100, plus a
/// purchase paid for someone (p1) and a non-personal one — neither counts.
/// Last month: Food 50 only.
final Map<DateTime, List<Expense>> byMonth = <DateTime, List<Expense>>{
  thisMonth: <Expense>[
    expense('f1', 100, thisMonth, 'food'),
    expense('f2', 200, DateTime(thisMonth.year, thisMonth.month, 2), 'food'),
    expense('g1', 200, thisMonth, 'fuel'),
    expense('u1', 100, thisMonth, null),
    expense('p1', 999, thisMonth, 'food'),
    expense('n1', 777, thisMonth, 'fuel', personal: false),
  ],
  lastMonth: <Expense>[expense('old', 50, lastMonth, 'food')],
};

class Expenses extends ExpenseRepository {
  Expenses(super.client);

  int monthReads = 0;

  @override
  Future<Set<String>> fetchPaidForExpenseIds({required String userId}) async => <String>{'p1'};

  @override
  Future<List<Expense>> fetchForMonth({required String userId, required DateTime month}) async {
    monthReads++;
    return byMonth[DateTime(month.year, month.month, 1)] ?? const <Expense>[];
  }

  @override
  Future<DateTime?> fetchEarliestDate({required String userId}) async => lastMonth;

  @override
  Future<Map<String, double>> fetchMonthlyTotals({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
    Set<String> exclude = const <String>{},
  }) async =>
      <String, double>{};
}

class NoIncome extends IncomeRepository {
  NoIncome(super.client);

  @override
  Future<List<Income>> fetchForMonth({required String userId, required DateTime month}) async => const <Income>[];

  @override
  Future<Map<String, double>> fetchMonthlyTotals({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
  }) async =>
      <String, double>{};
}

class FakeAuth extends AuthProvider {
  FakeAuth() : super(AuthRepository(GoTrueClient(autoRefreshToken: false)));

  @override
  String? get userId => 'u1';
}

class FakeCategories extends CategoryProvider {
  FakeCategories(SupabaseClient client) : super(CategoryRepository(client));

  @override
  List<ExpenseCategory> get categories => _categories;
}

const List<ExpenseCategory> _categories = categories;

void main() {
  late SupabaseClient client;
  late PreferencesService preferences;

  setUp(() async {
    client = SupabaseClient('http://localhost:54321', 'test-anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    preferences = await PreferencesService.create();
  });

  group('the breakdown behind the screens', () {
    test('each category carries its count and its expenses, newest first', () {
      final List<CategorySpend> breakdown = buildCategoryBreakdown(
        personalSpending(byMonth[thisMonth]!, <String>{'p1'}),
        categories,
      );
      final CategorySpend food = breakdown.firstWhere((CategorySpend c) => c.categoryId == 'food');
      expect(food.total, 300);
      expect(food.transactionCount, 2);
      expect(food.expenses.map((Expense e) => e.id), <String>['f2', 'f1']);
      // Every category, largest first; uncategorised kept as its own group.
      expect(breakdown.map((CategorySpend c) => c.name), <String>['Food', 'Fuel', 'Uncategorised']);
      expect(breakdown.last.categoryId, isNull);
    });

    test('a month adds up, and the shares are of its total', () {
      final CategoryMonthSpending month = buildCategoryMonthSpending(
        thisMonth,
        personalSpending(byMonth[thisMonth]!, <String>{'p1'}),
        categories,
      );
      expect(month.total, 600);
      expect(month.category('food')!.shareOf(month.total), 0.5);
      expect(categorySpendDetail(month.category('food')!, 0.5), '2 expenses · 50%');
      expect(categorySpendDetail(month.category('fuel')!, 1 / 3), '1 expense · 33%');
      expect(month.category(null)!.total, 100);
      expect(month.category('home'), isNull);
    });

    test('the provider gives the dashboard\'s own figures for the same month', () async {
      final DashboardProvider dashboard = DashboardProvider(expenses: Expenses(client), income: NoIncome(client));
      await dashboard.load(userId: 'u1', categories: categories);
      final CategorySpendingProvider spending = CategorySpendingProvider(expenses: Expenses(client));
      await spending.load(userId: 'u1', month: thisMonth, categories: categories);

      final CategoryMonthSpending month = spending.spendingFor(thisMonth)!;
      expect(month.total, dashboard.data!.totalExpense);
      expect(
        month.breakdown.map((CategorySpend c) => '${c.name}=${c.total}'),
        dashboard.data!.categoryBreakdown.map((CategorySpend c) => '${c.name}=${c.total}'),
      );
      expect(spending.earliest, lastMonth);
    });

    test('a month is read once until something changes', () async {
      final Expenses repo = Expenses(client);
      final CategorySpendingProvider spending = CategorySpendingProvider(expenses: repo);
      await spending.load(userId: 'u1', month: thisMonth, categories: categories);
      await spending.load(userId: 'u1', month: thisMonth, categories: categories);
      expect(repo.monthReads, 1);
      spending.invalidate();
      await spending.load(userId: 'u1', month: thisMonth, categories: categories);
      expect(repo.monthReads, 2);
    });
  });

  group('screens', () {
    Future<void> pump(WidgetTester tester, Widget home) async {
      tester.view.physicalSize = const Size(720, 1440);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: <ChangeNotifierProvider<dynamic>>[
            ChangeNotifierProvider<AuthProvider>.value(value: FakeAuth()),
            ChangeNotifierProvider<CategoryProvider>.value(value: FakeCategories(client)),
            ChangeNotifierProvider<SettingsProvider>(
              create: (_) => SettingsProvider(repository: ProfileRepository(client), preferences: preferences),
            ),
            ChangeNotifierProvider<CategorySpendingProvider>(
              create: (_) => CategorySpendingProvider(expenses: Expenses(client)),
            ),
          ],
          child: MaterialApp(theme: AppTheme.light, home: home),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('every category of the month, with counts and shares, at 360 dp', (WidgetTester tester) async {
      await pump(tester, CategorySpendingScreen(month: thisMonth));

      expect(find.text('Spending by category'), findsOneWidget);
      expect(find.text(Formatters.monthYear(thisMonth)), findsOneWidget);
      expect(find.text('Total spending'), findsOneWidget);
      expect(find.text('2 expenses · 50%'), findsOneWidget);
      expect(find.text('1 expense · 33%'), findsOneWidget);
      expect(find.text('1 expense · 17%'), findsOneWidget);
      // The current month is the last one: Next is off; Previous is on.
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_right_rounded)).onPressed, isNull);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();
      expect(find.text(Formatters.monthYear(lastMonth)), findsOneWidget);
      expect(find.text('1 expense · 100%'), findsOneWidget);
      // Next is back on, and "Today" returns to the current month — the
      // dashboard's own month switcher.
      await tester.tap(find.text('Today'));
      await tester.pumpAndSettle();
      expect(find.text('2 expenses · 50%'), findsOneWidget);
    });

    testWidgets('a category opens its expenses; the month switcher keeps the category', (WidgetTester tester) async {
      await pump(tester, CategorySpendingScreen(month: thisMonth));

      await tester.tap(find.text('Fuel'));
      await tester.pumpAndSettle();
      expect(find.byType(CategoryTransactionsScreen), findsOneWidget);
      expect(find.text('Expense g1'), findsOneWidget);
      // Only what counts: the non-personal Fuel purchase is not listed.
      expect(find.text('Expense n1'), findsNothing);
      expect(find.textContaining('${Formatters.monthYear(thisMonth)} · '), findsOneWidget);

      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();
      expect(find.text('No Fuel expenses in ${Formatters.monthYear(lastMonth)}'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a month with nothing says so', (WidgetTester tester) async {
      final DateTime empty = DateTime(thisMonth.year, thisMonth.month - 3, 1);
      await pump(tester, CategorySpendingScreen(month: empty));
      expect(find.text('No expenses in ${Formatters.monthYear(empty)}'), findsOneWidget);
      expect(find.text('Expenses you record this month show here by category.'), findsOneWidget);
    });

    testWidgets('the dashboard\'s "Where it went" card opens the category screen', (WidgetTester tester) async {
      final DashboardData data = DashboardData(
        month: thisMonth,
        totalExpense: 600,
        totalIncome: 0,
        recentExpenses: const <Expense>[],
        categoryBreakdown:
            buildCategoryBreakdown(personalSpending(byMonth[thisMonth]!, <String>{'p1'}), categories),
        trend: const <MonthlyPoint>[],
      );
      await pump(
        tester,
        Builder(
          builder: (BuildContext context) => Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(14),
              children: <Widget>[
                DashboardChartsCarousel(
                  data: data,
                  currency: 'INR',
                  onOpenCategories: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => CategorySpendingScreen(month: data.month)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('See all categories'));
      await tester.pumpAndSettle();
      expect(find.byType(CategorySpendingScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      // The card itself is a way in too.
      await tester.tap(find.byType(CategoryDonut));
      await tester.pumpAndSettle();
      expect(find.byType(CategorySpendingScreen), findsOneWidget);
    });
  });
}
