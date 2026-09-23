import 'package:flutter/material.dart';

/// The app's colour system.
///
/// Light and dark are authored as two deliberate palettes rather than one
/// palette inverted. Inverting produces grey-on-grey financial figures and
/// flattens elevation, which is exactly where a money app has to stay
/// legible — so each mode gets its own surface ramp and its own semantic
/// tones, tuned for contrast against that mode's background.
///
/// Semantics are fixed across the app:
///   * [income] / positive  — green
///   * [expense] / negative — red
///   * [warning]            — amber, budget pressure only
///   * [brand]              — primary actions and selection only
/// Nothing decorative uses a semantic colour, so a green number always means
/// money in.
class AppColors {
  const AppColors._();

  // ---------------------------------------------------------------------
  // Brand
  // ---------------------------------------------------------------------

  /// Reserved for primary actions, selection and focus. Never used to carry
  /// financial meaning.
  static const Color brand = Color(0xFF4F46E5);
  static const Color brandDark = Color(0xFF8B93F8);

  // ---------------------------------------------------------------------
  // Semantic money tones
  // ---------------------------------------------------------------------

  static const Color income = Color(0xFF047857);
  static const Color incomeDark = Color(0xFF34D399);
  static const Color expense = Color(0xFFDC2626);
  static const Color expenseDark = Color(0xFFF87171);
  static const Color warning = Color(0xFFB45309);
  static const Color warningDark = Color(0xFFFBBF24);

  /// Transfers are movement, not earning or spending, so they get a neutral
  /// slate tone that cannot be mistaken for income green.
  static const Color transfer = Color(0xFF475569);
  static const Color transferDark = Color(0xFF94A3B8);

  // ---------------------------------------------------------------------
  // Light surface ramp
  // ---------------------------------------------------------------------

  /// Page background. Slightly cool and slightly darker than the cards, so
  /// card edges read without needing a shadow.
  static const Color lightBackground = Color(0xFFF5F6F9);
  static const Color lightSurface = Color(0xFFFFFFFF);

  /// Insets: input fills, muted wells, chart tracks.
  static const Color lightSunken = Color(0xFFEEF0F5);
  static const Color lightBorder = Color(0x14101828);
  static const Color lightText = Color(0xFF101828);
  static const Color lightTextMuted = Color(0xFF667085);

  // ---------------------------------------------------------------------
  // Dark surface ramp
  // ---------------------------------------------------------------------

  /// Near-black rather than pure black: pure black makes elevation invisible
  /// and haloes light text on OLED.
  static const Color darkBackground = Color(0xFF0C0E13);
  static const Color darkSurface = Color(0xFF161A21);
  static const Color darkSunken = Color(0xFF1E232C);
  static const Color darkBorder = Color(0x1FFFFFFF);
  static const Color darkText = Color(0xFFF2F4F7);
  static const Color darkTextMuted = Color(0xFF98A2B3);

  // ---------------------------------------------------------------------
  // Category swatches
  // ---------------------------------------------------------------------

  /// Offered when creating a category. Mid-tone on purpose: each one has to
  /// stay distinguishable on both the white and the near-black surface.
  static const List<String> categorySwatches = <String>[
    '#EF6C4D',
    '#3B82F6',
    '#A855F7',
    '#14B8A6',
    '#EC4899',
    '#F43F5E',
    '#0EA5E9',
    '#8B5CF6',
    '#64748B',
    '#22C55E',
    '#F59E0B',
    '#A16207',
  ];

  /// Neutral grey for the aggregated "Other" slice in charts.
  static const Color chartOther = Color(0xFF94A3B8);

  /// Category colours are stored per row as hex strings, so parsing is
  /// defensive: a malformed value must never crash a list build.
  static Color fromHex(String? hex, {Color fallback = brand}) {
    if (hex == null) return fallback;
    String value = hex.trim().replaceFirst('#', '');
    if (value.length == 6) value = 'FF$value';
    if (value.length != 8) return fallback;
    final int? parsed = int.tryParse(value, radix: 16);
    return parsed == null ? fallback : Color(parsed);
  }

  static String toHex(Color color) =>
      '#${color.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  /// Lifts a category colour so it stays legible on a dark surface.
  ///
  /// Saturated mid-tones chosen against white can drop below the contrast
  /// floor in dark mode; this raises lightness only when that has happened,
  /// leaving already-bright colours alone.
  static Color readableOn(Color color, Brightness brightness) {
    if (brightness == Brightness.light) return color;
    final HSLColor hsl = HSLColor.fromColor(color);
    if (hsl.lightness >= 0.58) return color;
    return hsl.withLightness(0.68).toColor();
  }
}
