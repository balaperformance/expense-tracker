import 'package:flutter/material.dart';

/// The app's colour system — the Gothic Noir palette.
///
/// Four source colours drive the whole UI:
///
///   black      #000000  ink, the hero surface, the dark-mode page
///   lightGray  #D1D0D0  the page, and ink on dark surfaces
///   taupe      #988686  the secondary accent and the card tint
///   darkTaupe  #5C4E4E  primary actions, navigation, secondary text
///
/// Charts are the one exception and draw from their own palette — see
/// `app_chart_colors.dart`.
///
/// **How taupe is used, and why.** Taupe is a mid-tone: as text or an icon
/// on the light gray page it reaches only 2.2:1. So it appears where it
/// reads — on black (6.1:1: the hero's accents, the active navigation
/// circle, dark-mode actions) — and as the tint that gives cards their
/// colour: taupe at 15% over light gray. A solid taupe card would leave dark
/// taupe text at 2.3:1 and no room for a caption to sit below body copy.
///
/// Light and dark are authored as two palettes rather than one inverted:
/// light is gray paper with taupe-tinted cards and black ink, dark is black
/// with light-gray ink. Semantics are fixed across both:
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

  static const Color black = Color(0xFF000000);
  static const Color lightGray = Color(0xFFD1D0D0);
  static const Color taupe = Color(0xFF988686);
  static const Color darkTaupe = Color(0xFF5C4E4E);

  /// A card: [taupe] at 15% over [lightGray]. Dark taupe still reads on it
  /// at 4.6:1, which is what caps the tint.
  static const Color taupeCard = Color(0xFFC8C4C4);

  // ---------------------------------------------------------------------
  // Roles
  // ---------------------------------------------------------------------

  /// Primary actions — filled buttons, the FAB, text buttons, links.
  static const Color brand = darkTaupe;
  static const Color brandDark = taupe;

  /// The secondary accent: washes, the active navigation circle, selection.
  static const Color accent = taupe;

  /// The floating navigation bar.
  static const Color navBar = darkTaupe;

  /// Base colour for modal barriers.
  static const Color scrim = black;

  // ---------------------------------------------------------------------
  // Semantic money tones
  // ---------------------------------------------------------------------

  // Deep enough to clear 4.7:1 on a taupe-tinted card.
  static const Color income = Color(0xFF185A3D);
  static const Color incomeDark = Color(0xFF7DC9A2);
  static const Color expense = Color(0xFF8A2230);
  static const Color expenseDark = Color(0xFFEE8A93);
  static const Color warning = Color(0xFF6A4507);
  static const Color warningDark = Color(0xFFE4B862);

  /// Transfers are movement, not earning or spending, so they get a
  /// desaturated slate that cannot be mistaken for income green.
  static const Color transfer = Color(0xFF4B4F57);
  static const Color transferDark = Color(0xFFAEB3B8);

  // ---------------------------------------------------------------------
  // Light surface ramp — light gray page, taupe-tinted cards
  // ---------------------------------------------------------------------

  static const Color lightBackground = lightGray;
  static const Color lightSurface = taupeCard;

  /// Insets — input fills, wells, tracks: a faint black wash, recessed on
  /// the page and on a card alike.
  static const Color lightSunken = Color(0x0F000000);
  static const Color lightBorder = Color(0x405C4E4E);
  static const Color lightText = black;
  static const Color lightTextMuted = darkTaupe;

  // ---------------------------------------------------------------------
  // Dark surface ramp — black
  // ---------------------------------------------------------------------

  /// The palette's black, as iOS uses it: a true-black page, with elevation
  /// carried by the taupe-black cards above it.
  static const Color darkBackground = black;
  static const Color darkSurface = Color(0xFF1E1A1A);
  static const Color darkSunken = Color(0xFF2A2424);
  static const Color darkBorder = Color(0x1FD1D0D0);
  static const Color darkText = lightGray;
  static const Color darkTextMuted = Color(0xFFA39C9C);

  // ---------------------------------------------------------------------
  // Hero surface
  // ---------------------------------------------------------------------

  /// Black shading into taupe-black, behind the one headline figure on a
  /// screen. The light stop is held at #1F1A1A so taupe eyebrows keep 4.5:1
  /// anywhere on the card.
  static const List<Color> heroLight = <Color>[
    black,
    Color(0xFF1F1A1A),
  ];

  /// In dark mode the hero lifts off the black page instead of sinking.
  static const List<Color> heroDark = <Color>[
    Color(0xFF241E1E),
    Color(0xFF141010),
  ];

  /// Ink on the hero.
  static const Color heroInk = lightGray;

  /// Eyebrows, badges and glows on the hero: taupe, exact — 6.1:1 on black.
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
