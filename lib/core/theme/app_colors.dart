import 'package:flutter/material.dart';

/// The app's colour system — the Cappuccino palette.
///
/// Four source colours drive everything:
///
///   tan       #D6B588  accent, dark-mode primary, highlights
///   oat       #C6C0B9  neutral stone, muted text in dark mode
///   mocha     #705E46  light-mode primary, secondary text
///   espresso  #422701  the hero surface and the deepest ink
///
/// Light and dark are authored as two deliberate palettes rather than one
/// palette inverted: light mode is warm ivory with espresso ink, dark mode is
/// roasted charcoal with cream ink and tan accents. Each gets its own surface
/// ramp and its own semantic tones, tuned for contrast against that mode's
/// background.
///
/// Semantics are fixed across the app:
///   * [income] / positive  — sage green
///   * [expense] / negative — terracotta
///   * [warning]            — ochre, budget pressure only
///   * [brand]              — primary actions and selection only
/// The money tones are warmed to sit inside the palette, but they stay far
/// apart in hue, so a green number still always means money in.
class AppColors {
  const AppColors._();

  // ---------------------------------------------------------------------
  // Palette sources
  // ---------------------------------------------------------------------

  static const Color tan = Color(0xFFD6B588);
  static const Color oat = Color(0xFFC6C0B9);
  static const Color mocha = Color(0xFF705E46);
  static const Color espresso = Color(0xFF422701);

  /// Cream ink for text that sits on the espresso hero surface.
  static const Color cream = Color(0xFFFBF4EA);

  // ---------------------------------------------------------------------
  // Brand
  // ---------------------------------------------------------------------

  /// Reserved for primary actions, selection and focus. Never used to carry
  /// financial meaning.
  static const Color brand = mocha;
  static const Color brandDark = tan;

  // ---------------------------------------------------------------------
  // Semantic money tones
  // ---------------------------------------------------------------------

  static const Color income = Color(0xFF3B7A55);
  static const Color incomeDark = Color(0xFF8CC9A0);
  static const Color expense = Color(0xFFB0473A);
  static const Color expenseDark = Color(0xFFE8907C);
  static const Color warning = Color(0xFF9C6412);
  static const Color warningDark = Color(0xFFE3B45A);

  /// Transfers are movement, not earning or spending, so they get a
  /// desaturated taupe that cannot be mistaken for income green.
  static const Color transfer = Color(0xFF7A7167);
  static const Color transferDark = Color(0xFFADA59B);

  // ---------------------------------------------------------------------
  // Light surface ramp — warm ivory
  // ---------------------------------------------------------------------

  /// Page background. A touch darker and warmer than the cards, so a card
  /// edge reads without relying on the shadow.
  static const Color lightBackground = Color(0xFFF4EFE7);
  static const Color lightSurface = Color(0xFFFFFCF7);

  /// Insets: input fills, muted wells, chart tracks.
  static const Color lightSunken = Color(0xFFEDE6DB);
  static const Color lightBorder = Color(0x1A422701);
  static const Color lightText = Color(0xFF2A1D10);
  static const Color lightTextMuted = Color(0xFF6E5C45);

  // ---------------------------------------------------------------------
  // Dark surface ramp — roasted charcoal
  // ---------------------------------------------------------------------

  /// Warm near-black rather than pure black: pure black makes elevation
  /// invisible and haloes light text on OLED.
  static const Color darkBackground = Color(0xFF13100D);
  static const Color darkSurface = Color(0xFF1F1A15);
  static const Color darkSunken = Color(0xFF2A241E);
  static const Color darkBorder = Color(0x1FF4EDE4);
  static const Color darkText = Color(0xFFF4EDE4);
  static const Color darkTextMuted = Color(0xFFAA9E91);

  // ---------------------------------------------------------------------
  // Hero surface
  // ---------------------------------------------------------------------

  /// The espresso gradient behind the dashboard snapshot. The light stop is
  /// held at #5A4631 rather than the palette's mocha so the terracotta
  /// expense figure keeps at least 3.7:1 anywhere on the card.
  static const List<Color> heroLight = <Color>[
    Color(0xFF3F2A12),
    Color(0xFF5A4631),
  ];

  /// In dark mode the hero lifts off the page instead of sinking into it.
  static const List<Color> heroDark = <Color>[
    Color(0xFF3A2C1E),
    Color(0xFF261E16),
  ];

  // ---------------------------------------------------------------------
  // Category swatches
  // ---------------------------------------------------------------------

  /// Offered when creating a category. Earthy to sit inside the palette, but
  /// spread around the wheel and mid-tone on purpose: each one has to stay
  /// distinguishable on both the ivory and the charcoal surface.
  static const List<String> categorySwatches = <String>[
    '#C2703D',
    '#4F7CAC',
    '#8E6BA8',
    '#3F8F84',
    '#C0587E',
    '#B84A4A',
    '#4A9BB5',
    '#7466B0',
    '#7A6E62',
    '#5E9A5A',
    '#D19A2E',
    '#8C6A43',
  ];

  /// Neutral stone for the aggregated "Other" slice in charts.
  static const Color chartOther = Color(0xFFA89D90);

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
  /// Saturated mid-tones chosen against ivory can drop below the contrast
  /// floor in dark mode; this raises lightness only when that has happened,
  /// leaving already-bright colours alone.
  static Color readableOn(Color color, Brightness brightness) {
    if (brightness == Brightness.light) return color;
    final HSLColor hsl = HSLColor.fromColor(color);
    if (hsl.lightness >= 0.58) return color;
    return hsl.withLightness(0.68).toColor();
  }
}
