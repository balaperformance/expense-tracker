import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_glass.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_theme.dart';

/// The black hero pane — reserved for the one headline figure on a
/// screen (the dashboard snapshot, the accounts total).
///
/// A black gradient with light-gray ink, so the number the user came for
/// sits on the only dark surface on a light page (and lifts off the
/// page in dark mode). Rationing is the point: two of these on one screen
/// and neither is the hero.
///
/// The child is rendered under the dark theme, so every token inside — the
/// money tones, muted text, icon buttons — resolves to its light-on-dark
/// value without the caller restating a single colour.
///
/// **No blur.** The pane sits on a static page background, where a backdrop
/// blur would cost a read-back every frame and change nothing on screen.
/// Depth comes from the gradient, a warm shadow and two soft glows painted
/// as plain radial gradients, which are nearly free.
class HeroSurface extends StatelessWidget {
  const HeroSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(
      AppSpacing.lg + 2,
      AppSpacing.lg,
      AppSpacing.lg + 2,
      AppSpacing.lg,
    ),
    this.glow = AppColors.heroAccent,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Colour of the light in the top corner. The dashboard tints it with the
  /// month's outcome — emerald ahead, rose behind — so the card's mood
  /// carries meaning, not just decoration.
  final Color glow;

  @override
  Widget build(BuildContext context) {
    final bool pageIsDark = Theme.of(context).brightness == Brightness.dark;
    const BorderRadius shape =
        BorderRadius.all(Radius.circular(AppSpacing.radiusXl));

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: AppGlass.of(context).shadowStrong,
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: pageIsDark ? AppColors.heroDark : AppColors.heroLight,
            ),
            borderRadius: shape,
            border: Border.all(
              color: Colors.white.withOpacity(pageIsDark ? 0.10 : 0.07),
              width: 0.75,
            ),
          ),
          child: Theme(
            data: AppTheme.dark,
            child: Stack(
              children: <Widget>[
                Positioned(
                  top: -80,
                  right: -60,
                  child: _Glow(colour: glow, size: 210, opacity: 0.26),
                ),
                const Positioned(
                  bottom: -90,
                  left: -40,
                  child: _Glow(
                    colour: AppColors.heroAccent,
                    size: 170,
                    opacity: 0.12,
                  ),
                ),
                Padding(padding: padding, child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A soft light, painted as a radial gradient rather than blurred.
class _Glow extends StatelessWidget {
  const _Glow({
    required this.colour,
    required this.size,
    required this.opacity,
  });

  final Color colour;
  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        width: size,
        height: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: <Color>[
                colour.withOpacity(opacity),
                colour.withOpacity(0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
