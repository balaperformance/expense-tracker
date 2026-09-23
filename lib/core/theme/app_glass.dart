/// Liquid-glass surfaces.
///
/// The look is built from four layers, applied in this order:
///
///   1. a real blur of whatever is behind the surface,
///   2. a translucent fill that gives the glass its body and its tint,
///   3. a hairline border that is brighter along the top edge than the
///      bottom, which is what reads as a lit pane rather than a flat panel,
///   4. a soft shadow that separates the pane from the page.
///
/// **Blur is rationed.** `BackdropFilter` forces the compositor to read back
/// everything painted underneath, and the cost scales with the blurred area,
/// not with the sigma. A screen with twelve blurred cards on it will drop
/// frames on the mid-range Android hardware this app targets. So blur is
/// spent only where something genuinely moves behind the surface and the
/// effect is doing real work:
///
///   * the app bar and the bottom navigation, which content scrolls under,
///   * modal sheets and dialogs, which sit over the page,
///   * the one hero card on the dashboard.
///
/// Every other surface — cards, rows, wells, chips — uses layers 2 to 4
/// only. Translucency, tint, lit edge and depth all survive; only the
/// (invisible, because nothing is moving behind them) blur is dropped. That
/// is the difference between a design that looks like glass and one that
/// merely costs like it.
library;

import 'dart:ui';

import 'package:flutter/material.dart';

import 'app_spacing.dart';

/// Resolved glass values for one brightness.
///
/// Read through [AppGlass.of] so a widget never has to know which mode it is
/// in, and so the whole system can be retuned in one place.
@immutable
class GlassTokens {
  const GlassTokens({
    required this.fill,
    required this.fillStrong,
    required this.sunken,
    required this.borderTop,
    required this.borderBottom,
    required this.shadow,
    required this.shadowStrong,
    required this.blur,
    required this.isDark,
  });

  /// Body of an ordinary pane, over the page background.
  final Color fill;

  /// Body of a pane that must stay legible over arbitrary content — a bar, a
  /// sheet, a dialog. More opaque, because text sits on it.
  final Color fillStrong;

  /// Recessed area inside a pane: an input, a progress track, a well.
  final Color sunken;

  /// Lit edge. Brighter than [borderBottom], which is the whole trick.
  final Color borderTop;
  final Color borderBottom;

  final List<BoxShadow> shadow;
  final List<BoxShadow> shadowStrong;

  /// Sigma for surfaces that actually blur.
  final double blur;

  final bool isDark;

  /// The lit-edge border, as a gradient-backed painter would draw it.
  ///
  /// Flutter cannot stroke a box with a gradient directly, so the effect is
  /// approximated with a single colour on the whole outline plus a brighter
  /// top-edge highlight drawn by [GlassSurface]. That reads as intended at a
  /// hairline width and costs one less layer than a shader would.
  Border get border => Border.all(color: borderBottom, width: 0.75);
}

class AppGlass {
  const AppGlass._();

  // ---------------------------------------------------------------------
  // Blur sigmas
  // ---------------------------------------------------------------------

  /// Bars and navigation. Enough to abstract the content behind without
  /// smearing it into mush.
  static const double blurBar = 24;

  /// Sheets, dialogs and anything over a dimmed page.
  static const double blurOverlay = 32;

  /// The dashboard hero card.
  static const double blurCard = 18;

  static const GlassTokens light = GlassTokens(
    isDark: false,
    // White with body, not transparent white: over a near-white page a fill
    // below about 0.6 stops reading as a surface at all and the card edge
    // does the entire job.
    fill: Color(0xCCFFFFFF),
    fillStrong: Color(0xF2FFFFFF),
    sunken: Color(0x0F101828),
    // The top highlight is pure white; the outline is a very soft ink.
    borderTop: Color(0xE6FFFFFF),
    borderBottom: Color(0x14101828),
    blur: blurBar,
    shadow: <BoxShadow>[
      BoxShadow(
        color: Color(0x0D101828),
        blurRadius: 16,
        offset: Offset(0, 4),
      ),
    ],
    shadowStrong: <BoxShadow>[
      BoxShadow(
        color: Color(0x1A101828),
        blurRadius: 32,
        offset: Offset(0, 12),
      ),
    ],
  );

