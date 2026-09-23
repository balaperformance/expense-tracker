import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../models/analytics.dart';
import '../category_avatar.dart';
import '../common/money_text.dart';

/// Donut of spend by category with the period total in the middle.
///
/// Only the largest slices are drawn individually; the rest collapse into a
/// neutral "Other" so the ring stays readable instead of becoming a barcode.
class CategoryDonut extends StatelessWidget {
  const CategoryDonut({
    super.key,
    required this.breakdown,
    required this.currency,
    this.maxSlices = 6,
    this.size = 148,
  });

  final List<CategorySpend> breakdown;
  final String currency;
  final int maxSlices;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (breakdown.isEmpty) return const SizedBox.shrink();

    final double total = breakdown.fold<double>(
      0,
      (double sum, CategorySpend c) => sum + c.total,
    );

    final List<_Slice> slices = _buildSlices(theme.brightness);

    return SizedBox(
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          PieChart(
            PieChartData(
              sectionsSpace: 2,
              centerSpaceRadius: size * 0.33,
              startDegreeOffset: -90,
              sections: slices.map((_Slice slice) {
                return PieChartSectionData(
                  value: slice.value,
                  color: slice.color,
                  radius: size * 0.15,
                  showTitle: false,
                );
              }).toList(),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('Total spent', style: theme.textTheme.labelSmall),
              const SizedBox(height: AppSpacing.xxs),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: MoneyText(
                  total,
                  currency: currency,
                  compact: true,
                  fit: true,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<_Slice> _buildSlices(Brightness brightness) {
    Color tint(CategorySpend c) =>
        AppColors.readableOn(AppColors.fromHex(c.color), brightness);

    if (breakdown.length <= maxSlices) {
      return breakdown
          .map((CategorySpend c) => _Slice(c.total, tint(c)))
          .toList();
    }

    final List<_Slice> slices = breakdown
        .take(maxSlices - 1)
        .map((CategorySpend c) => _Slice(c.total, tint(c)))
        .toList();

    final double rest = breakdown
        .skip(maxSlices - 1)
        .fold<double>(0, (double sum, CategorySpend c) => sum + c.total);

    if (rest > 0) slices.add(_Slice(rest, AppColors.chartOther));
    return slices;
  }
}

class _Slice {
  const _Slice(this.value, this.color);

  final double value;
  final Color color;
}

/// Ranked category list with a share bar under each name.
class CategoryBreakdownList extends StatelessWidget {
  const CategoryBreakdownList({
    super.key,
    required this.breakdown,
    required this.currency,
    this.limit,
  });

  final List<CategorySpend> breakdown;
  final String currency;

  /// Caps how many rows are shown — the dashboard shows the top few, Reports
  /// shows them all.
  final int? limit;

  @override
  Widget build(BuildContext context) {
    if (breakdown.isEmpty) return const SizedBox.shrink();

    final double total = breakdown.fold<double>(
      0,
      (double sum, CategorySpend c) => sum + c.total,
    );

    final List<CategorySpend> visible =
        limit == null ? breakdown : breakdown.take(limit!).toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < visible.length; i++) ...<Widget>[
          if (i != 0) const SizedBox(height: AppSpacing.md),
          _CategoryRow(
            spend: visible[i],
            share: visible[i].shareOf(total),
            currency: currency,
          ),
        ],
      ],
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.spend,
    required this.share,
    required this.currency,
  });

  final CategorySpend spend;
  final double share;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color tone = AppColors.readableOn(
      AppColors.fromHex(spend.color),
      theme.brightness,
    );

    return Row(
      children: <Widget>[
        CategoryAvatar(
          icon: spend.icon,
          color: spend.color,
          size: AppSpacing.avatarSm,
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      spend.name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  MoneyText(
                    spend.total,
                    currency: currency,
                    compact: true,
                    style: theme.textTheme.titleSmall,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: <Widget>[
                  Expanded(
                    child: ClipRRect(
                      borderRadius:
                          BorderRadius.circular(AppSpacing.radiusPill),
                      child: TweenAnimationBuilder<double>(
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.easeOutCubic,
                        tween: Tween<double>(
                          begin: 0,
                          end: share.clamp(0.0, 1.0),
                        ),
                        builder:
                            (BuildContext context, double value, Widget? _) {
                          return LinearProgressIndicator(
                            value: value,
                            minHeight: 5,
                            backgroundColor: ToneColors.wash(context, tone),
                            valueColor: AlwaysStoppedAnimation<Color>(tone),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  SizedBox(
                    width: 34,
                    child: Text(
                      Formatters.percent(share),
                      textAlign: TextAlign.right,
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
