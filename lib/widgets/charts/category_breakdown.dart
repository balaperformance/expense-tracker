import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_chart_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/category_icons.dart';
import '../../core/utils/formatters.dart';
import '../../models/analytics.dart';
import '../common/money_text.dart';

/// Donut of spend by category with the period total in the middle.
///
/// Only the largest slices are drawn individually; the rest collapse into a
/// neutral "Other" so the ring stays readable instead of becoming a barcode.
///
/// Slices are coloured by rank from the Pastel Garden chart palette
/// ([ChartColors]), not by each category's stored colour: a ring of six
/// arbitrary user colours has no palette at all. [CategoryBreakdownList]
/// resolves the same colours, so it works as the legend.
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

    final List<_Slice> slices = _buildSlices(ChartColors.of(context));

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

  List<_Slice> _buildSlices(ChartColors palette) {
    final int count = breakdown.length;
    _Slice slice(int rank) => _Slice(
          breakdown[rank].total,
          palette.segment(rank, count, maxSlices: maxSlices),
        );

    if (count <= maxSlices) {
      return <_Slice>[for (int i = 0; i < count; i++) slice(i)];
    }

    final List<_Slice> slices = <_Slice>[
      for (int i = 0; i < maxSlices - 1; i++) slice(i),
    ];

    final double rest = breakdown
        .skip(maxSlices - 1)
        .fold<double>(0, (double sum, CategorySpend c) => sum + c.total);

    if (rest > 0) slices.add(_Slice(rest, palette.other));
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
    this.maxSlices = 6,
  });

  final List<CategorySpend> breakdown;
  final String currency;

  /// Caps how many rows are shown — the dashboard shows the top few, Reports
  /// shows them all.
  final int? limit;

  /// Must match the donut this list sits under, so each row takes its
  /// slice's colour — "Other" included.
  final int maxSlices;

  @override
  Widget build(BuildContext context) {
    if (breakdown.isEmpty) return const SizedBox.shrink();

    final double total = breakdown.fold<double>(
      0,
      (double sum, CategorySpend c) => sum + c.total,
    );

    final List<CategorySpend> visible =
        limit == null ? breakdown : breakdown.take(limit!).toList();
    final ChartColors palette = ChartColors.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < visible.length; i++) ...<Widget>[
          if (i != 0) const SizedBox(height: AppSpacing.md),
          _CategoryRow(
            spend: visible[i],
            share: visible[i].shareOf(total),
            currency: currency,
            tone: palette.segment(i, breakdown.length, maxSlices: maxSlices),
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
    required this.tone,
  });

  final CategorySpend spend;
  final double share;
  final String currency;

  /// The row's slice colour in the donut above it.
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Row(
      children: <Widget>[
        // A legend swatch rather than the usual category avatar: a strong
        // wash of the slice colour with the icon in neutral ink. The avatar's
        // tinted-icon-on-faint-wash would put a blush icon at 1.7:1.
        Container(
          width: AppSpacing.avatarSm,
          height: AppSpacing.avatarSm,
          decoration: BoxDecoration(
            color: tone.withOpacity(
              theme.brightness == Brightness.dark ? 0.34 : 0.32,
            ),
            borderRadius: BorderRadius.circular(AppSpacing.avatarSm * 0.29),
          ),
          child: Icon(
            CategoryIcons.resolve(spend.icon),
            size: AppSpacing.avatarSm * 0.46,
            color: theme.colorScheme.onSurface,
          ),
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
