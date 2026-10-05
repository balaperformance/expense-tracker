// Reports › Spending on the phone, rendered at the Armor X8's real size
// (360 x 720 dp) and at 320 x 640 dp. The insights engine is a scripted fake
// answering with canned views, and the repositories return nothing — so this
// checks what the tab shows and that it lays out without an overflow, and that
// its sheets hand the right range and filter back to the engine. The analysis
// itself is the web's code, tested there. Nothing touches a network or a
// database, and every figure is invented.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/core/utils/date_utils.dart';
import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/models/credit_card.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/payment_method.dart';
import 'package:expense_tracker/models/tag.dart';
import 'package:expense_tracker/providers/credit_card_provider.dart';
import 'package:expense_tracker/providers/insights_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/repositories/credit_card_repository.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/income_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/repositories/profile_repository.dart';
import 'package:expense_tracker/repositories/tag_repository.dart';
import 'package:expense_tracker/screens/reports/spending_sheets.dart';
import 'package:expense_tracker/screens/reports/spending_view.dart';
import 'package:expense_tracker/services/preferences_service.dart';
import 'package:expense_tracker/services/statement_import/statement_engine.dart';

/// Answers engine calls from a script and records each one.
class FakeEngine implements StatementEngine {
  FakeEngine(this.handlers);

  final Map<String, Object? Function(Map<String, Object?> args)> handlers;
  final List<(String, Map<String, Object?>)> calls = <(String, Map<String, Object?>)>[];

  @override
  Future<PickedStatementFile?> pickFile() async => null;

  @override
  Future<Object?> call(String name, Map<String, Object?> args) async {
    calls.add((name, args));
    final Object? Function(Map<String, Object?>)? handler = handlers[name];
    if (handler == null) throw StateError('unexpected call $name');
    return handler(args);
  }

  @override
  Future<void> release(String token) async {}

  List<Map<String, Object?>> argsOf(String name) => <Map<String, Object?>>[
        for (final (String n, Map<String, Object?> a) in calls)
          if (n == name) a,
      ];
}

class QuietExpenses extends ExpenseRepository {
  QuietExpenses(super.client);

  @override
  Future<List<Map<String, dynamic>>> fetchHistoryRows({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
  }) async =>
      const <Map<String, dynamic>>[];

  @override
  Future<Set<String>> fetchPaidForExpenseIds({required String userId}) async => <String>{};
}

class QuietIncome extends IncomeRepository {
  QuietIncome(super.client);

  @override
  Future<Map<String, double>> fetchMonthlyTotals({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
  }) async =>
      const <String, double>{};
}

class QuietTags extends TagRepository {
  const QuietTags(super.client);

  @override
  Future<List<Tag>> fetchTags(String userId) async => const <Tag>[];

  @override
  Future<Map<String, List<String>>> fetchExpenseTagLinks(String userId) async => const <String, List<String>>{};
}

class QuietCards extends CreditCardRepository {
  QuietCards(super.client)
      : super(expenses: ExpenseRepository(client), ledger: LedgerRepository(client));

  @override
  Future<List<CardTransaction>> fetchCharges({required String userId, required DateTime from}) async =>
      const <CardTransaction>[];
}

String _day(DateTime d) => AppDateUtils.toDateString(d);

Map<String, Object?> _period(DateTime start, DateTime end, String label, String short) =>
    <String, Object?>{'start': _day(start), 'end': _day(end), 'label': label, 'short': short};

List<String> _ids(String prefix, int n) => <String>[for (int i = 1; i <= n; i++) '$prefix$i'];

Map<String, Object?> _overview() {
  final DateTime today = AppDateUtils.today();
  final DateTime since = AppDateUtils.addMonths(today, -25);
  return <String, Object?>{
    'session': 's1',
    'today': _day(today),
    'since': _day(since),
    'historyStart': _day(since),
    'enoughData': true,
    'highlights': const <Object?>[],
    'recurring': const <Object?>[],
    'recurringMonthly': 0,
    'runningCount': 0,
    'savings': const <Object?>[],
    'unusual': const <Object?>[],
    'changes': <String, Object?>{
      'current': _period(AppDateUtils.firstDayOf(today), today, 'This month', 'This month'),
      'previous': _period(AppDateUtils.addMonths(today, -1), AppDateUtils.firstDayOf(today), 'Last month', 'Last month'),
      'compared': true,
      'headline': '',
      'reasons': const <Object?>[],
      'currentCount': 0,
      'ids': const <Object?>[],
      'movers': const <Object?>[],
    },
    'presets': <Map<String, String>>[
      for (final ({String value, String label}) p in spendingPeriodPresets) <String, String>{'value': p.value, 'label': p.label},
    ],
    'showCards': false,
  };
}