  static const GlassTokens dark = GlassTokens(
    isDark: true,
    // Dark glass is a lifted grey, not a black veil: a translucent black over
    // a near-black page produces no surface at all.
    fill: Color(0xB81B2028),
    fillStrong: Color(0xF01A1F27),
    sunken: Color(0x1FFFFFFF),
    borderTop: Color(0x26FFFFFF),
    borderBottom: Color(0x1AFFFFFF),
    blur: blurBar,
    shadow: <BoxShadow>[
      BoxShadow(
        color: Color(0x40000000),
        blurRadius: 18,
        offset: Offset(0, 6),
      ),
    ],
    shadowStrong: <BoxShadow>[
      BoxShadow(
        color: Color(0x66000000),
        blurRadius: 36,
        offset: Offset(0, 14),
      ),
    ],
  );

  static GlassTokens of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  static GlassTokens forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

/// A glass pane.
///
/// Set [blur] only where content genuinely moves behind the surface — see the
/// rationing note at the top of this file. Everything else gets the fill, the
/// lit edge and the shadow, which is what carries the look.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = AppSpacing.radiusLg,
    this.blur = 0,
    this.strong = false,
    this.padding = EdgeInsets.zero,
    this.tone,
    this.elevated = true,
    this.borderRadius,
    this.clip = true,
  });

  final Widget child;

  /// Uniform corner radius. Ignored when [borderRadius] is given.
  final double radius;

  /// Sigma for the backdrop blur. Zero — the default — paints no
  /// `BackdropFilter` at all, which is the cheap path.
  final double blur;

  /// Use the more opaque fill, for a surface text sits on over moving
  /// content.
  final bool strong;

  final EdgeInsetsGeometry padding;

  /// Tints the pane for a state that needs attention. Left null for almost
  /// every surface in the app.
  final Color? tone;

  final bool elevated;
  final BorderRadius? borderRadius;

  /// Clipping is required whenever [blur] is set, and merely tidy otherwise.
  final bool clip;

  @override
  Widget build(BuildContext context) {
    final GlassTokens glass = AppGlass.of(context);
    final BorderRadius shape =
        borderRadius ?? BorderRadius.circular(radius);

    final Color fill = tone != null
        ? tone!.withOpacity(glass.isDark ? 0.16 : 0.09)
        : (strong ? glass.fillStrong : glass.fill);

    final Color outline = tone != null
        ? tone!.withOpacity(glass.isDark ? 0.42 : 0.30)
        : glass.borderBottom;

    Widget pane = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: shape,
        border: Border.all(color: outline, width: 0.75),
      ),
      child: Stack(
        children: <Widget>[
          // The lit top edge. One hairline, drawn inside the border and
          // inset from the corners so it stops where the curve begins
          // instead of streaking across it.
          if (tone == null)
            Positioned(
              left: radius * 0.5,
              right: radius * 0.5,
              top: 0,
              child: _TopHighlight(colour: glass.borderTop),
            ),
          Padding(padding: padding, child: child),
        ],
      ),
    );

    if (clip) {
      pane = ClipRRect(borderRadius: shape, child: pane);
    }

    if (blur > 0) {
      pane = ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: pane,
        ),
      );
    }

    if (!elevated) return pane;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: strong ? glass.shadowStrong : glass.shadow,
      ),
      child: pane,
    );
  }
}

/// The one-pixel lit edge along the top of a pane.
class _TopHighlight extends StatelessWidget {
  const _TopHighlight({required this.colour});

  final Color colour;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: <Color>[
              colour.withOpacity(0),
              colour,
              colour.withOpacity(0),
            ],
            stops: const <double>[0, 0.5, 1],
          ),
        ),
      ),
    );
  }
}

/// Blurred, translucent bar for an app bar or a bottom navigation.
///
/// This is one of the few places blur earns its cost: content scrolls
/// underneath, so the blur is visibly doing something on every frame the user
/// drags. The hairline sits on the content side of the bar.
class GlassBar extends StatelessWidget {
  const GlassBar({
    super.key,
    required this.child,
    this.edge = GlassBarEdge.bottom,
    this.blur = AppGlass.blurBar,
  });

  final Widget child;

  /// Which side faces the scrolling content, and therefore gets the hairline.
  final GlassBarEdge edge;

  final double blur;

  @override
  Widget build(BuildContext context) {
    final GlassTokens glass = AppGlass.of(context);
    final BorderSide hairline = BorderSide(color: glass.borderBottom, width: 0.75);

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: glass.fillStrong,
            border: Border(
              bottom: edge == GlassBarEdge.bottom ? hairline : BorderSide.none,
              top: edge == GlassBarEdge.top ? hairline : BorderSide.none,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

enum GlassBarEdge { top, bottom, none }
