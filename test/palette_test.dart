// Palette tests: the Gothic Noir app theme and the Pastel Garden chart
// palette.
//
// The theme tests already measure contrast and hue separation. These pin the
// palette choices themselves — that the requested colours are the ones in
// use, that each deliberate adjustment stays in the palette's family, and
// that charts and the app theme do not bleed into each other.

import 'dart:math' as math;

import 'package:expense_tracker/core/theme/app_chart_colors.dart';
import 'package:expense_tracker/core/theme/app_colors.dart';
import 'package:expense_tracker/core/theme/app_glass.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/analytics.dart';
import 'package:expense_tracker/widgets/charts/category_breakdown.dart';
import 'package:expense_tracker/widgets/common/glass_nav_bar.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _luminance(Color c) {
  double channel(int v) {
    final double s = v / 255.0;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4) as double;
  }

  return 0.2126 * channel(c.red) +
      0.7152 * channel(c.green) +
      0.0722 * channel(c.blue);
}

double _contrast(Color a, Color b) {
  final double la = _luminance(a);
  final double lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

double _hueDistance(Color a, Color b) {
  final double raw =
      (HSLColor.fromColor(a).hue - HSLColor.fromColor(b).hue).abs();
  return raw > 180 ? 360 - raw : raw;
}

Color _opaque(Color c, Color over) => Color.alphaBlend(c, over);

(int, int, int) _rgb(Color c) => (c.red, c.green, c.blue);

void main() {
  const Color black = Color(0xFF000000);
  const Color lightGray = Color(0xFFD1D0D0);
  const Color taupe = Color(0xFF988686);
  const Color darkTaupe = Color(0xFF5C4E4E);

  const Color rose = Color(0xFFC75F71);
  const Color blush = Color(0xFFF0B8B8);
  const Color grayGreen = Color(0xFFA2AE9D);
  const Color deepBrown = Color(0xFF54463A);

  group('Gothic Noir theme', () {
    test('the four palette colours are the source tokens, exactly', () {
      expect(AppColors.black, black);
      expect(AppColors.lightGray, lightGray);
      expect(AppColors.taupe, taupe);
      expect(AppColors.darkTaupe, darkTaupe);
    });

    test('light mode: light-gray page, black ink, dark-taupe primary', () {
      final ThemeData t = AppTheme.light;
      expect(t.scaffoldBackgroundColor, lightGray);
      expect(t.colorScheme.onSurface, black);
      expect(t.textTheme.titleLarge!.color, black);
      expect(t.colorScheme.primary, darkTaupe);
      expect(t.colorScheme.onPrimary, lightGray);
    });

    test('cards are taupe washed into light gray, capped for readability', () {
      const Color card = AppColors.lightSurface;
      expect(card, _opaque(taupe.withOpacity(0.15), lightGray));
      // The tint stops where dark-taupe secondary text still reads.
      expect(_contrast(darkTaupe, card), greaterThanOrEqualTo(4.5));
      expect(_rgb(AppGlass.light.fill), _rgb(card));
      expect(card, isNot(lightGray), reason: 'cards must lift off the page');
    });

    test('taupe is the accent in both themes, used exactly where it reads',
        () {
      for (final ThemeData t in <ThemeData>[AppTheme.light, AppTheme.dark]) {
        expect(t.colorScheme.secondary, taupe);
      }
      // Too faint as text on the light page — and fine on black, which is
      // where the hero accents and dark-mode actions use it.
      expect(_contrast(taupe, lightGray), lessThan(3.0));
      expect(_contrast(taupe, black), greaterThanOrEqualTo(4.5));
      expect(AppColors.heroAccent, taupe);
      expect(AppTheme.dark.colorScheme.primary, taupe);
    });

    test('focus rings and progress use dark taupe, visible on a card', () {
      final ThemeData t = AppTheme.light;
      expect(t.progressIndicatorTheme.color, darkTaupe);
      final OutlineInputBorder focus =
          t.inputDecorationTheme.focusedBorder! as OutlineInputBorder;
      expect(focus.borderSide.color, darkTaupe);
      expect(_contrast(darkTaupe, AppColors.lightSurface),
          greaterThanOrEqualTo(3.0));
    });

    test('dark mode: black page, light-gray ink', () {
      final ThemeData t = AppTheme.dark;
      expect(t.scaffoldBackgroundColor, black);
      expect(t.colorScheme.onSurface, lightGray);
    });

    testWidgets('the navigation bar is dark taupe in both themes',
        (WidgetTester tester) async {
      for (final ThemeData theme in <ThemeData>[
        AppTheme.light,
        AppTheme.dark,
      ]) {
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: Scaffold(
            bottomNavigationBar: GlassNavBar(
              items: const <GlassNavItem>[
                GlassNavItem(label: 'Home', icon: Icons.home_outlined),
                GlassNavItem(label: 'Reports', icon: Icons.bar_chart),
              ],
              index: 0,
              onSelected: (_) {},
            ),
          ),
        ));
        final GlassSurface pane = tester.widget(find.descendant(
          of: find.byType(GlassNavBar),
          matching: find.byType(GlassSurface),
        ));
        expect(pane.color, darkTaupe, reason: '${theme.brightness}');
      }
    });

    test('nav icons clear the 3:1 graphics floor on the bar', () {
      expect(_contrast(lightGray, darkTaupe), greaterThanOrEqualTo(3.0),
          reason: 'idle icons');
      expect(_contrast(black, taupe), greaterThanOrEqualTo(3.0),
          reason: 'active icon on its taupe circle');
    });
  });

  group('Pastel Garden charts', () {
    test('light mode charts use the palette, blush deepened only', () {
      const ChartColors c = ChartColors.light;
      expect(c.segments.take(3), <Color>[rose, deepBrown, grayGreen]);
      expect(c.segments[3], isNot(blush));
      expect(_hueDistance(c.segments[3], blush), lessThan(8),
          reason: 'still recognisably blush');
      expect(c.emphasis, deepBrown);
      expect(c.idle, rose);
      expect(c.expense, rose);
      expect(c.income, grayGreen);
    });

    test('exact blush would vanish on the light card — hence the deepening',
        () {
      expect(_contrast(blush, AppColors.lightSurface), lessThan(1.1));
      expect(
        _contrast(ChartColors.light.segments[3], AppColors.lightSurface),
        greaterThan(_contrast(blush, AppColors.lightSurface)),
      );
    });

    test('dark mode lifts deep brown only', () {
      const ChartColors c = ChartColors.dark;
      expect(c.segments[0], rose);
      expect(c.segments[2], grayGreen);
      expect(c.segments[3], blush);
      expect(c.segments[1], isNot(deepBrown));
      expect(_hueDistance(c.segments[1], deepBrown), lessThan(10),
          reason: 'still recognisably the brown');
    });

    test('no chart colour borrows the app theme accents', () {
      for (final ChartColors c in <ChartColors>[
        ChartColors.light,
        ChartColors.dark,
      ]) {
        for (final Color colour in <Color>[
          ...c.segments,
          c.emphasis,
          c.idle,
          c.expense,
          c.income,
        ]) {
          for (final Color t in <Color>[darkTaupe, taupe, black, lightGray]) {
            expect(colour, isNot(t), reason: '$colour is a theme colour');
          }
        }
      }
    });

    test('every dark-mode slice is visible on the dark card', () {
      for (final Color colour in ChartColors.dark.segments) {
        expect(
          _contrast(colour, AppColors.darkSurface),
          greaterThanOrEqualTo(3.0),
          reason: '$colour',
        );
      }
    });

    test('"Other" does not vanish into the card', () {
      expect(
        _contrast(ChartColors.light.other, AppColors.lightSurface),
        greaterThan(1.5),
      );
    });

    test('the selected bar stands out and its label is readable', () {
      for (final (ChartColors c, Color card) in <(ChartColors, Color)>[
        (ChartColors.light, AppColors.lightSurface),
        (ChartColors.dark, AppColors.darkSurface),
      ]) {
        expect(_contrast(c.emphasis, card), greaterThanOrEqualTo(3.0));
        final Color pill = _opaque(c.emphasis.withOpacity(0.18), card);
        expect(_contrast(c.labelOnEmphasis, pill), greaterThanOrEqualTo(4.5));
      }
    });

    test('six named slices never repeat a colour', () {
      const ChartColors c = ChartColors.light;
      final Set<Color> used = <Color>{
        for (int i = 0; i < 6; i++) c.segment(i, 6),
      };
      expect(used, hasLength(6));
    });

    test('folded categories take the Other colour in ring and legend', () {
      const ChartColors c = ChartColors.light;
      // Eight categories, six slices: ranks 5+ are folded into "Other".
      expect(c.segment(4, 8), isNot(c.other));
      expect(c.segment(5, 8), c.other);
      expect(c.segment(7, 8), c.other);
    });

    testWidgets('the donut paints its slices from the chart palette',
        (WidgetTester tester) async {
      final List<CategorySpend> breakdown = <CategorySpend>[
        for (int i = 0; i < 3; i++)
          CategorySpend(
            categoryId: 'c$i',
            name: 'Category $i',
            // Stored category colours must NOT reach the chart.
            color: '#3B82F6',
            icon: 'restaurant',
            total: 300.0 - i * 50,
            transactionCount: 1,
          ),
      ];
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: CategoryDonut(breakdown: breakdown, currency: 'INR'),
        ),
      ));

      final PieChart chart = tester.widget(find.byType(PieChart));
      expect(
        chart.data.sections.map((PieChartSectionData s) => s.color),
        <Color>[rose, deepBrown, grayGreen],
      );
    });
  });
}
