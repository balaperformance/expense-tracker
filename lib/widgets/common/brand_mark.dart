import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

/// The app's mark: an espresso tile with a tan wallet glyph.
///
/// Drawn in code — a gradient, a hairline and an icon from the bundled
/// Material font — so the identity costs no image asset and stays crisp at
/// every size and density.
class BrandMark extends StatelessWidget {
  const BrandMark({
    super.key,
    this.size = 56,
    this.icon = Icons.account_balance_wallet_rounded,
  });

  final double size;

  /// The wallet by default; a screen with a specific job (checking email)
  /// can show its own glyph on the same tile.
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final BorderRadius shape = BorderRadius.circular(size * 0.3);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: shape,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: AppColors.heroLight,
        ),
        border: Border.all(
          color: AppColors.tan.withOpacity(0.35),
          width: 0.75,
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: AppColors.espresso.withOpacity(0.28),
            blurRadius: size * 0.4,
            offset: Offset(0, size * 0.14),
          ),
        ],
      ),
      child: Icon(
        icon,
        size: size * 0.48,
        color: AppColors.tan,
      ),
    );
  }
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
