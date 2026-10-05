// The Reports Analytics tab, rendered at the Armor X8's real size (360 x 720
// dp) and at a 320 dp phone over a scripted insights engine. It checks that
// every section lays out without an overflow, that the jump chips and a
// requested section scroll the list, and that the long view waits on its
// analysis — not the analysis itself, which the web engine's tests cover.
// Nothing touches a network or a database, and every figure is invented.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/credit_card.dart';
import 'package:expense_tracker/models/tag.dart';
import 'package:expense_tracker/providers/insights_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/repositories/credit_card_repository.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/income_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/repositories/profile_repository.dart';
import 'package:expense_tracker/repositories/tag_repository.dart';
import 'package:expense_tracker/screens/reports/analytics_view.dart';
import 'package:expense_tracker/services/preferences_service.dart';
import 'package:expense_tracker/services/statement_import/statement_engine.dart';
import 'package:expense_tracker/widgets/common/state_views.dart';

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
      <Map<String, dynamic>>[];

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
      <String, double>{};
}

class QuietTags extends TagRepository {
  QuietTags(super.client);

  @override
  Future<List<Tag>> fetchTags(String userId) async => const <Tag>[];

  @override
  Future<Map<String, List<String>>> fetchExpenseTagLinks(String userId) async => const <String, List<String>>{};
}

class QuietCards extends CreditCardRepository {
  QuietCards(super.client, {required super.expenses, required super.ledger});

  @override
  Future<List<CardTransaction>> fetchCharges({required String userId, required DateTime from}) async =>
      const <CardTransaction>[];
}

Map<String, Object?> period(String start, String end, String label, String short) =>
    <String, Object?>{'start': start, 'end': end, 'label': label, 'short': short};

Map<String, Object?> recurring(
  String key,
  String label, {
  required String kind,
  required bool active,
  String trend = 'flat',
  String next = '2026-10-12',
  String last = '2026-09-12',
  double amount = 649,
}) =>
    <String, Object?>{
      'key': key,
      'label': label,
      'kind': kind,
      'kindLabel': 'Subscription',
      'cadence': 'monthly',
      'cadenceLabel': 'Monthly',
      'unit': <String>['month', 'months'],
      'streak': 5,
      'amount': amount,
      'variable': false,
      'monthlyCost': amount,
      'yearlyCost': amount * 12,
      'totalPaid': amount * 5,
      'lastDate': last,
      'nextDate': next,
      'active': active,
      'trend': trend,
      'priceChange': null,
      'explanation': 'Paid every month for five months, the same amount each time.',
      'extraCount': 0,
      'payments': <Object?>[],
    };

