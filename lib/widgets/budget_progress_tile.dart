import 'package:flutter/material.dart';

import '../core/theme/app_spacing.dart';
import '../core/utils/formatters.dart';
import '../models/budget.dart';
import 'category_avatar.dart';
import 'common/money_text.dart';
import 'common/surface_card.dart';

/// Compact budget row: name, percentage, bar, spent-of-limit, remaining.
///
/// The bar is 6px rather than a large decorative ring — the numbers are the
/// information, and the bar only has to make "how far along" readable at a
/// glance. Colour is the warning channel: green on track, amber approaching,
/// red over.
class BudgetProgressTile extends StatelessWidget {
  const BudgetProgressTile({
    super.key,
    required this.progress,
    required this.currency,
    this.onTap,
    this.showAvatar = true,
  });

  final BudgetProgress progress;
  final String currency;
  final VoidCallback? onTap;
  final bool showAvatar;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color tone = _tone(context);
    final double ratio = progress.ratio.clamp(0.0, 1.0);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                if (showAvatar) ...<Widget>[
                  CategoryAvatar(
                    icon: progress.budget.category?.icon ?? 'savings',
                    color: progress.budget.category?.color,
                    size: AppSpacing.avatarSm,
                  ),
                  const SizedBox(width: AppSpacing.md),
                ],
                Expanded(
                  child: Text(
                    progress.budget.label,
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  Formatters.percent(progress.ratio),
                  style: theme.textTheme.labelLarge?.copyWith(color: tone),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
              child: TweenAnimationBuilder<double>(
                duration: const Duration(milliseconds: 480),
                curve: Curves.easeOutCubic,
                tween: Tween<double>(begin: 0, end: ratio),
                builder: (BuildContext context, double value, Widget? _) {
                  return LinearProgressIndicator(
                    value: value,
                    minHeight: 6,
                    backgroundColor: ToneColors.wash(context, tone),
                    valueColor: AlwaysStoppedAnimation<Color>(tone),
                  );
                },
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            // Both halves scale down rather than wrap or overflow: on a
            // narrow screen a six-figure limit plus a six-figure remainder
            // does not fit at full size, and shrinking reads better than
            // truncating a number.
            Row(
              children: <Widget>[
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        MoneyText(
                          progress.spent,
                          currency: currency,
                          compact: true,
                          style: theme.textTheme.bodySmall,
                        ),
                        Text(' of ', style: theme.textTheme.bodySmall),
                        MoneyText(
                          progress.limit,
                          currency: currency,
                          compact: true,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        MoneyText(
                          progress.remaining.abs(),
                          currency: currency,
                          compact: true,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: tone,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          progress.isOver ? ' over' : ' left',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: tone,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _tone(BuildContext context) {
    if (progress.isOver) return ToneColors.expense(context);
    if (progress.isApproaching) return ToneColors.warning(context);
    return ToneColors.income(context);
  }
}

/// Compact banner warning that one or more budgets need attention.
class BudgetAlertBanner extends StatelessWidget {
  const BudgetAlertBanner({
    super.key,
    required this.alerts,
    required this.currency,
    this.onTap,
  });

  final List<BudgetProgress> alerts;
  final String currency;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (alerts.isEmpty) return const SizedBox.shrink();

    final ThemeData theme = Theme.of(context);
    final bool anyOver = alerts.any((BudgetProgress p) => p.isOver);
    final Color tone =
        anyOver ? ToneColors.expense(context) : ToneColors.warning(context);

    final BudgetProgress first = alerts.first;
    final String message = alerts.length == 1
        ? (first.isOver
            ? 'Over your ${first.budget.label.toLowerCase()}'
            : 'Close to your ${first.budget.label.toLowerCase()}')
        : '${alerts.length} budgets need attention';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: ToneColors.wash(context, tone),
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: tone.withOpacity(0.30)),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              anyOver
                  ? Icons.warning_amber_rounded
                  : Icons.info_outline_rounded,
              color: tone,
              size: AppSpacing.iconMd,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tone,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: tone,
              size: AppSpacing.iconMd,
            ),
          ],
        ),
      ),
    );
  }
}

/// Budget card wrapper, so Dashboard and Budgets render the tile identically.
class BudgetCard extends StatelessWidget {
  const BudgetCard({
    super.key,
    required this.progress,
    required this.currency,
    this.onTap,
    this.showAvatar = true,
  });

  final BudgetProgress progress;
  final String currency;
  final VoidCallback? onTap;
  final bool showAvatar;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: BudgetProgressTile(
        progress: progress,
        currency: currency,
        showAvatar: showAvatar,
        onTap: onTap,
      ),
    );
  }
}
