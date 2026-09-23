// Palette tests: the Ink Wash app theme and the Pastel Garden chart palette.
//
// The theme tests already measure contrast and hue separation. These pin the
// palette choices themselves — that the requested colours are the ones in
// use, that the one deliberate deviation stays a same-hue shade, and that
// charts and the app theme do not bleed into each other.

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

void main() {
  const Color charcoal = Color(0xFF4A4A4A);
  const Color coolGray = Color(0xFFCBCBCB);
  const Color ivory = Color(0xFFFFFEE3);
  const Color blueGray = Color(0xFF6D8196);

  const Color rose = Color(0xFFC75F71);
  const Color blush = Color(0xFFF0B8B8);
  const Color grayGreen = Color(0xFFA2AE9D);
  const Color deepBrown = Color(0xFF54463A);

  group('Ink Wash theme', () {
    test('the four palette colours are the source tokens, exactly', () {
      expect(AppColors.charcoal, charcoal);
      expect(AppColors.coolGray, coolGray);
      expect(AppColors.ivory, ivory);
      expect(AppColors.blueGray, blueGray);
    });

    test('light mode: ivory page, charcoal ink, cool-gray borders', () {
      final ThemeData t = AppTheme.light;
      expect(t.scaffoldBackgroundColor, ivory);
      expect(t.colorScheme.onSurface, charcoal);
      // Borders are the cool gray, applied as a hairline.
      final Color border = t.colorScheme.outline;
      expect(
        (border.red, border.green, border.blue),
        (coolGray.red, coolGray.green, coolGray.blue),
      );
    });

    test('dark mode inks in ivory', () {
      expect(AppTheme.dark.colorScheme.onSurface, ivory);
    });

    test('the exact blue gray is the accent in both themes', () {
      for (final ThemeData t in <ThemeData>[AppTheme.light, AppTheme.dark]) {
        expect(t.colorScheme.secondary, blueGray);
        expect(t.progressIndicatorTheme.color, blueGray);
      }
    });

    test('the accent clears the 3:1 floor for graphics in both themes', () {
      for (final ThemeData t in <ThemeData>[AppTheme.light, AppTheme.dark]) {
        expect(
          _contrast(blueGray, t.colorScheme.surface),
          greaterThanOrEqualTo(3.0),
          reason: '${t.brightness}',
        );
      }
    });

    test('the button shade is the same hue as the accent, just deeper', () {
      // Exact #6D8196 cannot carry an ivory label at AA, so buttons use a
      // deeper shade. It must stay recognisably the same colour.
      expect(_contrast(AppColors.ivory, blueGray), lessThan(4.5),
          reason: 'if this ever passes, drop the deep shade');
      expect(_hueDistance(AppTheme.light.colorScheme.primary, blueGray),
          lessThan(3));
      expect(_hueDistance(AppTheme.dark.colorScheme.primary, blueGray),
          lessThan(8));
    });

    test('glass cards read as ivory paper with a cool-gray hairline', () {
      final Color card = _opaque(AppGlass.light.fill, ivory);
      expect(card, isNot(ivory), reason: 'cards must lift off the page');
      final Color edge = AppGlass.light.borderBottom;
      expect((edge.red, edge.green, edge.blue),
          (coolGray.red, coolGray.green, coolGray.blue));
    });

    testWidgets('the navigation bar is charcoal in both themes',
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
        expect(pane.color, charcoal, reason: '${theme.brightness}');
      }
    });
  });

  group('Pastel Garden charts', () {
    test('light mode charts use the four palette colours exactly', () {
      const ChartColors c = ChartColors.light;
      expect(c.segments.take(4), <Color>[rose, deepBrown, grayGreen, blush]);
      expect(c.emphasis, rose);
      expect(c.idle, blush);
      expect(c.expense, rose);
      expect(c.income, grayGreen);
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

    test('no chart colour borrows the Ink Wash blue gray', () {
      for (final ChartColors c in <ChartColors>[
        ChartColors.light,
        ChartColors.dark,
      ]) {
        for (final Color colour in <Color>[
          ...c.segments,
          c.other,
          c.emphasis,
          c.idle,
          c.expense,
          c.income,
        ]) {
          expect(_hueDistance(colour, blueGray), greaterThan(40),
              reason: '$colour is too close to the app accent');
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