Map<String, Object?> overviewJson({bool showCards = true}) => <String, Object?>{
      'session': 's1',
      'today': '2026-10-05',
      'since': '2024-09-05',
      'historyStart': '2024-09-07',
      'enoughData': true,
      'highlights': <Object?>[],
      'recurring': <Object?>[
        recurring('stream', 'Streaming Service Premium Family Plan With Extras', kind: 'subscription', active: true, trend: 'up'),
        recurring('rent', 'Apartment rent', kind: 'rent', active: true, next: '2026-11-01', amount: 2850000),
        recurring('gym', 'Gym membership', kind: 'fitness', active: false, last: '2026-05-02'),
      ],
      'recurringMonthly': 2850649,
      'runningCount': 2,
      'savings': <Object?>[
        for (int i = 0; i < 6; i++)
          <String, Object?>{
            'id': 'saving$i',
            'title': i == 0 ? 'Three streaming subscriptions overlap with one another' : 'Idea $i',
            'evidence': <String>[
              'You paid ₹1,947 a month across Streaming Service, Another Stream and Music.',
              'Two of them were used in the same weeks.',
            ],
            'suggestion': 'Keep the one you watch most and pause the others for a month to see if you miss them.',
            'saving': <String, Object?>{'monthly': 1298.4, 'yearly': 15580.8},
            'drill': i == 0
                ? <String, Object?>{'type': 'section', 'section': 'recurring'}
                : <String, Object?>{'type': 'rows', 'title': 'Idea $i', 'ids': <String>['e$i']},
          },
      ],
      'unusual': <Object?>[
        <String, Object?>{
          'type': 'large',
          'explanation': '₹18,400 at Electronics Mega Store on 28 Sep is about six times your usual purchase in Shopping.',
          'ids': <String>['e1'],
        },
        <String, Object?>{
          'type': 'duplicate',
          'explanation': 'Two charges of ₹649 at Streaming Service on 3 Oct, a few minutes apart.',
          'ids': <String>['e2', 'e3'],
        },
      ],
      'changes': <String, Object?>{
        'current': period('2026-08-01', '2026-10-05', '1 Aug – 5 Oct 2026', 'Aug–Oct'),
        'previous': period('2026-05-01', '2026-07-31', '1 May – 31 Jul 2026', 'May–Jul'),
        'compared': true,
        'headline': 'You spent ₹12,400 more than in May–Jul, mostly on Shopping and Travel.',
        'reasons': <String>['Shopping rose by ₹8,200 across 14 purchases.', 'Travel had two flights booked in September.'],
        'currentCount': 42,
        'ids': <String>['e1', 'e2'],
        'movers': <Object?>[
          <String, Object?>{
            'key': 'c1',
            'label': 'Shopping and personal electronics for the household',
            'delta': 8200,
            'currentCount': 14,
            'reason': 'more purchases, and larger on average than before',
            'ids': <String>['e1'],
          },
          <String, Object?>{'key': 'c2', 'label': 'Travel', 'delta': 5400, 'currentCount': 2, 'reason': 'two flights', 'ids': <String>['e2']},
          <String, Object?>{'key': 'c3', 'label': 'Dining out', 'delta': -1200, 'currentCount': 6, 'reason': 'fewer visits', 'ids': <String>['e3']},
        ],
      },
      'presets': <Object?>[],
      'showCards': showCards,
    };

String monthOf(int offset) {
  final DateTime m = DateTime(2026, 10 + offset);
  return '${m.year}-${m.month.toString().padLeft(2, '0')}-01';
}

List<double> series(int span, double base) => <double>[for (int i = 0; i <= span; i++) base + (i * 37 % 5) * base / 10];

Map<String, Object?> analyticsJson(int span) => <String, Object?>{
      'range': period(monthOf(1 - span).replaceFirst('-01', '-05'), '2026-10-05', 'Since 5 May 2026', 'May–Oct'),
      'patterns': <String, Object?>{
        'count': 64,
        'sentences': <String>[
          'A weekend day costs about 40% more than a weekday.',
          'Three categories took 62% of your spending.',
        ],
        'classifiedShare': 0.82,
        'necessity': <Object?>[
          <String, Object?>{'key': 'essential', 'name': 'Essential', 'total': 61200, 'share': 0.55, 'ids': <String>['e1']},
          <String, Object?>{'key': 'discretionary', 'name': 'Discretionary', 'total': 30100, 'share': 0.27, 'ids': <String>['e2']},
          <String, Object?>{'key': 'unclassified', 'name': 'Not classified', 'total': 20000, 'share': 0.18, 'ids': <String>['e3']},
        ],
        'week': <String, Object?>{'weekdayPerDay': 820, 'weekendPerDay': 1150},
        'size': <String, Object?>{'typical': 450, 'largeCount': 5, 'largeIds': <String>['e1']},
        'topCategoriesShare': 0.62,
        'recurringShare': 0.31,
      },
      'trends': <String, Object?>{
        'averageSpent': 1234567.4,
        'change': 0.22,
        'months': <Object?>[
          for (int i = 0; i <= span; i++)
            <String, Object?>{'month': monthOf(i - span), 'spent': 30000 + i * 1500, 'income': 42000, 'partial': i == span},
        ],
        'averages': <Object?>[
          <String, Object?>{'span': 3, 'average': 38000},
          <String, Object?>{'span': span, 'average': 36500},
        ],
        'sentences': <String>['Spending has risen three months in a row.'],
        'cashflowSentences': <String>['You kept 18% of your income over these months.'],
        'categories': <Object?>[
          for (int i = 0; i < 8; i++)
            <String, Object?>{
              'key': 'c$i',
              'label': i == 0 ? 'Groceries and household essentials from the market' : 'Category $i',
              'average': 4200.0 * (i + 1),
              'previousAverage': i.isEven ? 3900.0 * (i + 1) : null,
              'change': i == 1 ? null : (i == 2 ? 0 : 0.15 * (i - 3)),
              'months': series(span, 4200.0 * (i + 1)),
              'ids': <String>['e$i'],
              'color': '#3F6D9E',
            },
        ],
        'tags': <Object?>[
          <String, Object?>{
            'key': 't1',
            'label': 'Holiday',
            'average': 5000,
            'previousAverage': null,
            'change': null,
            'months': series(span, 5000),
            'ids': <String>['e1'],
            'color': null,
          },
        ],
        'cashflow': <String, Object?>{'income': 150000, 'spent': 123000, 'saved': 27000, 'rate': 0.18, 'overspentMonths': 2},
      },
      'cards': <String, Object?>{
        'uses': <Object?>[
          <String, Object?>{'id': 'k1', 'name': 'Travel Rewards Signature Card ••4821', 'utilisation': 0.82},
          <String, Object?>{'id': 'k2', 'name': 'Cashback', 'utilisation': 0.12},
        ],
        'cardShare': 0.35,
        'charged': 1250,
        'back': 3400,
        'purchaseIds': <String>['e1', 'e2'],
      },
    };

