import 'package:flutter/material.dart';

import 'app_chart_colors.dart';
import 'app_colors.dart';
import 'app_glass.dart';

/// The visual design language, chosen in Settings → Appearance.
///
/// Independent of light/dark: the theme mode still picks the brightness, and
/// each palette has both. Mirrors the web app's `PalettePreference`
/// (`ui/src/state/settings.tsx`), with the same ids, so the two apps describe
/// the same choice the same way.
enum AppPalette {
  /// Gothic Noir — black hero, dark-taupe brand, the jewel chart palette.
  /// The default: everyone stays on it until they choose Matte & Sand, as on
  /// the web.
  current('current', 'Current'),

  /// Matte & Sand — matte black for the hero and primary controls, warm
  /// ivory as the canvas, sand only for small marks. No glows.
  matte('matte', 'Matte & Sand');

  const AppPalette(this.id, this.label);

  /// The stored value — identical to the web app's.
  final String id;

  /// What the Appearance control and the section summary say.
  final String label;

  /// Anything unrecognised — nothing saved yet, or a value from a newer
  /// build — reads as the default rather than failing.
  static AppPalette fromId(String? id) {
    for (final AppPalette palette in values) {
      if (palette.id == id) return palette;
    }
    return current;
  }
}

/// Every colour that differs between palettes, resolved for one palette and
/// one brightness.
///
/// Carried on the [ThemeData] as an extension, so a widget asks the theme it
/// is drawn under — `PaletteTokens.of(context)` — and never has to know which
/// palette is chosen. That is what lets the hero render its child under the
/// palette's dark theme and have every token inside resolve correctly.
///
/// The Gothic Noir instances are built from the existing [AppColors],
/// [ChartColors] and [AppGlass] constants, so the current palette is exactly
/// what it was. The Matte & Sand values are the web app's tokens
/// (`ui/src/styles/tokens.css`, `[data-palette='matte']`).
@immutable
class PaletteTokens extends ThemeExtension<PaletteTokens> {
  const PaletteTokens({
    required this.palette,
    required this.brightness,
    required this.background,
    required this.surface,
    required this.sunken,
    required this.border,
    required this.text,
    required this.muted,
    required this.primary,
    required this.onPrimary,
    required this.accent,
    required this.onAccent,
    required this.onError,
    required this.onInverse,
    this.tonal,
    this.tonalInk,
    required this.income,
    required this.expense,
    required this.warning,
    required this.transfer,
    required this.wash,
    required this.hero,
    required this.heroEdge,
    required this.heroInk,
    required this.heroTrack,
    required this.heroAccent,
    required this.heroGlow,
    required this.glows,
    required this.mark,
    this.navActiveIcon,
    required this.brandGlow,
    required this.categoryMute,
    required this.chart,
    required this.glass,
  });

  final AppPalette palette;
  final Brightness brightness;

  // ---- Surfaces & ink ---------------------------------------------------

  final Color background;
  final Color surface;

  /// Insets — input fills, wells, tracks.
  final Color sunken;
  final Color border;
  final Color text;
  final Color muted;

  // ---- Brand --------------------------------------------------------------

  /// Primary actions, selection, the FAB and the active nav item.
  final Color primary;
  final Color onPrimary;

  /// The secondary accent: idle icons, the avatar ring, quiet highlights.
  final Color accent;
  final Color onAccent;
  final Color onError;

  /// Ink on the inverse surface — snack bars and tooltips.
  final Color onInverse;

  /// The selected segment and the primary container. Null derives it from
  /// [primary], which is what Gothic Noir always did; Matte & Sand sets a
  /// sand wash instead, because a wash of matte black is just gray.
  final Color? tonal;
  final Color? tonalInk;

  // ---- Money tones --------------------------------------------------------

  final Color income;
  final Color expense;
  final Color warning;
  final Color transfer;

  /// Opacity of a tone's tinted background — icon wells, soft badges.
  final double wash;

  // ---- Hero ---------------------------------------------------------------

  /// The hero pane's gradient, top-left to bottom-right, for this page
  /// brightness.
  final List<Color> hero;

  /// The hero's hairline.
  final Color heroEdge;

  /// Ink, the spend bar's track, and the eyebrows and badges on the hero.
  final Color heroInk;
  final Color heroTrack;
  final Color heroAccent;

  /// The Net card's corner light.
  final Color heroGlow;

