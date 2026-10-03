/// Tests for the floating navigation bar and the dashboard chart carousel.
///
/// Both are shared components with real behaviour behind them — a moving
/// selection indicator and a timer that must not fight the user — so the
/// things that would make them annoying rather than merely ugly are measured
/// here: that a swipe is never yanked back, that nothing animates on a tab
/// nobody is looking at, and that dropping the labels did not drop the
/// screen-reader's only way to name a destination.
library;

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/analytics.dart';
import 'package:expense_tracker/screens/dashboard/dashboard_screen.dart';
import 'package:expense_tracker/widgets/charts/category_breakdown.dart';
import 'package:expense_tracker/widgets/charts/monthly_trend_chart.dart';
import 'package:expense_tracker/widgets/common/card_carousel.dart';
import 'package:expense_tracker/widgets/common/glass_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const List<double> _widths = <double>[320, 360, 411];

const List<GlassNavItem> _items = <GlassNavItem>[
  GlassNavItem(label: 'Home', icon: Icons.home_outlined),
  GlassNavItem(label: 'Expenses', icon: Icons.receipt_long_outlined),
  GlassNavItem(label: 'Income', icon: Icons.savings_outlined),
  GlassNavItem(label: 'Reports', icon: Icons.bar_chart_rounded),
  GlassNavItem(label: 'Settings', icon: Icons.settings_outlined),
];

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 360,
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
  bool tickersEnabled = true,
  double bottomInset = 0,
}) async {
  tester.view.physicalSize = Size(width * 3, 800 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
      home: MediaQuery(
        data: MediaQueryData(
          disableAnimations: reduceMotion,
          padding: EdgeInsets.only(bottom: bottomInset),
        ),
        child: TickerMode(
          enabled: tickersEnabled,
          child: Scaffold(body: child),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  // ---------------------------------------------------------------------
  // Navigation bar
  // ---------------------------------------------------------------------
  group('GlassNavBar', () {
    Widget bar({int index = 0, ValueChanged<int>? onSelected}) => Align(
          alignment: Alignment.bottomCenter,
          child: GlassNavBar(
            items: _items,
            index: index,
            onSelected: onSelected ?? (_) {},
          ),
        );

    testWidgets('shows five icons and no painted labels',
        (WidgetTester tester) async {
      await _pump(tester, bar());

      expect(find.byType(Icon), findsNWidgets(_items.length));
      for (final GlassNavItem item in _items) {
        expect(find.text(item.label), findsNothing,
            reason: 'the bar is icon-only by design');
      }
    });

    testWidgets('every destination is still named for assistive tech',
        (WidgetTester tester) async {
      // Dropping the labels is a visual decision. It must not become an
      // accessibility one: without these a screen-reader user has five
      // unlabelled buttons.
      await _pump(tester, bar());

      for (final GlassNavItem item in _items) {
        expect(find.byTooltip(item.label), findsOneWidget, reason: item.label);
      }

      final SemanticsHandle handle = tester.ensureSemantics();
      for (final GlassNavItem item in _items) {
        expect(find.bySemanticsLabel(item.label), findsWidgets,
            reason: item.label);
      }
      handle.dispose();
    });

    testWidgets('tapping a destination reports its index',
        (WidgetTester tester) async {
      final List<int> taps = <int>[];
      await _pump(tester, bar(onSelected: taps.add));

      await tester.tap(find.byTooltip('Reports'));
      await tester.pumpAndSettle();
      expect(taps, <int>[3]);

      await tester.tap(find.byTooltip('Home'));
      await tester.pumpAndSettle();
      expect(taps, <int>[3, 0]);
    });

    testWidgets('the highlight slides to the selected slot',
        (WidgetTester tester) async {
      await _pump(tester, bar());
      final double first = tester
          .getTopLeft(find.byType(AnimatedPositioned).first)
          .dx;

      await _pump(tester, bar(index: 4));
      await tester.pumpAndSettle();
      final double last = tester
          .getTopLeft(find.byType(AnimatedPositioned).first)
          .dx;

      expect(last, greaterThan(first),
          reason: 'the pill marks which destination is active');
    });

    testWidgets('stays compact and clears the gesture inset',
        (WidgetTester tester) async {
      await _pump(tester, bar(), bottomInset: 34);
      final double height = tester.getSize(find.byType(GlassNavBar)).height;

      // The pill itself is 52; the rest is the inset it has to clear.
      expect(height, greaterThan(52));
      expect(height, lessThan(80), reason: 'a nav bar, not a drawer');
    });

    testWidgets('renders at every width in both themes',
        (WidgetTester tester) async {
      for (final Brightness brightness in Brightness.values) {
        for (final double width in _widths) {
          await _pump(tester, bar(index: 2),
              width: width, brightness: brightness);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$width $brightness');
        }
      }
    });
  });

  // ---------------------------------------------------------------------
  // Carousel
  // ---------------------------------------------------------------------
  group('CardCarousel', () {
    List<CarouselPage> pages() => <CarouselPage>[
          const CarouselPage(title: 'Where it went', child: Text('donut')),
          const CarouselPage(title: 'Monthly spending', child: Text('trend')),
        ];

    Widget carousel({List<CarouselPage>? only}) => CardCarousel(
          pages: only ?? pages(),
          height: 200,
        );

    testWidgets('opens on the first page and labels it',
        (WidgetTester tester) async {
      await _pump(tester, carousel());

      expect(find.text('Where it went'), findsOneWidget);
      expect(find.text('donut'), findsOneWidget);
    });

    testWidgets('swiping moves to the next card and retitles the header',
        (WidgetTester tester) async {
      await _pump(tester, carousel());

      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();

      expect(find.text('trend'), findsOneWidget);
      expect(find.text('Monthly spending'), findsOneWidget);
    });

    testWidgets('advances on its own after the interval',
        (WidgetTester tester) async {
      await _pump(tester, carousel());
      expect(find.text('donut'), findsOneWidget);

      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();

      expect(find.text('trend'), findsOneWidget);
    });

    testWidgets('wraps around rather than stopping at the end',
        (WidgetTester tester) async {
      await _pump(tester, carousel());

      for (int i = 0; i < 2; i++) {
        await tester.pump(const Duration(seconds: 10));
        await tester.pumpAndSettle();
      }
      expect(find.text('donut'), findsOneWidget);
    });

    testWidgets('a manual swipe restarts the clock instead of being overridden',
        (WidgetTester tester) async {
      // The failure this guards against: the user swipes back to the card
      // they want, and two seconds later the timer — still counting from
      // before the swipe — drags them off it again.
      await _pump(tester, carousel());

      await tester.pump(const Duration(seconds: 9));
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(find.text('trend'), findsOneWidget);

      // The pre-swipe timer would have fired about here.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('trend'), findsOneWidget,
          reason: 'the chosen card keeps a full interval to itself');

      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(find.text('donut'), findsOneWidget);
    });

    testWidgets('does not auto-advance on a tab nobody is looking at',
        (WidgetTester tester) async {
      await _pump(tester, carousel(), tickersEnabled: false);

      await tester.pump(const Duration(seconds: 15));
      await tester.pumpAndSettle();

      expect(find.text('donut'), findsOneWidget);
    });

    testWidgets('does not auto-advance under reduced motion',
        (WidgetTester tester) async {
      await _pump(tester, carousel(), reduceMotion: true);

      await tester.pump(const Duration(seconds: 15));
      await tester.pumpAndSettle();

      expect(find.text('donut'), findsOneWidget,
          reason: 'unsolicited movement is what the setting turns off');
    });

    testWidgets('a single page renders without indicators fighting it',
        (WidgetTester tester) async {
      await _pump(
        tester,
        carousel(
          only: <CarouselPage>[
            const CarouselPage(title: 'Only one', child: Text('solo')),
          ],
        ),
      );

      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(find.text('solo'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders at every width in both themes',
        (WidgetTester tester) async {
      for (final Brightness brightness in Brightness.values) {
        for (final double width in _widths) {
          await _pump(tester, carousel(),
              width: width, brightness: brightness);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$width $brightness');
        }
      }
    });

    testWidgets('the real dashboard charts fit the height it is given',
        (WidgetTester tester) async {
      // The height is a constant chosen for the taller page, so it has to be
      // checked against the actual charts rather than a Text placeholder —
      // an overflow here would be a red-striped card on the home screen.
      final List<CategorySpend> breakdown = <CategorySpend>[
        const CategorySpend(
          categoryId: 'c1',
          name: 'Food & Dining Out With A Long Name',
          color: '#EF6C4D',
          icon: 'restaurant',
          total: 123456,
          transactionCount: 12,
        ),
        const CategorySpend(
          categoryId: 'c2',
          name: 'Transport',
          color: '#3B82F6',
          icon: 'directions_bus',
          total: 45678,
          transactionCount: 8,
        ),
        const CategorySpend(
          categoryId: 'c3',
          name: 'Bills',
          color: '#A855F7',
          icon: 'receipt_long',
          total: 9876,
          transactionCount: 3,
        ),
      ];
      final List<MonthlyPoint> trend = <MonthlyPoint>[
        for (int i = 0; i < 6; i++)
          MonthlyPoint(
            month: DateTime(2026, i + 4, 1),
            expense: 10000.0 * (i + 1),
            income: 25000.0 * (i + 1),
          ),
      ];

      for (final double width in _widths) {
        await _pump(
          tester,
          CardCarousel(
            height: DashboardCharts.cardHeight,
            pages: <CarouselPage>[
              CarouselPage(
                title: 'Where it went',
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    CategoryDonut(
                      breakdown: breakdown,
                      currency: 'INR',
                      size: DashboardCharts.donutSize,
                    ),
                    const SizedBox(height: 12),
                    CategoryBreakdownList(
                      breakdown: breakdown,
                      currency: 'INR',
                      limit: 3,
                    ),
                  ],
                ),
              ),
              CarouselPage(
                title: 'Monthly spending',
                child: MonthlyTrendCard(
                  points: trend,
                  currency: 'INR',
                  chartHeight: DashboardCharts.trendHeight,
                ),
              ),
            ],
          ),
          width: width,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'page 1 at $width');

        await tester.drag(find.byType(PageView), const Offset(-400, 0));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'page 2 at $width');
      }
    });

    test('the dashboard gives a chart ten seconds before moving it', () {
      // Five was not long enough to read a chart, which is the whole point of
      // putting one on the home screen.
      expect(DashboardCharts.carouselInterval, const Duration(seconds: 10));
    });
  });

  // ---------------------------------------------------------------------
  // Monthly spending card
  // ---------------------------------------------------------------------
  group('MonthlyTrendCard', () {
    List<MonthlyPoint> trend() => <MonthlyPoint>[
          MonthlyPoint(month: DateTime(2026, 7), expense: 4000, income: 0),
          MonthlyPoint(month: DateTime(2026, 8), expense: 10000, income: 0),
          MonthlyPoint(month: DateTime(2026, 9), expense: 8428, income: 0),
        ];

    testWidgets('opens on the latest month and states its total',
        (WidgetTester tester) async {
      await _pump(
        tester,
        MonthlyTrendCard(points: trend(), currency: 'INR', chartHeight: 180),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('September 2026'), findsOneWidget);
      expect(find.textContaining('8,428'), findsOneWidget);
    });

    testWidgets('compares the month with the one before it',
        (WidgetTester tester) async {
      await _pump(
        tester,
        MonthlyTrendCard(points: trend(), currency: 'INR', chartHeight: 180),
      );
      await tester.pumpAndSettle();

      // 8,428 against 10,000 is a 16% fall — spending less, so the badge
      // reads as an improvement rather than a loss.
      expect(find.textContaining('16% vs Aug'), findsOneWidget);
    });

    testWidgets('a month with no predecessor shows no percentage',
        (WidgetTester tester) async {
      await _pump(
        tester,
        MonthlyTrendCard(
          points: <MonthlyPoint>[
            MonthlyPoint(month: DateTime(2026, 9), expense: 500, income: 0),
          ],
          currency: 'INR',
          chartHeight: 180,
        ),
      );
      await tester.pumpAndSettle();

      // A percentage against nothing is not a number.
      expect(find.textContaining('%'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders at every width in both themes',
        (WidgetTester tester) async {
      for (final Brightness brightness in Brightness.values) {
        for (final double width in _widths) {
          await _pump(
            tester,
            MonthlyTrendCard(
              points: trend(),
              currency: 'INR',
              chartHeight: DashboardCharts.trendHeight,
            ),
            width: width,
            brightness: brightness,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$width $brightness');
        }
      }
    });
  });
}
