import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

/// The app's mark: a dark tile with the app icon's gold wallet.
///
/// Drawn in code — gradients and rounded shapes, the same geometry as the
/// launcher icon (ui/assets/app-icon.svg) — so the identity costs no image
/// asset and stays crisp at every size and density.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 56, this.icon});

  final double size;

  /// The app icon's wallet when null; a screen with a specific job (checking
  /// email) can show its own glyph on the same tile.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final BorderRadius shape = BorderRadius.circular(size * 0.26);
    final IconData? glyph = icon;
    final PaletteTokens palette = PaletteTokens.of(context);

    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: shape,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette.mark,
        ),
        border: Border.all(
          color: palette.heroAccent.withOpacity(0.35),
          width: 0.75,
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: AppColors.scrim.withOpacity(0.28),
            blurRadius: size * 0.4,
            offset: Offset(0, size * 0.14),
          ),
        ],
      ),
      child: glyph != null
          ? Icon(glyph, size: size * 0.48, color: palette.heroAccent)
          : CustomPaint(size: Size.square(size), painter: const _WalletPainter()),
    );
  }
}

/// The launcher icon's wallet: a card tucked behind a gold wallet with a clasp.
/// Coordinates are the icon's 512 grid.
class _WalletPainter extends CustomPainter {
  const _WalletPainter();

  static const Color _stripe = Color(0xFFC9AE7E);
  static const Color _lip = Color(0xFFFFF1D2);
  static const Color _coin = Color(0xFFFCEFD3);

  static Paint _fill(Rect rect, List<Color> colors, {List<double>? stops, bool vertical = false}) {
    return Paint()
      ..isAntiAlias = true
      ..shader = LinearGradient(
        begin: vertical ? Alignment.topCenter : Alignment.topLeft,
        end: vertical ? Alignment.bottomCenter : Alignment.bottomRight,
        colors: colors,
        stops: stops,
      ).createShader(rect);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 512);
    canvas.translate(256, 256);
    canvas.scale(1.16);
    canvas.translate(-256, -256);

    // The card, tilted, behind the wallet.
    canvas.save();
    canvas.translate(232, 196);
    canvas.rotate(-11 * math.pi / 180);
    canvas.translate(-232, -196);
    const Rect card = Rect.fromLTWH(150, 142, 176, 108);
    canvas.drawRRect(
      RRect.fromRectAndRadius(card, const Radius.circular(20)),
      _fill(card, const <Color>[Color(0xFFFFFBF2), Color(0xFFE9DCC2)]),
    );
    canvas.drawRect(
      const Rect.fromLTWH(150, 170, 176, 18),
      Paint()..color = _stripe.withOpacity(0.55),
    );
    canvas.restore();

    const Rect body = Rect.fromLTWH(124, 196, 248, 168);
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, const Radius.circular(42)),
      _fill(
        body,
        const <Color>[Color(0xFFF2D59C), Color(0xFFD8AE68), Color(0xFFB07F3E)],
        stops: const <double>[0, 0.55, 1],
      ),
    );
    canvas.drawLine(
      const Offset(166, 197.5),
      const Offset(330, 197.5),
      Paint()
        ..color = _lip.withOpacity(0.55)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );

    const Rect clasp = Rect.fromLTWH(290, 246, 100, 68);
    canvas.drawRRect(
      RRect.fromRectAndRadius(clasp, const Radius.circular(34)),
      _fill(clasp, const <Color>[Color(0xFF8E6431), Color(0xFF6E4A22)], vertical: true),
    );
    canvas.drawCircle(const Offset(324, 280), 13, Paint()..color = _coin);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WalletPainter oldDelegate) => false;
}

/// The mark with the app name set in the display serif beneath it.
class BrandLockup extends StatelessWidget {
  const BrandLockup({super.key, this.markSize = 64, this.tagline});

  final double markSize;
  final String? tagline;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        BrandMark(size: markSize),
        const SizedBox(height: AppSpacing.lg),
        Text(
          AppConstants.appName,
          style: theme.textTheme.headlineLarge,
          textAlign: TextAlign.center,
        ),
        if (tagline != null) ...<Widget>[
          const SizedBox(height: AppSpacing.xs),
          Text(
            tagline!.toUpperCase(),
            style: AppTypography.eyebrow(theme.textTheme),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}