  /// Whether the hero paints its soft radial lights at all. Matte & Sand has
  /// none — the web palette sets `--glow-opacity: 0`.
  final bool glows;

  /// The profile avatar's disc: a small block of the hero's black.
  final List<Color> mark;

  // ---- Navigation ---------------------------------------------------------

  /// The icon on the active nav item. Null keeps it [onPrimary]; Matte &
  /// Sand marks it in sand.
  final Color? navActiveIcon;

  /// The soft shadow under the active nav item.
  final Color brandGlow;

  // ---- Categories ---------------------------------------------------------

  /// How far a category colour is pulled toward [muted] — 0 leaves it as
  /// saved. See [category].
  final double categoryMute;

  // ---- Groups -------------------------------------------------------------

  final ChartColors chart;
  final GlassTokens glass;

  /// A category's stored colour as this palette shows it: Matte & Sand pulls
  /// it toward the muted ink so a row of categories stays quiet, as the web's
  /// `--category-mute` does. Gothic Noir returns it unchanged.
  Color category(Color colour) =>
      categoryMute == 0 ? colour : Color.lerp(colour, muted, categoryMute)!;

  // ---------------------------------------------------------------------
  // The four palettes
  // ---------------------------------------------------------------------

  static const PaletteTokens currentLight = PaletteTokens(
    palette: AppPalette.current,
    brightness: Brightness.light,
    background: AppColors.lightBackground,
    surface: AppColors.lightSurface,
    sunken: AppColors.lightSunken,
    border: AppColors.lightBorder,
    text: AppColors.lightText,
    muted: AppColors.lightTextMuted,
    primary: AppColors.brand,
    onPrimary: Color(0xFFFFFFFF),
    accent: AppColors.accent,
    onAccent: Color(0xFFFFFFFF),
    onError: Color(0xFFFFFFFF),
    onInverse: Color(0xFFFFFFFF),
    income: AppColors.income,
    expense: AppColors.expense,
    warning: AppColors.warning,
    transfer: AppColors.transfer,
    wash: 0.11,
    hero: AppColors.heroLight,
    // White at 7%.
    heroEdge: Color(0x12FFFFFF),
    heroInk: AppColors.heroInk,
    heroTrack: AppColors.heroTrack,
    heroAccent: AppColors.heroAccent,
    heroGlow: AppColors.heroGlow,
    glows: true,
    mark: AppColors.heroLight,
    // The brand at 35%.
    brandGlow: Color(0x595C4E4E),
    categoryMute: 0,
    chart: ChartColors.light,
    glass: AppGlass.light,
  );

  static const PaletteTokens currentDark = PaletteTokens(
    palette: AppPalette.current,
    brightness: Brightness.dark,
    background: AppColors.darkBackground,
    surface: AppColors.darkSurface,
    sunken: AppColors.darkSunken,
    border: AppColors.darkBorder,
    text: AppColors.darkText,
    muted: AppColors.darkTextMuted,
    primary: AppColors.brandDark,
    onPrimary: AppColors.black,
    accent: AppColors.accent,
    onAccent: AppColors.black,
    onError: AppColors.black,
    onInverse: AppColors.lightText,
    income: AppColors.incomeDark,
    expense: AppColors.expenseDark,
    warning: AppColors.warningDark,
    transfer: AppColors.transferDark,
    // A 10% wash over near-black is invisible.
    wash: 0.20,
    hero: AppColors.heroDark,
    // White at 10%.
    heroEdge: Color(0x1AFFFFFF),
    heroInk: AppColors.heroInk,
    heroTrack: AppColors.heroTrack,
    heroAccent: AppColors.heroAccent,
    heroGlow: AppColors.heroGlow,
    glows: true,
    mark: AppColors.heroLight,
    brandGlow: Color(0x59988686),
    categoryMute: 0,
    chart: ChartColors.dark,
    glass: AppGlass.dark,
  );

