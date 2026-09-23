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
/// **Blur is rationed, hard.** `BackdropFilter` forces the compositor to read
/// back everything painted underneath, every frame, and it is the single most
/// expensive thing a Flutter screen can do on the mid-range Android hardware
/// this app targets. A blur is only visible through a fill translucent enough
/// to show it: behind a 95%-opaque bar or sheet, or over a static page
/// background, it costs the full price and shows nothing.
///
/// So the app blurs in exactly one place by default — the full-screen layer
/// behind a dialog, which is transient and sits over a lightly scrimmed page
/// where the effect is plainly visible. The navigation bar, sheets and the
/// dashboard hero carry the look with layers 2 to 4: translucency, tint, the
/// lit edge and depth. [GlassSurface.blur] still exists for a surface that
/// genuinely has moving content behind a translucent fill.
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
  static const double blurBar = 14;

  /// Sheets, dialogs and anything over a dimmed page.
  static const double blurOverlay = 18;

  /// The dashboard hero card.
  static const double blurCard = 12;

  static const GlassTokens light = GlassTokens(
    isDark: false,
    // A whiter ivory with body, laid over the ivory page like a sheet of
    // paper. Much below 0.8 it stops reading as a surface at all.
    fill: Color(0xEBFFFFF7),
    fillStrong: Color(0xF7FFFFF7),
    sunken: Color(0x4DCBCBCB),
    // A white highlight along the top; the palette's cool gray around the
    // rest, which is the hairline that defines the card on ivory.
    borderTop: Color(0xFFFFFFFF),
    borderBottom: Color(0xB3CBCBCB),
    blur: blurBar,
    // Soft charcoal shadows, kept faint: the hairline does most of the work.
    shadow: <BoxShadow>[
      BoxShadow(
        color: Color(0x0F4A4A4A),
        blurRadius: 18,
        offset: Offset(0, 6),
      ),
    ],
    shadowStrong: <BoxShadow>[
      BoxShadow(
        color: Color(0x244A4A4A),
        blurRadius: 34,
        offset: Offset(0, 14),
      ),
    ],
  );

  static const GlassTokens dark = GlassTokens(
    isDark: true,
    // Lifted charcoal, not a black veil. A translucent black over a
    // near-black page produces no surface at all.
    fill: Color(0xD92A2A2A),
    fillStrong: Color(0xF5282828),
    sunken: Color(0x1AFFFEE3),
    borderTop: Color(0x29FFFEE3),
    borderBottom: Color(0x17FFFEE3),
    blur: blurBar,
    shadow: <BoxShadow>[
      BoxShadow(
        color: Color(0x47000000),
        blurRadius: 20,
        offset: Offset(0, 8),
      ),
    ],
    shadowStrong: <BoxShadow>[
      BoxShadow(
        color: Color(0x6B000000),
        blurRadius: 38,
        offset: Offset(0, 16),
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
    this.opaque = false,
    this.color,
    this.borderColor,
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

  /// Flattens the glass tint onto the page colour. Use for a surface that
  /// content passes *under* without a blur — a floating bar, a sheet — where
  /// even a 4% see-through leaves legible ghost text behind the glass. The
  /// tone is identical; only the bleed is gone.
  final bool opaque;

  /// An explicit body colour in place of the glass fill — for a pane that
  /// is its own material, like the charcoal navigation bar. It still gets
  /// the lit edge, and [opaque] still applies.
  final Color? color;

  /// Replaces the hairline when [color] would clash with the glass one.
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final GlassTokens glass = AppGlass.of(context);
    final BorderRadius shape =
        borderRadius ?? BorderRadius.circular(radius);

    final Color body = color ?? (strong ? glass.fillStrong : glass.fill);
    final Color fill = tone != null
        ? tone!.withOpacity(glass.isDark ? 0.16 : 0.09)
        : opaque
            ? Color.alphaBlend(
                body,
                Theme.of(context).scaffoldBackgroundColor,
              )
            : body;

    final Color outline = tone != null
        ? tone!.withOpacity(glass.isDark ? 0.42 : 0.30)
        : borderColor ?? glass.borderBottom;

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
              child: _TopHighlight(
                // Over an explicit body colour (the charcoal nav bar) the
                // glass highlight would be a hard white rule; a faint glint
                // reads as the same lit edge.
                colour: color != null
                    ? const Color(0x29FFFEE3)
                    : glass.borderTop,
              ),
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