FakeEngine engineFor({bool analyticsFails = false, bool showCards = true}) => FakeEngine(
      <String, Object? Function(Map<String, Object?>)>{
        'insightsLoad': (_) => overviewJson(showCards: showCards),
        'insightsSpending': (_) => <String, Object?>{
              'period': period('2026-08-01', '2026-10-05', '1 Aug – 5 Oct 2026', 'Aug–Oct'),
              'previous': period('2026-05-01', '2026-07-31', '1 May – 31 Jul 2026', 'May–Jul'),
              'earliestCustomStart': '2016-10-05',
            },
        'insightsAnalytics': (Map<String, Object?> args) {
          if (analyticsFails) throw const StatementEngineException('failed', 'The analysis failed.');
          return analyticsJson(args['span']! as int);
        },
      },
    );

Future<InsightsProvider> pumpTab(
  WidgetTester tester, {
  required Size size,
  required FakeEngine engine,
  required ValueNotifier<String?> jump,
}) async {
  tester.view.physicalSize = Size(size.width * 2, size.height * 2);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(<String, Object>{});
  final PreferencesService preferences = await PreferencesService.create();
  final SupabaseClient client = SupabaseClient(
    'http://localhost:54321',
    'test-anon-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  final QuietExpenses expenses = QuietExpenses(client);
  final InsightsProvider insights = InsightsProvider(
    engine: engine,
    expenses: expenses,
    income: QuietIncome(client),
    tags: QuietTags(client),
    cards: QuietCards(client, expenses: expenses, ledger: LedgerRepository(client)),
  );
  await insights.load(
    userId: 'u1',
    currency: 'INR',
    catalog: const InsightsCatalog(categories: [], paymentMethods: [], accounts: [], cards: []),
  );

  await tester.pumpWidget(
    MultiProvider(
      providers: <ChangeNotifierProvider<dynamic>>[
        ChangeNotifierProvider<SettingsProvider>.value(
          value: SettingsProvider(repository: ProfileRepository(client), preferences: preferences),
        ),
        ChangeNotifierProvider<InsightsProvider>.value(value: insights),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: AnalyticsTab(jump: jump)),
      ),
    ),
  );
  return insights;
}

/// The tab's own list, not the jump chips' row inside it.
final Finder listScrollable = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;