  /// Matte & Sand, light: warm ivory canvas, matte-black primary, sand for
  /// small marks only. Money tones are deepened so they read as text on
  /// ivory.
  static const PaletteTokens matteLight = PaletteTokens(
    palette: AppPalette.matte,
    brightness: Brightness.light,
    background: Color(0xFFF6F4EE),
    surface: Color(0xFFFFFEFB),
    sunken: Color(0xFFEBE7DE),
    border: Color(0xFFDED7CA),
    text: Color(0xFF171717),
    muted: Color(0xFF6B665E),
    primary: Color(0xFF121212),
    onPrimary: Color(0xFFF4EFE4),
    accent: Color(0xFF9A7F4F),
    onAccent: Color(0xFFFFFEFB),
    onError: Color(0xFFFFFFFF),
    onInverse: Color(0xFFFFFEFB),
    tonal: Color(0xFFEBE3D1),
    tonalInk: Color(0xFF171717),
    income: Color(0xFF3F7D61),
    expense: Color(0xFFB04A40),
    warning: Color(0xFF9C6F26),
    transfer: Color(0xFF66625B),
    wash: 0.11,
    hero: <Color>[Color(0xFF191918), Color(0xFF131313)],
    // Sand at 14%.
    heroEdge: Color(0x24D4C4A1),
    heroInk: Color(0xFFEFE9DD),
    heroTrack: Color(0x1FEFE9DD),
    heroAccent: Color(0xFFD4C4A1),
    heroGlow: Color(0x00D4C4A1),
    glows: false,
    mark: <Color>[Color(0xFF191918), Color(0xFF121212)],
    navActiveIcon: Color(0xFFD4C4A1),
    brandGlow: Color(0x42121212),
    categoryMute: 0.42,
    chart: ChartColors.matteLight,
    glass: AppGlass.matteLight,
  );

  /// Matte & Sand, dark: black stays the canvas and ivory becomes the
  /// primary. The hero and the avatar lift off the black page.
  static const PaletteTokens matteDark = PaletteTokens(
    palette: AppPalette.matte,
    brightness: Brightness.dark,
    background: Color(0xFF111111),
    surface: Color(0xFF1A1A19),
    sunken: Color(0xFF262523),
    border: Color(0xFF3A3733),
    text: Color(0xFFEDE8DD),
    muted: Color(0xFFA39D92),
    primary: Color(0xFFEBE5D8),
    onPrimary: Color(0xFF141414),
    accent: Color(0xFFD4C4A1),
    onAccent: Color(0xFF141414),
    onError: Color(0xFF141414),
    onInverse: Color(0xFF171717),
    tonal: Color(0xFF2A2722),
    tonalInk: Color(0xFFEDE8DD),
    income: Color(0xFF86BFA2),
    expense: Color(0xFFE08378),
    warning: Color(0xFFD9AB5E),
    transfer: Color(0xFFA19B91),
    wash: 0.16,
    hero: <Color>[Color(0xFF1F1E1C), Color(0xFF1A1918)],
    heroEdge: Color(0xFF3A3733),
    heroInk: Color(0xFFEFE9DD),
    heroTrack: Color(0x1FEFE9DD),
    heroAccent: Color(0xFFD4C4A1),
    heroGlow: Color(0x00D4C4A1),
    glows: false,
    mark: <Color>[Color(0xFF1F1E1C), Color(0xFF1A1918)],
    navActiveIcon: Color(0xFF9A7F4F),
    brandGlow: Color(0x80000000),
    categoryMute: 0.38,
    chart: ChartColors.matteDark,
    glass: AppGlass.matteDark,
  );

  static PaletteTokens resolve(AppPalette palette, Brightness brightness) {
    final bool dark = brightness == Brightness.dark;
    return switch (palette) {
      AppPalette.current => dark ? currentDark : currentLight,
      AppPalette.matte => dark ? matteDark : matteLight,
    };
  }

  /// The tokens of the theme [context] is drawn under.
  ///
  /// A theme built outside `AppTheme` — a bare `ThemeData` in a test — has
  /// no extension, and gets Gothic Noir for its brightness: exactly what
  /// every widget resolved to before palettes existed.
  static PaletteTokens of(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return theme.extension<PaletteTokens>() ??
        resolve(AppPalette.current, theme.brightness);
  }

  /// Token sets are chosen whole, never tweaked, so there is nothing to copy.
  @override
  PaletteTokens copyWith() => this;

  /// Switches at the midpoint of a theme animation. The [ColorScheme] around
  /// it interpolates smoothly; blending two palettes' hero gradients and
  /// chart sets in between would only show colours neither palette has.
  @override
  PaletteTokens lerp(covariant ThemeExtension<PaletteTokens>? other, double t) {
    if (other is! PaletteTokens) return this;
    return t < 0.5 ? this : other;
  }
}
