import 'package:flutter/material.dart';

/// One typography system for the whole app.
///
/// Roboto is named explicitly rather than left to the platform default: it
/// ships with Flutter on every platform, so the hierarchy below renders
/// identically on Android and iOS instead of silently reflowing.
///
/// The scale has seven jobs, and every screen uses these and nothing else:
///
///   display*        the one hero figure on a screen (total balance)
///   headline*       large financial figures inside a card
///   titleLarge      page title
///   titleMedium     section title and list-row title
///   bodyLarge/Medium  body copy
///   bodySmall       secondary / supporting text
///   label*          buttons, field labels, chart axes, captions
///
/// Financial numbers additionally go through [AppTypography.money], which
/// applies tabular figures so digits occupy identical widths. Without it a
/// column of amounts visibly jitters as the digits change, which is the
/// single most common reason a money list looks unprofessional.
class AppTypography {
  const AppTypography._();

  static const String fontFamily = 'Roboto';

  /// Fixed-width digits. Applied to every amount the user might compare
  /// against another amount — which is nearly all of them.
  static const List<FontFeature> tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  /// Returns [style] with tabular figures enabled.
  ///
  /// Use for any rendered currency value. [emphasis] additionally bumps the
  /// weight, for the amount on a transaction row where the amount is the
  /// thing being scanned.
  static TextStyle money(TextStyle? style, {bool emphasis = false}) {
    final TextStyle base = style ?? const TextStyle();
    return base.copyWith(
      fontFeatures: tabular,
      fontWeight: emphasis ? FontWeight.w700 : base.fontWeight,
    );
  }

  static TextTheme textTheme(ColorScheme scheme) {
    final Color onSurface = scheme.onSurface;
    final Color muted = scheme.onSurfaceVariant;

    return TextTheme(
      // The single hero figure on a screen.
      displayLarge: TextStyle(
        fontFamily: fontFamily,
        fontSize: 34,
        height: 1.1,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.4,
        color: onSurface,
      ),
      displayMedium: TextStyle(
        fontFamily: fontFamily,
        fontSize: 29,
        height: 1.12,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.1,
        color: onSurface,
      ),
      displaySmall: TextStyle(
        fontFamily: fontFamily,
        fontSize: 24,
        height: 1.15,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
        color: onSurface,
      ),

      // Large figures inside a card.
      headlineLarge: TextStyle(
        fontFamily: fontFamily,
        fontSize: 22,
        height: 1.18,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
        color: onSurface,
      ),
      headlineMedium: TextStyle(
        fontFamily: fontFamily,
        fontSize: 19.5,
        height: 1.2,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.45,
        color: onSurface,
      ),
      headlineSmall: TextStyle(
        fontFamily: fontFamily,
        fontSize: 17,
        height: 1.22,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: onSurface,
      ),

      // Page title.
      titleLarge: TextStyle(
        fontFamily: fontFamily,
        fontSize: 18,
        height: 1.22,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.35,
        color: onSurface,
      ),
      // Section title and list-row title.
      titleMedium: TextStyle(
        fontFamily: fontFamily,
        fontSize: 15,
        height: 1.3,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
        color: onSurface,
      ),
      titleSmall: TextStyle(
        fontFamily: fontFamily,
        fontSize: 13.5,
        height: 1.3,
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),

      bodyLarge: TextStyle(
        fontFamily: fontFamily,
        fontSize: 15,
        height: 1.35,
        color: onSurface,
      ),
      bodyMedium: TextStyle(
        fontFamily: fontFamily,
        fontSize: 13.5,
        height: 1.35,
        color: onSurface,
      ),
      // Secondary text. Muted by default so a row's title carries the
      // hierarchy without each caller having to restate the colour.
      bodySmall: TextStyle(
        fontFamily: fontFamily,
        fontSize: 12.5,
        height: 1.3,
        color: muted,
      ),

      // Buttons.
      labelLarge: TextStyle(
        fontFamily: fontFamily,
        fontSize: 14,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        color: onSurface,
      ),
      // Field labels and section eyebrows.
      labelMedium: TextStyle(
        fontFamily: fontFamily,
        fontSize: 12.5,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
        color: muted,
      ),
      // Chart axes and fine print.
      labelSmall: TextStyle(
        fontFamily: fontFamily,
        fontSize: 11,
        height: 1.2,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.2,
        color: muted,
      ),
    );
  }
}