Map<String, Object?> _analytics() {
  final DateTime today = AppDateUtils.today();
  return <String, Object?>{'range': _period(AppDateUtils.addMonths(today, -5), today, 'Last 6 months', 'May–Oct')};
}

/// A canned Spending view. [tagged] is the slice for #family alone; [empty]
/// has nothing in it; [buckets] monthly bars, or weekly ones with [weekly].
Map<String, Object?> _spending({
  bool tagged = false,
  bool empty = false,
  int buckets = 3,
  bool weekly = false,
  bool tags = true,
  int merchants = 20,
}) {
  final DateTime today = AppDateUtils.today();
  final DateTime start = weekly ? AppDateUtils.firstDayOf(today) : AppDateUtils.addMonths(today, -(buckets - 1));
  final int count = empty ? 0 : (tagged ? 3 : 12);
  final double total = empty ? 0 : (tagged ? 4200 : 12400);
  final List<Map<String, Object?>> trend = <Map<String, Object?>>[
    for (int i = 0; i < buckets; i++)
      <String, Object?>{
        'start': _day(weekly ? start.add(Duration(days: i * 7)) : AppDateUtils.addMonths(start, i)),
        'end': _day(i == buckets - 1
            ? today
            : (weekly
                ? start.add(Duration(days: i * 7 + 6))
                : AppDateUtils.addMonths(start, i + 1).subtract(const Duration(days: 1)))),
        'label': weekly ? 'W${i + 1}' : 'M${i + 1}',
        'total': empty ? 0 : total / buckets,
        'count': empty ? 0 : (i == buckets - 1 ? 2 : 3),
        'ids': empty ? const <String>[] : _ids('b$i-', 2),
      },
  ];
  Map<String, Object?> group(String key, String label, double amount, int n, {String? color}) => <String, Object?>{
        'key': key,
        'label': label,
        'total': amount,
        'count': n,
        'share': total == 0 ? 0 : amount / total,
        'ids': _ids('$key-', n),
        if (color != null) 'color': color,
      };
  return <String, Object?>{
    'period': _period(start, today, weekly ? 'This month so far' : '1 Aug – 5 Oct 2026', weekly ? 'October' : 'Aug–Oct'),
    'previous': _period(AppDateUtils.addMonths(start, -buckets), start, 'May – Jul 2026', 'May–Jul'),
    'total': total,
    'count': count,
    'average': count == 0 ? 0 : total / count,
    'previousTotal': 11000,
    'change': 0.127,
    'shareOfAll': tagged ? 0.34 : 1,
    'previousIncomplete': false,
    'granularity': weekly ? 'week' : 'month',
    'trend': trend,
    'monthOverMonth': <String, Object?>{
      'current': 'Oct',
      'previous': 'Sep',
      'currentTotal': 3900,
      'previousTotal': 4300,
      'change': -0.093,
    },
    'summary': empty
        ? const <String>[]
        : <String>['You spent 13% more than in May–Jul, mostly on groceries and fuel for the long weekend trips.'],
    'ids': _ids('e', count),
    'multiTagged': tags && !empty,
    'groups': <String, Object?>{
      'tag': tags && !empty
          ? <Object?>[group('t1', '#family', 4200, 3), group('t2', '#car', 2600, 2)]
          : const <Object?>[],
      'category': empty
          ? const <Object?>[]
          : <Object?>[
              for (int i = 1; i <= 10; i++)
                group('c$i', i == 1 ? 'Groceries and household supplies' : 'Category $i', 1300.0 - i * 50, 1,
                    color: '#3366CC'),
            ],
      'merchant': empty ? const <Object?>[] : <Object?>[group('m1', 'Fresh Mart', 3100, 4), group('m2', 'Fuel Stop', 2000, 2)],
      'source': empty ? const <Object?>[] : <Object?>[group('card:k1', 'Travel card', 8000, 8), group('cash', 'Cash', 4400, 4)],
    },
    'largest': empty
        ? const <Object?>[]
        : <Object?>[
            for (int i = 1; i <= 3; i++)
              <String, Object?>{
                'id': 'e$i',
                'amount': 2000.0 - i * 100,
                'date': _day(today.subtract(Duration(days: i * 9))),
                'title': i == 1 ? 'A very long merchant description for the weekend groceries run' : 'Large expense $i',
                'category': <String, Object?>{'name': 'Groceries', 'color': '#3366CC', 'icon': 'shopping_cart'},
                'funding': 'Travel card',
              },
          ],
    'options': <String, Object?>{
      'tags': tags
          ? <Object?>[
              <String, Object?>{'id': 't2', 'name': 'car', 'count': 2},
              <String, Object?>{'id': 't1', 'name': 'family', 'count': 3},
              <String, Object?>{'id': 't3', 'name': 'unused', 'count': 0},
            ]
          : const <Object?>[],
      'categories': <Object?>[
        <String, Object?>{'id': 'c1', 'name': 'Groceries'},
        <String, Object?>{'id': 'uncategorised', 'name': 'Uncategorised'},
      ],
      'merchants': <Object?>[
        for (int i = 1; i <= merchants; i++) <String, Object?>{'key': 'm$i', 'label': 'Merchant $i', 'total': 5000.0 - i},
      ],
      'sources': <Object?>[
        <String, Object?>{'key': 'card:k1', 'label': 'Travel card'},
        <String, Object?>{'key': 'cash', 'label': 'Cash'},
      ],
      'paymentMethods': <Object?>[
        <String, Object?>{'id': 'p1', 'name': 'UPI'},
      ],
    },
    'earliestCustomStart': _day(AppDateUtils.addMonths(today, -120)),
  };
}

