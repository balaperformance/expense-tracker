import 'package:flutter/material.dart';

/// One typography system for the whole app: a serif for voice, a sans for
/// work.
///
/// **Display serif.** Hero figures, headlines and page titles are set in the
/// platform serif — Noto Serif on Android, Georgia on iOS. Both ship with the
/// operating system, so the editorial character of the premium design costs
/// zero bytes of APK: no bundled font file, no runtime download.
///
/// **Working sans.** Everything the user scans — list rows, amounts in a
/// column, labels, buttons, body copy — stays in Roboto, which is the most
/// legible face at small sizes on the hardware this app targets.
///
/// The scale has seven jobs, and every screen uses these and nothing else:
///
///   display*          the one hero figure on a screen (serif)
///   headline*         large figures and headings inside a card (serif)
///   titleLarge        page title (serif)
///   titleMedium       list-row title and row amount (sans)
///   bodyLarge/Medium  body copy (sans)
///   bodySmall         secondary / supporting text (sans)
///   label*            buttons, field labels, chart axes, captions (sans)
///
/// Financial numbers additionally go through [AppTypography.money], which
/// applies tabular figures so digits occupy identical widths. Without it a
/// column of amounts visibly jitters as the digits change.
class AppTypography {
  const AppTypography._();

  /// The working sans.
  static const String fontFamily = 'Roboto';

  /// The display serif. `serif` is the Android system alias for Noto Serif;
  /// iOS has no such alias and falls through to [displayFallback].
  static const String displayFamily = 'serif';
  static const List<String> displayFallback = <String>[
    'Georgia',
    'Noto Serif',
    'Times New Roman',
  ];

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

  /// Heading above a group of cards — "Recent", "Accounts". Serif, so a
  /// section reads as a chapter of the page rather than as another label.
  static TextStyle section(TextTheme text) =>
      text.titleLarge!.copyWith(fontSize: 17, height: 1.25);

  /// Small tracked caps above a figure — "NET THIS MONTH". Callers pass the
  /// text already upper-cased; the style only adds the tracking.
  static TextStyle eyebrow(TextTheme text, {Color? color}) =>
      text.labelSmall!.copyWith(
        letterSpacing: 1.1,
        fontWeight: FontWeight.w600,
        color: color,
      );

  static TextStyle _serif({
    required double size,
    required double height,
    required double tracking,
    required Color color,
  }) {
    // Regular weight on purpose. The Android system serif ships Regular and
    // Bold only, and Bold at display size reads as a newspaper headline; the
    // size alone carries the hierarchy.
    return TextStyle(
      fontFamily: displayFamily,
      fontFamilyFallback: displayFallback,
      fontSize: size,
      height: height,
      fontWeight: FontWeight.w500,
      letterSpacing: tracking,
      color: color,
    );
  }

  static TextTheme textTheme(ColorScheme scheme) {
    final Color onSurface = scheme.onSurface;
    final Color muted = scheme.onSurfaceVariant;
    // Headings and figures share the body ink — black in light mode, the
    // palette's "primary dark elements" — so the serif tier leads by size
    // and face, not by a second colour.
    final Color headline = onSurface;

    return TextTheme(
      // The single hero figure on a screen.
      displayLarge: _serif(
          size: 34, height: 1.1, tracking: -0.6, color: headline),
      displayMedium: _serif(
          size: 30, height: 1.12, tracking: -0.5, color: headline),
      displaySmall: _serif(
          size: 28, height: 1.14, tracking: -0.4, color: headline),

      // Figures and headings inside a card.
      headlineLarge: _serif(
          size: 25, height: 1.18, tracking: -0.3, color: headline),
      headlineMedium: _serif(
          size: 21, height: 1.2, tracking: -0.2, color: headline),
      headlineSmall: _serif(
          size: 18.5, height: 1.22, tracking: -0.1, color: headline),

      // Page title.
      titleLarge: _serif(
          size: 21, height: 1.22, tracking: -0.2, color: headline),

      // List-row title and row amount.
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
        height: 1.4,
        color: onSurface,
      ),
      bodyMedium: TextStyle(
        fontFamily: fontFamily,
        fontSize: 13.5,
        height: 1.4,
        color: onSurface,
      ),
      // Secondary text. Muted by default so a row's title carries the
      // hierarchy without each caller having to restate the colour.
      bodySmall: TextStyle(
        fontFamily: fontFamily,
        fontSize: 12.5,
        height: 1.32,
        color: muted,
      ),

      // Buttons.
      labelLarge: TextStyle(
        fontFamily: fontFamily,
        fontSize: 14,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.15,
        color: onSurface,
      ),
      // Field labels.
      labelMedium: TextStyle(
        fontFamily: fontFamily,
        fontSize: 12.5,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
        color: muted,
      ),
      // Chart axes, eyebrows and fine print.
      labelSmall: TextStyle(
        fontFamily: fontFamily,
        fontSize: 11,
        height: 1.2,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.25,
        color: muted,
      ),
    );
  }
}
