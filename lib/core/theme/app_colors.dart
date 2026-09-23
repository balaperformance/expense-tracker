import 'package:flutter/material.dart';

/// The app's colour system — the Ink Wash palette.
///
/// Four source colours drive the whole UI:
///
///   charcoal   #4A4A4A  ink: headings, body text, navigation, dark surfaces
///   coolGray   #CBCBCB  secondary surfaces, borders, idle icons on dark
///   ivory      #FFFEE3  the page, and ink on dark surfaces
///   blueGray   #6D8196  the accent: highlights, focus, selection
///
/// Charts are the one exception and draw from their own palette — see
/// `app_chart_colors.dart`. Nothing outside a chart uses a chart colour, and
/// no chart uses the blue gray.
///
/// **One deliberate deviation.** A label on exact #6D8196 reaches only 3.9:1
/// (ivory) or 4.0:1 (white), under the 4.5:1 AA floor for button text. So
/// wherever text sits on, or is set in, the accent — filled buttons, the FAB,
/// text buttons — the scheme's `primary` is [blueGrayDeep], the same hue
/// about 6% deeper, which clears 4.7:1. The exact hue is `secondary`, and is
/// used for everything that is not text: the navigation highlight, focus
/// rings, progress, page dots, accent icons.
///
/// Light and dark are authored as two palettes rather than one inverted:
/// light is ivory paper with charcoal ink, dark is deep charcoal with ivory
/// ink. Semantics are fixed across both:
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

  static const Color charcoal = Color(0xFF4A4A4A);
  static const Color coolGray = Color(0xFFCBCBCB);
  static const Color ivory = Color(0xFFFFFEE3);
  static const Color blueGray = Color(0xFF6D8196);

  /// [blueGray] deepened just enough to carry an ivory label at AA (4.7:1).
  static const Color blueGrayDeep = Color(0xFF5F7489);

  /// [blueGray] lifted for text and buttons on the dark surface.
  static const Color blueGrayLight = Color(0xFFA3B4C6);

  // ---------------------------------------------------------------------
  // Roles
  // ---------------------------------------------------------------------

  /// Primary actions — filled buttons, the FAB, text buttons, links.
  static const Color brand = blueGrayDeep;
  static const Color brandDark = blueGrayLight;

  /// The exact accent, for highlights that carry no text.
  static const Color accent = blueGray;

  /// The floating navigation bar.
  static const Color navBar = charcoal;

  /// Base colour for modal barriers. Neutral ink rather than black, which
  /// on ivory read as a dirty film.
  static const Color scrim = Color(0xFF262626);

  // ---------------------------------------------------------------------
  // Semantic money tones
  // ---------------------------------------------------------------------

  static const Color income = Color(0xFF2E7657);
  static const Color incomeDark = Color(0xFF7DC9A2);
  static const Color expense = Color(0xFFB23B4B);
  static const Color expenseDark = Color(0xFFEE8A93);
  static const Color warning = Color(0xFF9A6512);
  static const Color warningDark = Color(0xFFE4B862);

  /// Transfers are movement, not earning or spending, so they get a
  /// desaturated slate that cannot be mistaken for income green — and that
  /// is kept clear of the blue-gray accent, so a transfer never reads as a
  /// selection.
  static const Color transfer = Color(0xFF6F767D);
  static const Color transferDark = Color(0xFFAEB3B8);

  // ---------------------------------------------------------------------
  // Light surface ramp — ivory paper
  // ---------------------------------------------------------------------

  /// The page is the palette's ivory exactly.
  static const Color lightBackground = ivory;

  /// Cards are a whiter ivory, so they lift off the page like a sheet laid
  /// on it; the cool-gray hairline finishes the edge.
  static const Color lightSurface = Color(0xFFFFFFF7);

  /// Insets — input fills, wells, tracks: cool gray washed into the ivory.
  static const Color lightSunken = Color(0xFFF0EFDA);
  static const Color lightBorder = Color(0xCCCBCBCB);
  static const Color lightText = charcoal;
  static const Color lightTextMuted = Color(0xFF6B6B6B);

  // ---------------------------------------------------------------------
  // Dark surface ramp — deep charcoal
  // ---------------------------------------------------------------------

  /// Neutral near-black rather than pure black: pure black makes elevation
  /// invisible and haloes light text on OLED.
  static const Color darkBackground = Color(0xFF1A1A1A);
  static const Color darkSurface = Color(0xFF262626);
  static const Color darkSunken = Color(0xFF333333);
  static const Color darkBorder = Color(0x1FFFFEE3);
  static const Color darkText = ivory;
  static const Color darkTextMuted = Color(0xFFA8A8A8);

  // ---------------------------------------------------------------------
  // Hero surface
  // ---------------------------------------------------------------------

  /// The charcoal gradient behind the one headline figure on a screen. The
  /// light stop is held at #3A3A3A rather than the palette's #4A4A4A so the
  /// muted labels keep 4.5:1 anywhere on the card.
  static const List<Color> heroLight = <Color>[
    Color(0xFF2C2C2C),
    Color(0xFF3A3A3A),
  ];

  /// In dark mode the hero lifts off the page instead of sinking into it.
  static const List<Color> heroDark = <Color>[
    Color(0xFF3A3A3A),
    Color(0xFF2A2A2A),
  ];

  /// Ink on the hero.
  static const Color heroInk = ivory;

  /// Eyebrows, badges and glows on the hero: the blue gray lifted to 6:1 on
  /// charcoal. The exact accent would be 2.2:1 there.
  static const Color heroAccent = Color(0xFFB3C2D2);

  // ---------------------------------------------------------------------
  // Category swatches
  // ---------------------------------------------------------------------

  /// Offered when creating a category. Mid-tone and spread around the wheel
  /// on purpose: each one has to stay distinguishable on both the ivory and
  /// the charcoal surface. These are user data, not theme — a category keeps
  /// the colour it was saved with.
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
