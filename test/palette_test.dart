// Palette tests: Gothic Noir, lit — and the rich chart palette.
//
// The theme tests already measure contrast and hue separation. These pin the
// redesign's intent: black reserved for the hero, a light and clean page with
// white cards rather than gray on gray, dark taupe as the brand, and charts
// that are genuinely colourful rather than another shade of taupe.

import 'dart:math' as math;

import 'package:expense_tracker/core/theme/app_chart_colors.dart';
import 'package:expense_tracker/core/theme/app_colors.dart';
import 'package:expense_tracker/core/theme/app_glass.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/analytics.dart';
import 'package:expense_tracker/widgets/charts/category_breakdown.dart';
import 'package:expense_tracker/widgets/common/glass_nav_bar.dart';
import 'package:expense_tracker/widgets/common/hero_surface.dart';
import 'package:expense_tracker/widgets/stat_tiles.dart';
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
  const Color black = Color(0xFF000000);
  const Color lightGray = Color(0xFFD1D0D0);
  const Color taupe = Color(0xFF988686);
  const Color darkTaupe = Color(0xFF5C4E4E);

  group('Gothic Noir, lit', () {
    test('the four palette colours are the source tokens, exactly', () {
      expect(AppColors.black, black);
      expect(AppColors.lightGray, lightGray);
      expect(AppColors.taupe, taupe);
      expect(AppColors.darkTaupe, darkTaupe);
    });

    test('the page is light and clean; cards are white, not gray', () {
      final ThemeData t = AppTheme.light;
      expect(
        HSLColor.fromColor(t.scaffoldBackgroundColor).lightness,
        greaterThan(0.94),
        reason: 'a light, clean page — not the palette gray',
      );
      expect(t.colorScheme.surface, Colors.white);
      expect(t.scaffoldBackgroundColor, isNot(t.colorScheme.surface));
    });

    test('depth comes from shadow, not outlines', () {
      // The hairline is nearly invisible against a white card …
      final Color edge = _opaque(AppGlass.light.borderBottom, Colors.white);
      expect(_contrast(edge, Colors.white), lessThan(1.2));
      // … and every card carries a layered shadow.
      expect(AppGlass.light.shadow.length, greaterThanOrEqualTo(2));
    });

    test('light gray is kept to subtle fills', () {
      const Color sunken = AppColors.lightSunken;
      expect((sunken.red, sunken.green, sunken.blue),
          (lightGray.red, lightGray.green, lightGray.blue));
      expect(sunken.alpha, lessThan(255), reason: 'a wash, not a surface');
    });

    test('dark taupe is the brand; taupe is secondary', () {
      final ColorScheme light = AppTheme.light.colorScheme;
      expect(light.primary, darkTaupe);
      expect(light.onPrimary, Colors.white);
      expect(_contrast(light.onPrimary, light.primary),
          greaterThanOrEqualTo(7.0));
      for (final ThemeData t in <ThemeData>[AppTheme.light, AppTheme.dark]) {
        expect(t.colorScheme.secondary, taupe);
      }
    });

    test('black is reserved for the hero', () {
      expect(AppColors.heroLight.first, black);
      final ThemeData t = AppTheme.light;
      expect(t.scaffoldBackgroundColor, isNot(black));
      expect(t.colorScheme.surface, isNot(black));
      expect(t.colorScheme.onSurface, isNot(black),
          reason: 'body ink is a warm near-black, not the hero black');
    });

    test('the hero spend bar track is a soft white, not a money tone', () {
      const Color track = AppColors.heroTrack;
      expect((track.red, track.green, track.blue),
          (AppColors.heroInk.red, AppColors.heroInk.green, AppColors.heroInk.blue));
      expect(track.alpha, lessThan(80), reason: 'subtle, not a second bar');
      expect(track, isNot(AppColors.income));
      expect(track, isNot(AppColors.incomeDark));
    });

    test('the Net card glow is a cool neutral, not a money tone', () {
      final HSLColor glow = HSLColor.fromColor(AppColors.heroGlow);
      expect(glow.saturation, lessThan(0.25), reason: 'a blue-gray');
      expect(glow.hue, inInclusiveRange(200, 230), reason: 'cool, not green');
    });

    for (final (String name, double income, double expense)
        in <(String, double, double)>[
      ('ahead', 110000, 9600),
      ('behind', 1000, 9600),
    ]) {
      testWidgets('Net card ($name): green only on Income',
          (WidgetTester tester) async {
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: BalanceCard(
              income: income,
              expense: expense,
              currency: 'INR',
              monthLabel: 'Sep',
            ),
          ),
        ));
        await tester.pumpAndSettle();

        final HeroSurface hero = tester.widget(find.byType(HeroSurface));
        expect(hero.glow, AppColors.heroGlow);

        final List<Color?> inks = tester
            .widgetList<Text>(find.descendant(
              of: find.byType(BalanceCard),
              matching: find.byType(Text),
            ))
            .map((Text t) => t.style?.color)
            .toList();
        expect(inks.where((Color? c) => c == AppColors.incomeDark),
            hasLength(1),
            reason: 'only the Income figure is green');
        expect(inks, contains(AppColors.heroInk),
            reason: 'the net figure is neutral ink');
      });
    }

    test('money tones are brighter but still readable on a white card', () {
      for (final Color tone in <Color>[
        AppColors.income,
        AppColors.expense,
        AppColors.warning,
      ]) {
        expect(HSLColor.fromColor(tone).saturation, greaterThan(0.75),
            reason: '$tone should be lively, not muted');
        expect(_contrast(tone, Colors.white), greaterThanOrEqualTo(4.5),
            reason: '$tone must still read as text');
      }
    });

    testWidgets('the nav bar is a light pill with a brand-filled selection',
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
        // MaterialApp animates between themes; let it land first.
        await tester.pumpAndSettle();

        final GlassSurface pane = tester.widget(find.descendant(
          of: find.byType(GlassNavBar),
          matching: find.byType(GlassSurface),
        ));
        expect(pane.color, isNull, reason: 'the bar takes the theme glass');
        expect(pane.opaque, isTrue);

        final Iterable<Color?> fills = tester
            .widgetList<DecoratedBox>(find.descendant(
              of: find.byType(AnimatedPositioned),
              matching: find.byType(DecoratedBox),
            ))
            .map((DecoratedBox b) => (b.decoration as BoxDecoration).color);
        expect(fills, contains(theme.colorScheme.primary),
            reason: '${theme.brightness}: selection is the brand');
      }
    });
  });

  group('rich charts', () {
    for (final (String name, ChartColors c, Color card)
        in <(String, ChartColors, Color)>[
      ('light', ChartColors.light, AppColors.lightSurface),
      ('dark', ChartColors.dark, AppColors.darkSurface),
    ]) {
      test('$name: every slice is rich but not neon', () {
        for (final Color colour in <Color>[
          ...c.segments,
          c.emphasis,
          c.expense,
          c.income,
        ]) {
          final double s = HSLColor.fromColor(colour).saturation;
          expect(s, greaterThan(0.3), reason: '$colour: a colour, not a gray');
          expect(s, lessThan(0.7), reason: '$colour: muted, not neon');
        }
      });

      test('$name: every slice is visible on its card', () {
        for (final Color colour in c.segments) {
          expect(_contrast(colour, card), greaterThanOrEqualTo(3.0),
              reason: '$colour');
        }
      });

      test('$name: neighbouring slices sit far apart in hue', () {
        final List<Color> s = c.segments;
        for (int i = 0; i < s.length; i++) {
          final Color next = s[(i + 1) % s.length];
          expect(_hueDistance(s[i], next), greaterThanOrEqualTo(90),
              reason: '${s[i]} next to $next');
        }
      });

      test('$name: six named slices never repeat a colour', () {
        final Set<Color> used = <Color>{
          for (int i = 0; i < 6; i++) c.segment(i, 6),
        };
        expect(used, hasLength(6));
      });

      test('$name: no chart colour is a theme colour', () {
        for (final Color colour in <Color>[
          ...c.segments,
          c.emphasis,
          c.expense,
        ]) {
          for (final Color t in <Color>[darkTaupe, taupe, black, lightGray]) {
            expect(colour, isNot(t));
          }
        }
      });

      test('$name: the selected bar stands out and its label reads', () {
        expect(_contrast(c.emphasis, card), greaterThanOrEqualTo(3.0));
        final Color pill = _opaque(c.emphasis.withOpacity(0.18), card);
        expect(_contrast(c.labelOnEmphasis, pill), greaterThanOrEqualTo(4.5));
      });

      test('$name: "Other" stays visible but quiet', () {
        expect(_contrast(c.other, card), greaterThan(1.5));
        expect(HSLColor.fromColor(c.other).saturation, lessThan(0.2));
      });
    }

    test('every dark-mode slice is visible on the dark card', () {
      for (final Color colour in ChartColors.dark.segments) {
        expect(
          _contrast(colour, AppColors.darkSurface),
          greaterThanOrEqualTo(3.0),
          reason: '$colour',
        );
      }
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
        ChartColors.light.segments.take(3),
      );
    });
  });
}