/// Pumps the tab over a loaded provider. [spending] answers each
/// `insightsSpending` call from its arguments.
Future<(FakeEngine, InsightsProvider)> pumpTab(
  WidgetTester tester, {
  double width = 360,
  double height = 720,
  Map<String, Object?> Function(Map<String, Object?> args)? spending,
}) async {
  tester.view.physicalSize = Size(width * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(<String, Object>{});
  final PreferencesService preferences = await PreferencesService.create();
  final SupabaseClient client = SupabaseClient(
    'http://localhost:54321',
    'test-anon-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  final FakeEngine engine = FakeEngine(<String, Object? Function(Map<String, Object?>)>{
    'insightsLoad': (_) => _overview(),
    'insightsSpending': spending ??
        (Map<String, Object?> args) {
          final List<Object?> tagIds = ((args['filter'] as Map<String, Object?>?)?['tagIds'] as List<Object?>?) ?? const <Object?>[];
          return _spending(tagged: tagIds.isNotEmpty);
        },
    'insightsAnalytics': (_) => _analytics(),
    'insightsRows': (Map<String, Object?> args) {
      final List<Object?> ids = args['ids']! as List<Object?>;
      return <String, Object?>{
        'total': ids.length * 1400.0,
        'rows': <Object?>[
          for (final Object? id in ids)
            <String, Object?>{
              'id': id,
              'amount': 1400,
              'date': _day(AppDateUtils.today()),
              'title': 'Row $id',
              'category': <String, Object?>{'name': 'Groceries'},
            },
        ],
      };
    },
  });
  final InsightsProvider insights = InsightsProvider(
    engine: engine,
    expenses: QuietExpenses(client),
    income: QuietIncome(client),
    tags: QuietTags(client),
    cards: QuietCards(client),
  );
  await insights.load(
    userId: 'u1',
    currency: 'INR',
    catalog: const InsightsCatalog(
      categories: <ExpenseCategory>[],
      paymentMethods: <PaymentMethod>[],
      accounts: <BankAccount>[],
      cards: <CardOverview>[],
    ),
  );

  await tester.pumpWidget(
    MultiProvider(
      providers: <ChangeNotifierProvider<dynamic>>[
        ChangeNotifierProvider<SettingsProvider>.value(
          value: SettingsProvider(repository: ProfileRepository(client), preferences: preferences),
        ),
        ChangeNotifierProvider<InsightsProvider>.value(value: insights),
      ],
      child: MaterialApp(theme: AppTheme.light, home: const Scaffold(body: SpendingTab())),
    ),
  );
  await tester.pumpAndSettle();
  return (engine, insights);
}

