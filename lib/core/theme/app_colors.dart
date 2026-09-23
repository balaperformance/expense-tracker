import 'package:flutter/material.dart';

/// The app's colour system — Gothic Noir, lit.
///
/// The palette's four colours keep their character but each has a narrow,
/// deliberate job, so no large surface is gray on gray:
///
///   black      #000000  the hero card only — the one dark, dramatic surface
///   lightGray  #D1D0D0  subtle fills: wells, tracks, hairlines
///   taupe      #988686  secondary elements: idle icons, dots, quiet accents
///   darkTaupe  #5C4E4E  the brand: primary actions, selection, navigation
///
/// Around them the page is a clean near-white and cards are white, lifted by
/// soft shadows rather than outlined — which is where the depth comes from.
/// Colour and energy come from a brighter set of semantic tones (emerald in,
/// rose out) and from the chart palette in `app_chart_colors.dart`, so the
/// UI reads as lively rather than monochrome.
///
/// Semantics are fixed across both themes:
///   * [income] / positive  — emerald
///   * [expense] / negative — rose red
///   * [warning]            — amber, budget pressure only
///   * [brand]              — primary actions and selection only
/// A green number always means money in.
class AppColors {
  const AppColors._();

  // ---------------------------------------------------------------------
  // Palette sources
  // ---------------------------------------------------------------------

  static const Color black = Color(0xFF000000);
  static const Color lightGray = Color(0xFFD1D0D0);
  static const Color taupe = Color(0xFF988686);
  static const Color darkTaupe = Color(0xFF5C4E4E);

  // ---------------------------------------------------------------------
  // Roles
  // ---------------------------------------------------------------------

  /// Primary actions — filled buttons, the FAB, text buttons, selection.
  static const Color brand = darkTaupe;

  /// Dark taupe is 2.2:1 on the dark surface; taupe carries the brand there.
  static const Color brandDark = taupe;

  /// The secondary accent: idle icons, page dots, quiet highlights.
  static const Color accent = taupe;

  /// Base colour for modal barriers.
  static const Color scrim = black;

  // ---------------------------------------------------------------------
  // Semantic money tones — brighter, still readable on white
  // ---------------------------------------------------------------------

  static const Color income = Color(0xFF0B875E);
  static const Color incomeDark = Color(0xFF34D399);
  static const Color expense = Color(0xFFE11D48);
  static const Color expenseDark = Color(0xFFFB7185);
  static const Color warning = Color(0xFFB45309);
  static const Color warningDark = Color(0xFFFBBF24);

  /// Transfers are movement, not earning or spending, so they get a
  /// desaturated slate that cannot be mistaken for income green.
  static const Color transfer = Color(0xFF64748B);
  static const Color transferDark = Color(0xFF94A3B8);

  // ---------------------------------------------------------------------
  // Light surface ramp — clean near-white, white cards
  // ---------------------------------------------------------------------

  /// The page: near-white with a whisper of the palette's warm gray, so the
  /// white cards lift off it without needing a border.
  static const Color lightBackground = Color(0xFFF5F4F4);
  static const Color lightSurface = Color(0xFFFFFFFF);

  /// Insets — input fills, wells, tracks: the palette's light gray, washed.
  static const Color lightSunken = Color(0x59D1D0D0);

  /// Hairlines are light gray and faint: depth comes from shadow, not rules.
  static const Color lightBorder = Color(0x80D1D0D0);
  static const Color lightText = Color(0xFF1A1616);
  static const Color lightTextMuted = Color(0xFF6F6363);

  // ---------------------------------------------------------------------
  // Dark surface ramp
  // ---------------------------------------------------------------------

  static const Color darkBackground = Color(0xFF0B0909);
  static const Color darkSurface = Color(0xFF1C1818);
  static const Color darkSunken = Color(0xFF272121);
  static const Color darkBorder = Color(0x1AD1D0D0);
  static const Color darkText = Color(0xFFF2F0F0);
  static const Color darkTextMuted = Color(0xFFA89E9E);

  // ---------------------------------------------------------------------
  // Hero surface
  // ---------------------------------------------------------------------

  /// The palette's black, shading into taupe-black: the one dark, dramatic
  /// surface on a light page.
  static const List<Color> heroLight = <Color>[
    black,
    Color(0xFF1C1616),
  ];

  /// In dark mode the hero lifts off the page instead of sinking into it.
  static const List<Color> heroDark = <Color>[
    Color(0xFF2A2222),
    Color(0xFF151111),
  ];

  /// Ink on the hero.
  static const Color heroInk = Color(0xFFF7F5F5);

  /// Eyebrows and badges on the hero: taupe, exact — 5.2:1 on the hero.
  static const Color heroAccent = taupe;

  // ---------------------------------------------------------------------
  // Category swatches
  // ---------------------------------------------------------------------

  /// Offered when creating a category. Mid-tone and spread around the wheel
  /// on purpose: each one has to stay distinguishable on both the light and
  /// the dark surface. These are user data, not theme — a category keeps the
  /// colour it was saved with.
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
  /// Saturated mid-tones chosen against a light sheet can drop below the
  /// contrast floor in dark mode; this raises lightness only when that has
  /// happened, leaving already-bright colours alone.
  static Color readableOn(Color color, Brightness brightness) {
    if (brightness == Brightness.light) return color;
    final HSLColor hsl = HSLColor.fromColor(color);
    if (hsl.lightness >= 0.58) return color;
    return hsl.withLightness(0.68).toColor();
  }
}
