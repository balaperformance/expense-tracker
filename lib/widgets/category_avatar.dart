import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_spacing.dart';
import '../core/theme/category_icons.dart';
import 'common/money_text.dart';

/// Rounded, tinted icon tile identifying a category.
///
/// The stored hex is lifted for dark mode via [AppColors.readableOn]: a
/// colour the user picked against a white sheet can otherwise fall below the
/// contrast floor on a near-black surface.
class CategoryAvatar extends StatelessWidget {
  const CategoryAvatar({
    super.key,
    required this.icon,
    required this.color,
    this.size = AppSpacing.avatar,
  });

  final String? icon;
  final String? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final Color tint = AppColors.readableOn(
      AppColors.fromHex(color),
      Theme.of(context).brightness,
    );

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: ToneColors.wash(context, tint),
        borderRadius: BorderRadius.circular(size * 0.29),
      ),
      child: Icon(
        CategoryIcons.resolve(icon),
        size: size * 0.46,
        color: tint,
      ),
    );
  }
}

/// Avatar for income rows, which have no category in the schema.
class IncomeAvatar extends StatelessWidget {
  const IncomeAvatar({super.key, this.size = AppSpacing.avatar});

  final double size;

  @override
  Widget build(BuildContext context) {
    return _ToneAvatar(
      size: size,
      tone: ToneColors.income(context),
      icon: Icons.south_west_rounded,
    );
  }
}

/// Avatar for a transfer leg.
///
/// Neutral slate with a horizontal-swap glyph, deliberately unlike the income
/// avatar — a transfer arriving in an account must never look like earnings.
class TransferAvatar extends StatelessWidget {
  const TransferAvatar({super.key, this.size = AppSpacing.avatar});

  final double size;

  @override
  Widget build(BuildContext context) {
    return _ToneAvatar(
      size: size,
      tone: ToneColors.transfer(context),
      icon: Icons.swap_horiz_rounded,
    );
  }
}

/// Avatar for a manual bank movement that is not an expense or income.
class LedgerAvatar extends StatelessWidget {
  const LedgerAvatar({super.key, required this.isCredit, this.size = AppSpacing.avatar});

  final bool isCredit;
  final double size;

  @override
  Widget build(BuildContext context) {
    return _ToneAvatar(
      size: size,
      tone: isCredit ? ToneColors.income(context) : ToneColors.expense(context),
      icon: isCredit ? Icons.south_west_rounded : Icons.north_east_rounded,
    );
  }
}

class _ToneAvatar extends StatelessWidget {
  const _ToneAvatar({
    required this.size,
    required this.tone,
    required this.icon,
  });

  final double size;
  final Color tone;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: ToneColors.wash(context, tone),
        borderRadius: BorderRadius.circular(size * 0.29),
      ),
      child: Icon(icon, size: size * 0.46, color: tone),
    );
  }
}

/// Circular monogram for a bank account.
class BankAvatar extends StatelessWidget {
  const BankAvatar({
    super.key,
    required this.initial,
    this.size = AppSpacing.avatar,
  });

  final String initial;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: ToneColors.wash(context, scheme.primary),
        borderRadius: BorderRadius.circular(size * 0.29),
      ),
      child: Text(
        initial,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}
