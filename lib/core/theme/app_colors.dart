import 'package:flutter/material.dart';

/// The app's colour system — the Old Photograph palette.
///
/// Four source colours drive the whole UI:
///
///   cream      #FDFBD4  the page, and ink on dark surfaces
///   beige      #D9D7B6  cards and secondary surfaces
///   oliveGray  #878672  the secondary accent
///   deepOlive  #545333  primary actions, navigation, headings and figures
///
/// Charts are the one exception and draw from their own palette — see
/// `app_chart_colors.dart`.
///
/// **Where the palette is shaded, and why.** Two roles cannot use a source
/// colour exactly without failing the contrast floors the theme tests hold:
///
///   * Olive gray is 2.5:1 on a beige card — under even the 3:1 floor for an
///     icon. It is used exactly where it sits on the cream page (page dots,
///     washes) and as the dark-mode accent; icons, focus rings and progress
///     inside cards use deep olive instead, and secondary *text* uses
///     [oliveGrayDeep], the same hue deepened to 4.9:1.
///   * Deep olive is 5.4:1 on beige — fine for headings, but too close to the
///     muted text for body copy to keep a hierarchy. Body copy uses [oliveInk]
///     (9.4:1); deep olive carries the important text: headings and figures.
///
/// Light and dark are authored as two palettes rather than one inverted:
/// light is cream paper with beige cards, dark is deep olive-black with
/// cream ink. Semantics are fixed across both:
///   * [income] / positive  — green
///   * [expense] / negative — crimson
///   * [warning]            — amber, budget pressure only
///   * [brand]              — primary actions and selection only
/// A green number always means money in.
class AppColors {
  const AppColors._();

  // ---------------------------------------------------------------------
  // Palette sources
  // ---------------------------------------------------------------------

  static const Color cream = Color(0xFFFDFBD4);
  static const Color beige = Color(0xFFD9D7B6);
  static const Color oliveGray = Color(0xFF878672);
  static const Color deepOlive = Color(0xFF545333);

  /// Olive gray deepened for secondary text on a beige card (4.9:1).
  static const Color oliveGrayDeep = Color(0xFF5A5944);

  /// Body ink: deep olive taken nearly to black, so body copy sits clearly
  /// above the muted text and below nothing.
  static const Color oliveInk = Color(0xFF2F2E1C);

  // ---------------------------------------------------------------------
  // Roles
  // ---------------------------------------------------------------------

  /// Primary actions — filled buttons, the FAB, text buttons, links — and
  /// the important text.
  static const Color brand = deepOlive;
  static const Color brandDark = beige;

  /// The secondary accent, for highlights that carry no text.
  static const Color accent = oliveGray;

  /// The floating navigation bar.
  static const Color navBar = deepOlive;

  /// Base colour for modal barriers: olive-black rather than pure black,
  /// which on cream read as a dirty film.
  static const Color scrim = Color(0xFF1F1F14);

  // ---------------------------------------------------------------------
  // Semantic money tones
  // ---------------------------------------------------------------------

  // Deepened from the previous theme's values: beige cards are far darker
  // than white ones, and every amount still has to clear 4.4:1 on them.
  static const Color income = Color(0xFF1F6B4C);
  static const Color incomeDark = Color(0xFF7DC9A2);
  static const Color expense = Color(0xFF9E2F3D);
  static const Color expenseDark = Color(0xFFEE8A93);
  static const Color warning = Color(0xFF7E520C);
  static const Color warningDark = Color(0xFFE4B862);

  /// Transfers are movement, not earning or spending, so they get a
  /// near-neutral gray that cannot be mistaken for income green.
  static const Color transfer = Color(0xFF5E625E);
  static const Color transferDark = Color(0xFFAEB3B8);

  // ---------------------------------------------------------------------
  // Light surface ramp — cream paper, beige cards
  // ---------------------------------------------------------------------

  static const Color lightBackground = cream;
  static const Color lightSurface = beige;

  /// Insets — input fills, wells, tracks: a faint deep-olive wash, so a
  /// field reads as recessed on the cream page and on a beige card alike.
  static const Color lightSunken = Color(0x14545333);
  static const Color lightBorder = Color(0x2E545333);
  static const Color lightText = oliveInk;
  static const Color lightTextMuted = oliveGrayDeep;

  // ---------------------------------------------------------------------
  // Dark surface ramp — olive-black
  // ---------------------------------------------------------------------

  /// Near-black with an olive cast rather than pure black: pure black makes
  /// elevation invisible and haloes light text on OLED.
  static const Color darkBackground = Color(0xFF1A1A12);
  static const Color darkSurface = Color(0xFF27271B);
  static const Color darkSunken = Color(0xFF333324);
  static const Color darkBorder = Color(0x1FFDFBD4);
  static const Color darkText = cream;
  static const Color darkTextMuted = Color(0xFFB0AE93);

  // ---------------------------------------------------------------------
  // Hero surface
  // ---------------------------------------------------------------------

  /// The deep-olive gradient behind the one headline figure on a screen. The
  /// light stop is held darker than the palette's #545333 so the muted labels
  /// keep 4.5:1 anywhere on the card.
  static const List<Color> heroLight = <Color>[
    Color(0xFF34331F),
    Color(0xFF424128),
  ];

  /// In dark mode the hero lifts off the page instead of sinking into it.
  static const List<Color> heroDark = <Color>[
    Color(0xFF3A3923),
    Color(0xFF2A2A1B),
  ];

  /// Ink on the hero.
  static const Color heroInk = cream;

  /// Eyebrows, badges and glows on the hero.
  static const Color heroAccent = beige;

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
