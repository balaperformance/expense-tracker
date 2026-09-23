// Palette tests: the Old Photograph app theme and the Pastel Garden chart
// palette.
//
// The theme tests already measure contrast and hue separation. These pin the
// palette choices themselves — that the requested colours are the ones in
// use, that each deliberate shading stays in the palette's family, and that
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

(int, int, int) _rgb(Color c) => (c.red, c.green, c.blue);

void main() {
  const Color cream = Color(0xFFFDFBD4);
  const Color beige = Color(0xFFD9D7B6);
  const Color oliveGray = Color(0xFF878672);
  const Color deepOlive = Color(0xFF545333);

  const Color rose = Color(0xFFC75F71);
  const Color blush = Color(0xFFF0B8B8);
  const Color grayGreen = Color(0xFFA2AE9D);
  const Color deepBrown = Color(0xFF54463A);

  group('Old Photograph theme', () {
    test('the four palette colours are the source tokens, exactly', () {
      expect(AppColors.cream, cream);
      expect(AppColors.beige, beige);
      expect(AppColors.oliveGray, oliveGray);
      expect(AppColors.deepOlive, deepOlive);
    });

    test('light mode: cream page, beige cards, deep-olive primary', () {
      final ThemeData t = AppTheme.light;
      expect(t.scaffoldBackgroundColor, cream);
      expect(t.colorScheme.surface, beige);
      expect(t.colorScheme.primary, deepOlive);
      expect(t.colorScheme.onPrimary, cream);
    });

    test('deep olive carries the important text: headings and figures', () {
      final TextTheme text = AppTheme.light.textTheme;
      expect(text.titleLarge!.color, deepOlive);
      expect(text.displaySmall!.color, deepOlive);
      expect(text.headlineSmall!.color, deepOlive);
    });

    test('olive gray is the secondary accent in both themes', () {
      for (final ThemeData t in <ThemeData>[AppTheme.light, AppTheme.dark]) {
        expect(t.colorScheme.secondary, oliveGray);
      }
    });

    test('olive gray is shaded only where it would fail contrast', () {
      // Exact olive gray is too faint on a beige card for an icon or for
      // text. If that ever stops being true, the shading should go.
      expect(_contrast(oliveGray, beige), lessThan(3.0));
      expect(_contrast(oliveGray, cream), greaterThanOrEqualTo(3.0),
          reason: 'fine on the page, where the page dots use it');

      // Secondary text is the same hue, deepened to AA on the card.
      final Color muted = AppTheme.light.colorScheme.onSurfaceVariant;
      expect(_hueDistance(muted, oliveGray), lessThan(8));
      expect(_contrast(muted, beige), greaterThanOrEqualTo(4.5));
    });

    test('focus rings and progress use deep olive, visible on a card', () {
      final ThemeData t = AppTheme.light;
      expect(t.progressIndicatorTheme.color, deepOlive);
      final OutlineInputBorder focus =
          t.inputDecorationTheme.focusedBorder! as OutlineInputBorder;
      expect(focus.borderSide.color, deepOlive);
      expect(_contrast(deepOlive, beige), greaterThanOrEqualTo(3.0));
    });

    test('body ink sits clearly above the muted text', () {
      final ColorScheme s = AppTheme.light.colorScheme;
      expect(
        _contrast(s.onSurface, beige) - _contrast(s.onSurfaceVariant, beige),
        greaterThan(3.0),
        reason: 'otherwise body copy and captions read as one weight',
      );
    });

    test('dark mode inks in cream', () {
      expect(AppTheme.dark.colorScheme.onSurface, cream);
    });

    test('glass cards are the palette beige over the cream page', () {
      expect(_rgb(AppGlass.light.fill), _rgb(beige));
      final Color card = _opaque(AppGlass.light.fill, cream);
      expect(card, isNot(cream), reason: 'cards must lift off the page');
    });

    testWidgets('the navigation bar is deep olive in both themes',
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
        expect(pane.color, deepOlive, reason: '${theme.brightness}');
      }
    });

    test('nav icons clear the 3:1 graphics floor on the bar', () {
      expect(_contrast(beige, deepOlive), greaterThanOrEqualTo(3.0),
          reason: 'idle icons');
      expect(_contrast(deepOlive, cream), greaterThanOrEqualTo(3.0),
          reason: 'active icon on its cream circle');
    });
  });

  group('Pastel Garden charts', () {
    test('light mode charts use only the four palette colours', () {
      const ChartColors c = ChartColors.light;
      expect(c.segments.take(4), <Color>[rose, deepBrown, grayGreen, blush]);
      expect(c.emphasis, deepBrown);
      expect(c.idle, rose);
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

    test('no chart colour borrows the app theme accents', () {
      final List<Color> theme = <Color>[deepOlive, oliveGray];
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
          for (final Color t in theme) {
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
