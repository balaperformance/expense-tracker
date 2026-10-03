// Theme tests.
//
// Light and dark are authored as two separate palettes rather than one
// inverted, so the things that could silently break are contrast and the
// distinguishability of the semantic colours. Both are measurable, so they
// are measured here instead of being eyeballed.

import 'dart:math' as math;

import 'package:expense_tracker/core/theme/app_colors.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/core/theme/app_typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Relative luminance, per WCAG 2.1.
double _luminance(Color c) {
  double channel(int v) {
    final double s = v / 255.0;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4) as double;
  }

  return 0.2126 * channel(c.red) +
      0.7152 * channel(c.green) +
      0.0722 * channel(c.blue);
}

/// WCAG contrast ratio between two opaque colours, 1.0 to 21.0.
double _contrast(Color a, Color b) {
  final double la = _luminance(a);
  final double lb = _luminance(b);
  final double lighter = math.max(la, lb);
  final double darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

/// Flattens a translucent colour over a background, which is what the eye
/// actually sees for the tinted wells the app uses everywhere.
Color _over(Color fg, Color bg) => Color.alphaBlend(fg, bg);

/// Shortest distance between two hues on the colour wheel, in degrees.
double _hueDistance(Color a, Color b) {
  final double ha = HSLColor.fromColor(a).hue;
  final double hb = HSLColor.fromColor(b).hue;
  final double raw = (ha - hb).abs();
  return raw > 180 ? 360 - raw : raw;
}

void main() {
  final Map<String, ThemeData> themes = <String, ThemeData>{
    'light': AppTheme.light,
    'dark': AppTheme.dark,
  };

  group('surface ramp', () {
    themes.forEach((String name, ThemeData theme) {
      test('$name: body text clears WCAG AA on the card surface', () {
        final double ratio = _contrast(
          theme.colorScheme.onSurface,
          theme.colorScheme.surface,
        );
        expect(ratio, greaterThanOrEqualTo(4.5), reason: '$name onSurface');
      });

      test('$name: secondary text clears WCAG AA', () {
        // bodySmall is used for every caption and meta line in the app, so it
        // has to be readable rather than merely present.
        final double ratio = _contrast(
          theme.colorScheme.onSurfaceVariant,
          theme.colorScheme.surface,
        );
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: '$name onSurfaceVariant');
      });

      test('$name: card surface is distinguishable from the page', () {
        // The app uses no card shadow, so the surface/background step is the
        // only thing separating a card from the page behind it.
        expect(
          theme.colorScheme.surface,
          isNot(theme.scaffoldBackgroundColor),
          reason: '$name surface equals background — cards would vanish',
        );
      });

      test('$name: primary button label is readable on the button',
          () {
        final double ratio = _contrast(
          theme.colorScheme.onPrimary,
          theme.colorScheme.primary,
        );
        expect(ratio, greaterThanOrEqualTo(4.5), reason: '$name onPrimary');
      });
    });
  });

  group('semantic money colours', () {
    final Map<String, (Color income, Color expense, Color warning, Color transfer, Color surface)>
        modes = <String, (Color, Color, Color, Color, Color)>{
      'light': (
        AppColors.income,
        AppColors.expense,
        AppColors.warning,
        AppColors.transfer,
        AppColors.lightSurface,
      ),
      'dark': (
        AppColors.incomeDark,
        AppColors.expenseDark,
        AppColors.warningDark,
        AppColors.transferDark,
        AppColors.darkSurface,
      ),
    };

    modes.forEach((String name, (Color, Color, Color, Color, Color) c) {
      final Color income = c.$1;
      final Color expense = c.$2;
      final Color warning = c.$3;
      final Color transfer = c.$4;
      final Color surface = c.$5;

      test('$name: an amount is readable on a card', () {
        // 3.0 is the WCAG AA floor for large/bold text, which is what every
        // coloured amount in this app is.
        for (final (String, Color) entry in <(String, Color)>[
          ('income', income),
          ('expense', expense),
          ('warning', warning),
          ('transfer', transfer),
        ]) {
          expect(
            _contrast(entry.$2, surface),
            greaterThanOrEqualTo(3.0),
            reason: '$name ${entry.$1} on surface',
          );
        }
      });

      test('$name: income and expense are far apart in hue', () {
        // Measured as hue distance, not luminance contrast: red and green can
        // sit at almost identical luminance — that is precisely why
        // red/green confusion exists — while being plainly different colours.
        // Luminance is the wrong instrument for "are these two hues
        // distinguishable".
        expect(
          _hueDistance(income, expense),
          greaterThanOrEqualTo(90),
          reason: '$name income vs expense hue',
        );
      });

      test('$name: a transfer cannot be mistaken for income', () {
        // Two independent signals, because either alone is weak: the hues are
        // separated, and the transfer tone is deliberately desaturated slate
        // against a saturated green.
        expect(
          _hueDistance(transfer, income),
          greaterThanOrEqualTo(30),
          reason: '$name transfer vs income hue',
        );
        expect(
          HSLColor.fromColor(transfer).saturation,
          lessThan(HSLColor.fromColor(income).saturation - 0.2),
          reason: '$name transfer is not desaturated enough vs income',
        );
      });

      test('$name: tinted wells stay visible against the surface', () {
        // Icon wells are the tone at low opacity. In dark mode a 10% wash
        // over near-black is invisible, which is why ToneColors.wash uses a
        // stronger alpha there.
        final double alpha = name == 'dark' ? 0.20 : 0.11;
        for (final Color tone in <Color>[income, expense, warning]) {
          final Color well = _over(tone.withOpacity(alpha), surface);
          expect(
            _contrast(well, surface),
            greaterThan(1.03),
            reason: '$name well for $tone is invisible',
          );
        }
      });
    });
  });

  group('category colours', () {
    test('every swatch parses', () {
      for (final String hex in AppColors.categorySwatches) {
        final Color parsed = AppColors.fromHex(hex, fallback: Colors.black);
        expect(parsed, isNot(Colors.black), reason: 'unparsed swatch $hex');
      }
    });

    test('dark mode lifts a swatch that would be too dark', () {
      const Color deep = Color(0xFF1A1A2E);
      final Color lifted = AppColors.readableOn(deep, Brightness.dark);
      expect(
        _contrast(lifted, AppColors.darkSurface),
        greaterThan(_contrast(deep, AppColors.darkSurface)),
      );
    });

    test('light mode leaves a swatch untouched', () {
      for (final String hex in AppColors.categorySwatches) {
        final Color base = AppColors.fromHex(hex);
        expect(AppColors.readableOn(base, Brightness.light), base);
      }
    });

    test('an already bright colour is not lifted further', () {
      const Color bright = Color(0xFFEEEEEE);
      expect(AppColors.readableOn(bright, Brightness.dark), bright);
    });

    test('a malformed hex falls back instead of throwing', () {
      expect(AppColors.fromHex('not-a-colour'), AppColors.brand);
      expect(AppColors.fromHex(null), AppColors.brand);
      expect(AppColors.fromHex('#12'), AppColors.brand);
    });
  });

  group('typography', () {
    themes.forEach((String name, ThemeData theme) {
      test('$name: the type scale is complete and ordered', () {
        final TextTheme t = theme.textTheme;

        // Every style the app uses must exist; a null here renders as a
        // silent fallback that breaks the hierarchy.
        for (final TextStyle? style in <TextStyle?>[
          t.displayLarge,
          t.displayMedium,
          t.displaySmall,
          t.headlineLarge,
          t.headlineMedium,
          t.headlineSmall,
          t.titleLarge,
          t.titleMedium,
          t.titleSmall,
          t.bodyLarge,
          t.bodyMedium,
          t.bodySmall,
          t.labelLarge,
          t.labelMedium,
          t.labelSmall,
        ]) {
          expect(style, isNotNull);
          // Every style names its family explicitly — the working sans or
          // the display serif — so nothing falls back to a platform default.
          expect(
            style!.fontFamily,
            anyOf(AppTypography.fontFamily, AppTypography.displayFamily),
          );
          // `serif` is an Android alias only. Without the fallback chain iOS
          // would silently render every headline in the system sans.
          if (style.fontFamily == AppTypography.displayFamily) {
            expect(style.fontFamilyFallback, AppTypography.displayFallback);
          }
        }

        // The voice/work split: headlines and page titles are serif, anything
        // scanned in a list is sans.
        expect(t.displaySmall!.fontFamily, AppTypography.displayFamily);
        expect(t.titleLarge!.fontFamily, AppTypography.displayFamily);
        expect(t.titleMedium!.fontFamily, AppTypography.fontFamily);
        expect(t.bodySmall!.fontFamily, AppTypography.fontFamily);

        // Hierarchy has to actually descend, or "compact" just means "small".
        expect(t.displaySmall!.fontSize!, greaterThan(t.headlineSmall!.fontSize!));
        expect(t.headlineSmall!.fontSize!, greaterThan(t.titleMedium!.fontSize!));
        expect(t.titleMedium!.fontSize!, greaterThan(t.bodySmall!.fontSize!));
        expect(t.bodySmall!.fontSize!, greaterThan(t.labelSmall!.fontSize!));
      });
    });

    test('money styles use tabular figures', () {
      final TextStyle style = AppTypography.money(
        const TextStyle(fontSize: 14),
      );
      expect(style.fontFeatures, contains(const FontFeature.tabularFigures()));
    });

    test('money emphasis bumps the weight without losing tabular figures', () {
      final TextStyle style = AppTypography.money(
        const TextStyle(fontSize: 14),
        emphasis: true,
      );
      expect(style.fontWeight, FontWeight.w700);
      expect(style.fontFeatures, contains(const FontFeature.tabularFigures()));
    });

    test('money tolerates a null base style', () {
      expect(
        AppTypography.money(null).fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    });
  });

  group('component theming is centralised', () {
    themes.forEach((String name, ThemeData theme) {
      test('$name: cards, inputs and sheets are themed', () {
        // These are the defaults every screen relies on. If one is null the
        // screens fall back to Material defaults and the app looks mixed.
        expect(theme.cardTheme.shape, isNotNull);
        expect(theme.inputDecorationTheme.filled, isTrue);
        expect(theme.bottomSheetTheme.shape, isNotNull);
        expect(theme.filledButtonTheme.style, isNotNull);
        expect(theme.navigationBarTheme.height, isNotNull);
        expect(theme.dividerTheme.color, isNotNull);
      });

      test('$name: no card elevation, so shadows cannot stack', () {
        expect(theme.cardTheme.elevation, 0);
      });
    });
  });
}
