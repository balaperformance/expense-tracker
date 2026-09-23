import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_glass.dart';
import 'app_motion.dart';
import 'app_spacing.dart';
import 'app_typography.dart';

/// Light and dark themes.
///
/// Every component the app uses is styled once here, so screens describe
/// layout and never appearance. If a card, field or chip looks different on
/// one screen, that is a bug in that screen rather than a local override to
/// be added.
///
/// Light and dark are built from the same structure but genuinely different
/// values — see [AppColors] for why they are not one palette inverted.
class AppTheme {
  const AppTheme._();

  /// Built once and reused. The getters these replace rebuilt the whole
  /// ThemeData — every component theme, every text style — on each access,
  /// which the app did on every settings change and every themed rebuild.
  static final ThemeData light = _build(Brightness.light);
  static final ThemeData dark = _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final bool isDark = brightness == Brightness.dark;

    final Color background =
        isDark ? AppColors.darkBackground : AppColors.lightBackground;
    final Color surface =
        isDark ? AppColors.darkSurface : AppColors.lightSurface;
    final Color sunken = isDark ? AppColors.darkSunken : AppColors.lightSunken;
    final Color border = isDark ? AppColors.darkBorder : AppColors.lightBorder;
    final Color onSurface = isDark ? AppColors.darkText : AppColors.lightText;
    final Color muted =
        isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted;
    final Color primary = isDark ? AppColors.brandDark : AppColors.brand;
    // The secondary accent, olive gray, for washes and highlights on the
    // page. It is too faint on a beige card to mark a control, so focus
    // rings and progress use [primary]; see the note in AppColors.
    const Color accent = AppColors.accent;
    final Color onAccentInk = isDark ? AppColors.darkBackground : AppColors.cream;
    final Color error = isDark ? AppColors.expenseDark : AppColors.expense;

    final ColorScheme scheme = ColorScheme(
      brightness: brightness,
      primary: primary,
      onPrimary: isDark ? AppColors.darkBackground : AppColors.cream,
      primaryContainer: primary.withOpacity(isDark ? 0.22 : 0.12),
      onPrimaryContainer: primary,
      secondary: accent,
      onSecondary: onAccentInk,
      tertiary: accent,
      onTertiary: onAccentInk,
      surface: surface,
      onSurface: onSurface,
      surfaceContainerHighest: sunken,
      onSurfaceVariant: muted,
      error: error,
      onError: isDark ? AppColors.darkBackground : AppColors.cream,
      errorContainer: error.withOpacity(isDark ? 0.20 : 0.10),
      onErrorContainer: error,
      outline: border,
      outlineVariant: border,
      inverseSurface: isDark ? AppColors.cream : AppColors.oliveInk,
      onInverseSurface: isDark ? AppColors.oliveInk : AppColors.cream,
      shadow: Colors.black,
      scrim: Colors.black,
    );

    final TextTheme text = AppTypography.textTheme(scheme);
    final GlassTokens glass = AppGlass.forBrightness(brightness);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: AppTypography.fontFamily,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      textTheme: text,
      // Every push in this app is a drill-down, so every platform gets the
      // horizontal slide that makes "back" feel like going back.
      pageTransitionsTheme: const AppPageTransitions(),
      // InkSparkle is heavy under a dense list; a plain ripple reads as
      // faster and keeps long scrolls smooth on mid-range hardware.
      splashFactory: InkRipple.splashFactory,
      visualDensity: VisualDensity.standard,