Finder inSheet(Finder finder) => find.descendant(of: find.byType(BottomSheet), matching: finder);

Future<void> tapText(WidgetTester tester, String text, {bool sheet = false}) async {
  final Finder target = sheet ? inSheet(find.text(text)) : find.text(text);
  await tester.ensureVisible(target.first);
  await tester.pumpAndSettle();
  await tester.tap(target.first);
  await tester.pumpAndSettle();
}

Map<String, Object?> lastFilter(FakeEngine engine) =>
    engine.argsOf('insightsSpending').last['filter']! as Map<String, Object?>;

void main() {
  for (final Size size in const <Size>[Size(360, 720), Size(320, 640)]) {
    final String at = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('report: summary, trend, breakdown and largest at $at, no overflow', (WidgetTester tester) async {
      await pumpTab(tester, width: size.width, height: size.height);

      // The filter bar.
      expect(find.text('1 Aug – 5 Oct 2026'), findsOneWidget);
      expect(find.text('All tags'), findsOneWidget);
      expect(find.text('Filters'), findsOneWidget);
      expect(find.text('Clear'), findsNothing);

      // Summary.
      expect(find.text('TOTAL SPENDING'), findsOneWidget);
      expect(find.text('₹12,400.00'), findsOneWidget);
      expect(find.text('vs May–Jul'), findsOneWidget);
      expect(find.text('13%'), findsOneWidget);
      expect(find.text('Expenses'), findsOneWidget);
      expect(find.text('Average'), findsOneWidget);
      expect(find.text('Before'), findsOneWidget);
      expect(find.text('₹11.0K'), findsOneWidget);
      expect(find.textContaining('You spent 13% more'), findsOneWidget);
      expect(find.text('See all 12 expenses'), findsOneWidget);

      // Trend: the latest bar is selected and still running.
      expect(find.text('Spending over time'), findsOneWidget);
      expect(find.text('By month'), findsOneWidget);
      expect(find.text('M3 · so far'), findsOneWidget);
      expect(find.text('View'), findsOneWidget);
      expect(find.textContaining('Month over month: ₹3.9K in Oct against ₹4.3K in Sep'), findsOneWidget);

      // Where it went, by tag.
      expect(find.text('Where it went'), findsOneWidget);
      expect(find.text('An expense with several tags counts under each'), findsOneWidget);
      for (final String label in <String>['Tags', 'Categories', 'Merchants', 'Paid from']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('#family'), findsOneWidget);
      expect(find.text('34% · 3 expenses'), findsOneWidget);

      // Largest.
      await tester.ensureVisible(find.text('Largest expenses'));
      await tester.pumpAndSettle();
      expect(find.text('Large expense 2'), findsOneWidget);
      expect(find.textContaining('A very long merchant description'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a year of months and a month of weeks lay out at $at', (WidgetTester tester) async {
      bool weekly = false;
      final (FakeEngine _, InsightsProvider insights) = await pumpTab(
        tester,
        width: size.width,
        height: size.height,
        spending: (_) => _spending(buckets: weekly ? 5 : 12, weekly: weekly),
      );
      expect(find.text('M12 · so far'), findsOneWidget);
      expect(tester.takeException(), isNull);

      weekly = true;
      await insights.setPeriod('thisMonth');
      await tester.pumpAndSettle();
      expect(find.text('By week'), findsOneWidget);
      expect(find.text('Week of W5 · so far'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('filter sheet at $at: every group, merchant search, apply a tag', (WidgetTester tester) async {
      final (FakeEngine engine, InsightsProvider _) = await pumpTab(tester, width: size.width, height: size.height);

      await tapText(tester, 'Filters');
      expect(inSheet(find.text('Filters')), findsOneWidget);
      expect(inSheet(find.text('Narrow down the analysis')), findsOneWidget);
      expect(inSheet(find.text('#family · 3')), findsOneWidget);
      expect(inSheet(find.text('#unused')), findsOneWidget);
      expect(inSheet(find.text('Categories')), findsOneWidget);
      expect(inSheet(find.text('Uncategorised')), findsOneWidget);
      expect(inSheet(find.text('Most spent first')), findsOneWidget);
      // Twenty merchants: a search, and the sixteen most spent at first.
      expect(inSheet(find.widgetWithText(TextField, 'Find a merchant')), findsOneWidget);
      expect(inSheet(find.text('Merchant 16')), findsOneWidget);
      expect(inSheet(find.text('Merchant 17')), findsNothing);
      expect(inSheet(find.text('Paid from')), findsOneWidget);
      expect(inSheet(find.text('Travel card')), findsOneWidget);
      expect(inSheet(find.text('Payment methods')), findsOneWidget);
      expect(inSheet(find.text('UPI')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.enterText(inSheet(find.byType(TextField)), 'merchant 2');
      await tester.pumpAndSettle();
      expect(inSheet(find.text('Merchant 20')), findsOneWidget);
      expect(inSheet(find.text('Merchant 3')), findsNothing);

      await tapText(tester, '#family · 3', sheet: true);
      expect(inSheet(find.text('1 selected')), findsWidgets);
      await tapText(tester, 'Apply', sheet: true);

      expect(find.byType(BottomSheet), findsNothing);
      expect(lastFilter(engine)['tagIds'], <String>['t1']);
      expect(find.text('MATCHING SPENDING'), findsOneWidget);
      expect(find.text('₹4,200.00'), findsOneWidget);
      expect(find.text('Of all spending'), findsOneWidget);
      expect(find.text('34%'), findsOneWidget);
      expect(find.text('#family'), findsWidgets);
      expect(tester.takeException(), isNull);

      await tapText(tester, 'Clear');
      expect(lastFilter(engine)['tagIds'], isEmpty);
      expect(find.text('TOTAL SPENDING'), findsOneWidget);
      expect(find.text('All tags'), findsOneWidget);
    });
  }

  testWidgets('the tags chip opens the tags alone', (WidgetTester tester) async {
    final (FakeEngine engine, InsightsProvider _) = await pumpTab(tester, width: 320, height: 640);

    await tapText(tester, 'All tags');
    expect(find.byType(SpendingFilterSheet), findsOneWidget);
    expect(inSheet(find.text('Tags')), findsNWidgets(2)); // The title and the field label.
    expect(inSheet(find.text('Expenses with any of the chosen tags')), findsOneWidget);
    expect(inSheet(find.text('Categories')), findsNothing);
    expect(inSheet(find.text('Merchants')), findsNothing);

    await tapText(tester, '#car · 2', sheet: true);
    await tapText(tester, '#family · 3', sheet: true);
    await tapText(tester, '#unused', sheet: true);
    expect(inSheet(find.text('3 selected')), findsWidgets);
    await tapText(tester, 'Apply', sheet: true);

    expect(lastFilter(engine)['tagIds'], <String>['t2', 't1', 't3']);
    expect(find.text('#car, #family +1'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('period sheet: presets, a custom range waits for two dates', (WidgetTester tester) async {
    final (FakeEngine engine, InsightsProvider insights) = await pumpTab(tester);

    await tapText(tester, '1 Aug – 5 Oct 2026');
    expect(inSheet(find.text('Date range')), findsOneWidget);
    for (final ({String value, String label}) p in spendingPeriodPresets) {
      expect(inSheet(find.text(p.label)), findsOneWidget);
    }
    // The range in use is ticked.
    expect(
      find.descendant(
        of: find.ancestor(of: inSheet(find.text('Last 3 months')), matching: find.byType(Row)).first,
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsOneWidget,
    );
    expect(inSheet(find.text('Custom range')), findsOneWidget);
    expect(inSheet(find.text('From')), findsOneWidget);
    expect(inSheet(find.text('To')), findsOneWidget);
    final TextButton use = tester.widget<TextButton>(
      find.ancestor(of: inSheet(find.text('Use this range')), matching: find.byType(TextButton)),
    );
    expect(use.onPressed, isNull);

    await tapText(tester, 'Last 6 months', sheet: true);
    expect(find.byType(BottomSheet), findsNothing);
    expect(engine.argsOf('insightsSpending').last['preset'], 'last6');
    expect(insights.preset, 'last6');
    expect(tester.takeException(), isNull);
  });

  testWidgets('nothing matching: empty states, and Clear filters', (WidgetTester tester) async {
    bool none = true;
    final (FakeEngine engine, InsightsProvider _) = await pumpTab(
      tester,
      width: 320,
      height: 640,
      spending: (Map<String, Object?> args) {
        final List<Object?> tagIds = ((args['filter'] as Map<String, Object?>?)?['tagIds'] as List<Object?>?) ?? const <Object?>[];
        return _spending(empty: none || tagIds.contains('t2'));
      },
    );
    expect(find.text('No spending matches'), findsOneWidget);
    expect(find.text('No expenses recorded in Aug–Oct.'), findsOneWidget);
    expect(find.text('Clear filters'), findsNothing);
    expect(find.text('Where it went'), findsNothing);

    none = false;
    await tapText(tester, 'All tags');
    await tapText(tester, '#car · 2', sheet: true);
    await tapText(tester, 'Apply', sheet: true);
    expect(find.text('Nothing in Aug–Oct matches these filters.'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tapText(tester, 'Clear filters');
    expect(lastFilter(engine)['tagIds'], isEmpty);
    expect(find.text('TOTAL SPENDING'), findsOneWidget);
  });

  testWidgets('group by: categories with more, then merchants', (WidgetTester tester) async {
    final (FakeEngine _, InsightsProvider insights) = await pumpTab(tester, width: 320, height: 640);

    await tapText(tester, 'Categories');
    expect(insights.groupBy, 'category');
    expect(find.text('An expense with several tags counts under each'), findsNothing);
    expect(find.text('Groceries and household supplies'), findsOneWidget);
    expect(find.text('Category 8'), findsOneWidget);
    expect(find.text('Category 9'), findsNothing);
    await tapText(tester, 'Show all 10 groups');
    expect(find.text('Category 10'), findsOneWidget);
    expect(find.text('Show fewer'), findsOneWidget);

    await tapText(tester, 'Merchants');
    expect(insights.groupBy, 'merchant');
    expect(find.text('Fresh Mart'), findsOneWidget);
    expect(find.text('Show all 10 groups'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without tags, the breakdown is by category and the tags sheet says why', (WidgetTester tester) async {
    await pumpTab(tester, width: 320, height: 640, spending: (_) => _spending(tags: false, merchants: 4));

    expect(find.text('An expense with several tags counts under each'), findsNothing);
    expect(find.text('Groceries and household supplies'), findsOneWidget);

    await tapText(tester, 'Filters');
    expect(inSheet(find.textContaining('No tags yet.')), findsOneWidget);
    // Four merchants: no search.
    expect(inSheet(find.byType(TextField)), findsNothing);
    expect(inSheet(find.text('Merchant 4')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a group, a bar\'s View and See all open their rows',
    (WidgetTester tester) async {
      final (FakeEngine engine, InsightsProvider _) = await pumpTab(tester, width: 320, height: 640);

      Future<void> closeSheet() async {
        Navigator.of(tester.element(find.byType(BottomSheet))).pop();
        await tester.pumpAndSettle();
      }

      await tapText(tester, '#family');
      expect(engine.argsOf('insightsRows').last['ids'], <String>['t1-1', 't1-2', 't1-3']);
      expect(inSheet(find.text('#family')), findsOneWidget);
      expect(inSheet(find.text('Aug–Oct · 3 expenses · ₹4,200.00')), findsOneWidget);
      expect(inSheet(find.text('Row t1-1')), findsOneWidget);
      await closeSheet();

      await tapText(tester, 'View');
      expect(engine.argsOf('insightsRows').last['ids'], <String>['b2-1', 'b2-2']);
      expect(inSheet(find.text('M3')), findsOneWidget);
      expect(inSheet(find.text('2 expenses · ₹2,800.00')), findsOneWidget);
      await closeSheet();

      await tapText(tester, 'See all 12 expenses');
      expect(engine.argsOf('insightsRows').last['ids'], hasLength(12));
      expect(inSheet(find.text('All expenses')), findsOneWidget);
      expect(inSheet(find.text('Aug–Oct · 12 expenses · ₹16,800.00')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