ScrollPosition listPosition(WidgetTester tester) => tester.state<ScrollableState>(listScrollable).position;

/// Scrolls the list a part-screen at a time until [finder] is built and on
/// screen. The list builds lazily, so a section far down does not exist yet.
Future<void> scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 250, scrollable: listScrollable, maxScrolls: 80);
  await tester.pumpAndSettle();
}

/// Steps through the whole list top to bottom, so every section is built and
/// laid out at least once, checking for an overflow at each step. Returns the
/// [texts] that were seen on the way.
Future<Set<String>> scrollThrough(WidgetTester tester, [List<String> texts = const <String>[]]) async {
  final Set<String> seen = <String>{};
  listPosition(tester).jumpTo(0);
  await tester.pumpAndSettle();
  for (int i = 0; i < 80; i++) {
    for (final String text in texts) {
      if (find.text(text).evaluate().isNotEmpty) seen.add(text);
    }
    final ScrollPosition position = listPosition(tester);
    if (position.pixels >= position.maxScrollExtent) break;
    position.jumpTo(position.pixels + 250);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }
  return seen;
}

Future<void> tapChip(WidgetTester tester, String label) async {
  final Finder chip = find.widgetWithText(ChoiceChip, label);
  final Finder bar = find.ancestor(
    of: find.widgetWithText(ChoiceChip, 'What changed'),
    matching: find.byType(SingleChildScrollView),
  );
  final double width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  for (int i = 0; i < 10 && tester.getRect(chip).right > width; i++) {
    await tester.drag(bar, const Offset(-150, 0));
    await tester.pumpAndSettle();
  }
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

void main() {
  for (final Size size in const <Size>[Size(360, 720), Size(320, 640)]) {
    final String at = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('every section renders without an overflow at $at', (WidgetTester tester) async {
      final ValueNotifier<String?> jump = ValueNotifier<String?>(null);
      await pumpTab(tester, size: size, engine: engineFor(), jump: jump);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(find.text('You spent ₹12,400 more than in May–Jul, mostly on Shopping and Travel.'), findsOneWidget);
      expect(find.text('See 42 expenses in Aug–Oct'), findsOneWidget);

      // The stopped payment opens on request.
      await scrollTo(tester, find.text('Not seen recently (1)'));
      expect(find.text('Gym membership'), findsNothing);
      await tester.tap(find.text('Not seen recently (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Gym membership'), findsOneWidget);
      expect(find.text('Hide payments not seen recently'), findsOneWidget);

      // Five of six ideas, then all of them.
      await scrollTo(tester, find.text('Show all 6 ideas'));
      expect(find.text('Idea 5'), findsNothing);
      await tester.tap(find.text('Show all 6 ideas'));
      await tester.pumpAndSettle();
      expect(find.text('Idea 5'), findsOneWidget);

      const List<String> expected = <String>[
        'Recurring payments',
        'Running',
        'Savings opportunities',
        'Worth a second look',
        'Possible duplicate',
        'The long view',
        'Spending patterns',
        'A weekend day',
        'See the 5 largest purchases',
        'Trends',
        'AVERAGE MONTH',
        'Category trends',
        'Show all 8 categories',
        'Tag trends',
        'Cash flow',
        'Spending was above income in 2 of these months.',
        'Credit cards',
        'Using under about 30% of a limit is generally better for a credit score.',
        'See 2 card purchases',
      ];
      final Set<String> seen = await scrollThrough(tester, expected);
      expect(seen, containsAll(expected));
    });

    testWidgets('a jump chip scrolls to its section at $at', (WidgetTester tester) async {
      final ValueNotifier<String?> jump = ValueNotifier<String?>(null);
      await pumpTab(tester, size: size, engine: engineFor(), jump: jump);
      await tester.pumpAndSettle();

      expect(listPosition(tester).pixels, 0);
      await tapChip(tester, 'Trends');
      expect(tester.takeException(), isNull);
      expect(listPosition(tester).pixels, greaterThan(0));
      final double top = tester.getTopLeft(find.text('Complete months, with this month so far shown last')).dy;
      expect(top, inInclusiveRange(0, 120));

      // And back up the list to the first section.
      final double down = listPosition(tester).pixels;
      jump.value = 'changes';
      await tester.pumpAndSettle();
      expect(listPosition(tester).pixels, lessThan(down));
      expect(tester.getTopLeft(find.text('1 Aug – 5 Oct 2026 vs May–Jul')).dy, inInclusiveRange(0, 120));
    });
  }

  testWidgets('a requested section scrolls into view and the request clears', (WidgetTester tester) async {
    final ValueNotifier<String?> jump = ValueNotifier<String?>(null);
    await pumpTab(tester, size: const Size(360, 720), engine: engineFor(), jump: jump);
    await tester.pumpAndSettle();

    jump.value = 'cashflow';
    await tester.pumpAndSettle();
    expect(jump.value, isNull);
    final double cashflow = tester.getTopLeft(find.text('Income recorded against spending')).dy;
    expect(cashflow, inInclusiveRange(0, 120));

    // Back up the list, to a section above.
    jump.value = 'savings';
    await tester.pumpAndSettle();
    expect(jump.value, isNull);
    expect(
      tester.getTopLeft(find.text('Optional ideas from your own spending — estimates, and some may overlap')).dy,
      inInclusiveRange(0, 120),
    );

    // A saving idea's Details can lead to another section.
    await tester.tap(find.text('Details').first);
    await tester.pumpAndSettle();
    expect(jump.value, isNull);
    expect(
      tester.getTopLeft(find.text('Subscriptions, bills, EMIs and renewals found in your history')).dy,
      inInclusiveRange(0, 120),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a section asked for before the tab opens is shown when it does', (WidgetTester tester) async {
    final ValueNotifier<String?> jump = ValueNotifier<String?>('unusual');
    await pumpTab(tester, size: const Size(360, 720), engine: engineFor(), jump: jump);
    await tester.pumpAndSettle();
    expect(jump.value, isNull);
    expect(tester.getTopLeft(find.text('Last 45 days')).dy, inInclusiveRange(0, 120));
  });

  testWidgets('the span control asks the engine for a new long view', (WidgetTester tester) async {
    final ValueNotifier<String?> jump = ValueNotifier<String?>(null);
    final FakeEngine engine = engineFor();
    final InsightsProvider insights = await pumpTab(tester, size: const Size(320, 640), engine: engine, jump: jump);
    await tester.pumpAndSettle();
    expect(engine.argsOf('insightsAnalytics').last['span'], 6);

    await scrollTo(tester, find.text('12 months'));
    await tester.tap(find.text('12 months'));
    await tester.pumpAndSettle();
    expect(engine.argsOf('insightsAnalytics').last['span'], 12);
    expect(insights.span, 12);

    // Thirteen months of bars and a year of trends still fit.
    final Set<String> seen = await scrollThrough(
      tester,
      const <String>['Average a month · Last 12 months', 'vs the 12 months before'],
    );
    expect(seen, hasLength(2));
  });

  testWidgets('without the long view yet, only it shows a placeholder', (WidgetTester tester) async {
    final ValueNotifier<String?> jump = ValueNotifier<String?>(null);
    await pumpTab(
      tester,
      size: const Size(320, 640),
      engine: engineFor(analyticsFails: true, showCards: false),
      jump: jump,
    );
    // The placeholder shimmers, so the frames are pumped by hand.
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('What changed'), findsWidgets);
    expect(find.widgetWithText(ChoiceChip, 'Cards'), findsNothing);

    // A long-view section waits on the placeholder, which stands in for it.
    jump.value = 'trends';
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(jump.value, isNull);
    expect(listPosition(tester).pixels, greaterThan(0));
    expect(tester.getTopLeft(find.byType(Skeleton).first).dy, inInclusiveRange(0, 160));
    expect(find.text('Spending patterns', skipOffstage: false), findsNothing);
    expect(find.text('Credit cards', skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