      // -------------------------------------------------------------------
      // App bar — flat, background-coloured, title left-aligned
      // -------------------------------------------------------------------
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: AppSpacing.page,
        toolbarHeight: AppSpacing.appBarHeight,
        titleTextStyle: text.titleLarge,
        iconTheme: IconThemeData(color: onSurface, size: AppSpacing.iconLg),
        actionsIconTheme:
            IconThemeData(color: onSurface, size: AppSpacing.iconLg),
        systemOverlayStyle: isDark
            ? SystemUiOverlayStyle.light.copyWith(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: background,
                systemNavigationBarIconBrightness: Brightness.light,
              )
            : SystemUiOverlayStyle.dark.copyWith(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: background,
                systemNavigationBarIconBrightness: Brightness.dark,
              ),
      ),

      // -------------------------------------------------------------------
      // Cards — translucent glass fill, lit hairline
      // -------------------------------------------------------------------
      // A raw `Card` written anywhere in the app lands on the same fill and
      // hairline that [SurfaceCard] paints, so the two can sit side by side
      // without one looking like a different material. The depth comes from
      // the shadow [GlassSurface] draws outside the pane rather than from
      // Material elevation, which tints the surface and stacks badly in a
      // list of cards.
      cardTheme: CardTheme(
        color: glass.fill,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
          side: BorderSide(color: glass.borderBottom, width: 0.75),
        ),
      ),

      // -------------------------------------------------------------------
      // Inputs — filled, sunken, no heavy outline until focus
      // -------------------------------------------------------------------
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: sunken,
        isDense: true,
        // 12 rather than 16 vertical: a four-field form was taller than the
        // screen purely because of input padding.
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.fieldPadY,
        ),
        border: _inputBorder(Colors.transparent),
        enabledBorder: _inputBorder(Colors.transparent),
        disabledBorder: _inputBorder(Colors.transparent),
        // Deep olive, not the olive-gray accent: a focus ring has to clear
        // 3:1 against a beige card, and olive gray is 2.5:1 there.
        focusedBorder: _inputBorder(primary, width: 1.6),
        errorBorder: _inputBorder(error, width: 1.2),
        focusedErrorBorder: _inputBorder(error, width: 1.6),
        hintStyle: text.bodyMedium?.copyWith(color: muted),
        labelStyle: text.bodyMedium?.copyWith(color: muted),
        floatingLabelStyle: text.labelMedium?.copyWith(color: primary),
        helperStyle: text.bodySmall,
        errorStyle: text.bodySmall?.copyWith(color: error),
        prefixStyle: text.bodyLarge,
        prefixIconColor: muted,
        suffixIconColor: muted,
      ),

      // -------------------------------------------------------------------
      // Buttons — compact, content-width, one radius and one weight
      // -------------------------------------------------------------------
      //
      // Two rules decide every value below.
      //
      // First, a button sizes to its content. The previous theme used
      // `Size.fromHeight(50)`, which is `Size(double.infinity, 50)` — an
      // infinite *minimum width*. That silently stretched every button in the
      // app to the full width of its parent. Minimum width is now 0, so a
      // button is as wide as its label and full width is opt-in.
      //
      // Second, drawn height and tap target are separate concerns. The
      // buttons are 42px tall for density, and `tapTargetSize.padded` keeps
      // the actual hit area at 48px. Compact to look at, unchanged to hit.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, AppSpacing.buttonHeight),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.buttonPadX,
          ),
          tapTargetSize: MaterialTapTargetSize.padded,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusButton),
          ),
          textStyle: text.labelLarge,
          disabledBackgroundColor: onSurface.withOpacity(0.10),
          disabledForegroundColor: muted,
        ).copyWith(iconSize: _iconSize(AppSpacing.buttonIcon)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          minimumSize: const Size(0, AppSpacing.buttonHeight),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.buttonPadX,
          ),
          tapTargetSize: MaterialTapTargetSize.padded,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusButton),
          ),
          textStyle: text.labelLarge,
        ).copyWith(iconSize: _iconSize(AppSpacing.buttonIcon)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, AppSpacing.buttonHeight),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.buttonPadX - 2,
          ),
          tapTargetSize: MaterialTapTargetSize.padded,
          foregroundColor: onSurface,
          side: BorderSide(color: border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusButton),
          ),
          textStyle: text.labelLarge,
        ).copyWith(iconSize: _iconSize(AppSpacing.buttonIcon)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          minimumSize: const Size(0, AppSpacing.buttonHeightSm),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.buttonPadXSm,
          ),
          // A text button is usually inline next to a heading, where a padded
          // 48px target would push the heading out of alignment.
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusXs),
          ),
          textStyle: text.labelLarge,
        ).copyWith(iconSize: _iconSize(AppSpacing.buttonIconSm)),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: onSurface,
          // Drawn at 40, padded to the 48px hit target.
          minimumSize: const Size(40, 40),
          padding: EdgeInsets.zero,
          iconSize: AppSpacing.iconLg - 2,
          tapTargetSize: MaterialTapTargetSize.padded,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusButton),
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll<TextStyle?>(text.labelLarge),
          side: WidgetStatePropertyAll<BorderSide>(BorderSide(color: border)),
          backgroundColor: WidgetStateProperty.resolveWith<Color>(
            (Set<WidgetState> states) => states.contains(WidgetState.selected)
                ? primary.withOpacity(isDark ? 0.22 : 0.10)
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith<Color>(
            (Set<WidgetState> states) =>
                states.contains(WidgetState.selected) ? primary : muted,
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
            ),
          ),
          visualDensity: VisualDensity.compact,
        ),
      ),

      // -------------------------------------------------------------------
      // Navigation
      // -------------------------------------------------------------------
      // Transparent on purpose: the shell floats the bar over the content and
      // paints the glass itself, so the bar must not draw a second opaque
      // surface underneath it.
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        indicatorColor: primary.withOpacity(isDark ? 0.24 : 0.12),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        ),
        elevation: 0,
        height: AppSpacing.navBarHeight,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>(
          (Set<WidgetState> states) => TextStyle(
            fontFamily: AppTypography.fontFamily,
            fontSize: 11,
            height: 1.2,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected) ? primary : muted,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith<IconThemeData>(
          (Set<WidgetState> states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected) ? primary : muted,
          ),
        ),
      ),
      // Material's extended FAB defaults to 48px tall with 20px padding and a
      // 24px icon, which next to a 42px button reads as a different species.
      // These constraints bring it into the same family.
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: scheme.onPrimary,
        elevation: 2,
        focusElevation: 2,
        hoverElevation: 3,
        highlightElevation: 4,
        iconSize: AppSpacing.buttonIcon + 1,
        extendedTextStyle: text.labelLarge?.copyWith(color: scheme.onPrimary),
        extendedSizeConstraints: const BoxConstraints.tightFor(
          height: AppSpacing.fabHeight,
        ),
        extendedPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
        ),
        extendedIconLabelSpacing: AppSpacing.buttonIconGap,
        // `sizeConstraints` is deliberately not set. For an extended FAB it
        // takes precedence over `extendedSizeConstraints`, which silently
        // pinned the height back to Material's 48px default.
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        ),
      ),

      // -------------------------------------------------------------------
      // Chips
      // -------------------------------------------------------------------
      chipTheme: ChipThemeData(
        backgroundColor: sunken,
        selectedColor: accent.withOpacity(isDark ? 0.28 : 0.16),
        disabledColor: sunken.withOpacity(0.5),
        checkmarkColor: primary,
        side: BorderSide(color: border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        ),
        labelStyle: text.labelLarge,
        secondaryLabelStyle: text.labelLarge?.copyWith(color: primary),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm + 2,
          vertical: AppSpacing.xs + 1,
        ),
        labelPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
        showCheckmark: false,
      ),

      // -------------------------------------------------------------------
      // Surfaces and overlays
      // -------------------------------------------------------------------
      dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
      // Transparent, with no drag handle and no clipping: every sheet in the
      // app is opened through `showAppSheet`, which wraps the content in a
      // blurred glass pane and draws the handle on top of it. A surface here
      // would sit behind that glass and defeat the blur.
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        showDragHandle: false,
        clipBehavior: Clip.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppSpacing.radiusXxl),
          ),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: glass.fillStrong,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xxl,
          vertical: AppSpacing.xxl,
        ),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium?.copyWith(color: muted),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
          side: BorderSide(color: glass.borderBottom, width: 0.75),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        elevation: 2,
        insetPadding: const EdgeInsets.all(AppSpacing.md),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        ),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xxs,
        ),
        minVerticalPadding: AppSpacing.sm,
        iconColor: muted,
        titleTextStyle: text.titleMedium,
        subtitleTextStyle: text.bodySmall,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        ),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) =>
              states.contains(WidgetState.selected) ? primary : muted,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) =>
              states.contains(WidgetState.selected) ? primary : muted,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: onSurface.withOpacity(0.08),
        linearMinHeight: 6,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(AppSpacing.radiusXs),
        ),
        textStyle: text.labelSmall?.copyWith(color: scheme.onInverseSurface),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        textStyle: text.bodyMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          side: BorderSide(color: border),
        ),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        headerBackgroundColor: primary,
        headerForegroundColor: scheme.onPrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: primary,
        selectionColor: primary.withOpacity(0.24),
        selectionHandleColor: primary,
      ),
      tabBarTheme: TabBarTheme(
        labelColor: onSurface,
        unselectedLabelColor: muted,
        labelStyle: text.labelLarge,
        unselectedLabelStyle: text.labelLarge,
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.tab,
        indicator: BoxDecoration(
          color: glass.fillStrong,
          borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
          boxShadow: glass.shadow,
        ),
      ),
      splashColor: primary.withOpacity(0.08),
      highlightColor: primary.withOpacity(0.05),
    );
  }

  /// `styleFrom` does not expose icon size in this Flutter version, so it is
  /// applied to the resulting [ButtonStyle] instead. Setting it in the theme
  /// means even a raw `FilledButton.icon` written anywhere in the app gets
  /// the right icon size without the call site knowing about it.
  static WidgetStateProperty<double?> _iconSize(double size) =>
      WidgetStatePropertyAll<double?>(size);

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      borderSide: BorderSide(color: color, width: width),
    );
  }
}
