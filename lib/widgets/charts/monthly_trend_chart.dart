import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_chart_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../../models/analytics.dart';
import '../common/money_text.dart';

/// Monthly bars: expenses alone, or expenses against income.
///
/// Kept deliberately plain — three horizontal guides, short month labels,
/// compact axis figures. A chart in a finance app has to be read in a second;
/// anything that makes it look more impressive makes it slower to read.
class MonthlyTrendChart extends StatelessWidget {
  const MonthlyTrendChart({
    super.key,
    required this.points,
    required this.currency,
    this.showIncome = false,
    this.height = 164,
    this.selectedIndex,
    this.onSelected,
  });

  final List<MonthlyPoint> points;
  final String currency;
  final bool showIncome;
  final double height;

  /// Which month is emphasised. Defaults to the most recent, which is the one
  /// the user opened the app about.
  final int? selectedIndex;

  /// Set to make the bars selectable. The chart stays stateless — the owner
  /// holds the selection, because the figure above the chart has to agree
  /// with it.
  final ValueChanged<int>? onSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (points.isEmpty) return SizedBox(height: height);

    final double maxValue =
        points.fold<double>(0, (double max, MonthlyPoint p) {
      final double local = showIncome
          ? (p.expense > p.income ? p.expense : p.income)
          : p.expense;
      return local > max ? local : max;
    });

    // A non-zero ceiling keeps the axis stable when every month is empty.
    final double ceiling = maxValue <= 0 ? 100 : maxValue * 1.2;
    final double step = ceiling / 3;
    // Bars come from the Pastel Garden chart palette, never the app theme.
    // Expenses alone: the selected month stands out (deep brown on the light
    // theme's taupe-tinted cards, rose in dark), the rest recede. Against income:
    // rose for money out, gray-green for money in.
    final ChartColors palette = ChartColors.of(context);

    Color expenseBar(bool isSelected) {
      if (!showIncome) return isSelected ? palette.emphasis : palette.idle;
      return isSelected ? palette.expense : palette.expense.withOpacity(0.5);
    }

    Color incomeBar(bool isSelected) =>
        isSelected ? palette.income : palette.income.withOpacity(0.5);

    // The selected month is the one the user cares about; the others are
    // context, so they are drawn back a little.
    final int lastIndex = points.length - 1;
    final int selected = (selectedIndex ?? lastIndex).clamp(0, lastIndex);

    return SizedBox(
      height: height,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: ceiling,
          minY: 0,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: step,
            getDrawingHorizontalLine: (double value) => FlLine(
              color: theme.colorScheme.outline,
              strokeWidth: 1,
            ),
          ),
          borderData: FlBorderData(show: false),
          barTouchData: BarTouchData(
            enabled: true,
            // A bar is a few pixels wide and a month with no spending is a
            // few pixels tall, so the rod itself is a poor target. Extending
            // the hit area up the full column and out to the gaps makes every
            // month tappable, including the empty ones.
            touchExtraThreshold: const EdgeInsets.symmetric(
              vertical: 260,
              horizontal: 12,
            ),
            touchCallback: onSelected == null
                ? null
                : (FlTouchEvent event, BarTouchResponse? response) {
                    // Only act on a settled gesture, so dragging across the
                    // chart does not fire a selection per pixel.
                    if (!event.isInterestedForInteractions) return;
                    final int? index = response?.spot?.touchedBarGroupIndex;
                    if (index != null && index >= 0 && index < points.length) {
                      onSelected!(index);
                    }
                  },
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (BarChartGroupData _) =>
                  theme.colorScheme.inverseSurface,
              tooltipRoundedRadius: AppSpacing.radiusXs,
              tooltipPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              getTooltipItem: (
                BarChartGroupData group,
                int groupIndex,
                BarChartRodData rod,
                int rodIndex,
              ) {
                return BarTooltipItem(
                  Formatters.currency(
                    rod.toY,
                    currencyCode: currency,
                    compact: true,
                  ),
                  AppTypography.money(
                    theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onInverseSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                );
              },
            ),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                // Wide enough for "₹88.0K" on one line; the FittedBox below
                // shrinks anything longer rather than wrapping it.
                reservedSize: 48,
                interval: step,
                getTitlesWidget: (double value, TitleMeta meta) {
                  // The zero line is implied by the baseline; labelling it
                  // only adds noise.
                  if (value <= 0 || value > ceiling - step * 0.4) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.sm),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        Formatters.currency(
                          value,
                          currencyCode: currency,
                          compact: true,
                        ),
                        style:
                            AppTypography.money(theme.textTheme.labelSmall),
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ),
                  );
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                getTitlesWidget: (double value, TitleMeta meta) {
                  final int index = value.toInt();
                  if (index < 0 || index >= points.length) {
                    return const SizedBox.shrink();
                  }
                  final bool isSelected = index == selected;
                  return Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: 2,
                      ),
                      decoration: isSelected
                          ? BoxDecoration(
                              // A filled pill rather than bold text: at 11px
                              // a weight change is nearly invisible, and the
                              // selected month has to be obvious at a glance.
                              color: palette.emphasis.withOpacity(0.18),
                              borderRadius: BorderRadius.circular(
                                AppSpacing.radiusPill,
                              ),
                            )
                          : null,
                      child: Text(
                        Formatters.shortMonth(points[index].month),
                        style: theme.textTheme.labelSmall?.copyWith(
                          // Deep brown on the rose wash (7:1), not rose on
                          // rose: an 11px label needs 4.5:1.
                          color: isSelected
                              ? palette.labelOnEmphasis
                              : theme.colorScheme.onSurfaceVariant,
                          fontWeight:
                              isSelected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          barGroups: List<BarChartGroupData>.generate(points.length, (int i) {
            final MonthlyPoint point = points[i];
            final bool isSelected = i == selected;

            return BarChartGroupData(
              x: i,
              barsSpace: 3,
              barRods: <BarChartRodData>[
                BarChartRodData(
                  toY: point.expense,
                  color: expenseBar(isSelected),
                  width: showIncome ? 7 : (isSelected ? 16 : 12),
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(showIncome ? 4 : 6),
                  ),
                  // No background track. A full-height rod behind the
                  // selected bar reads as a floating dark block above it on a
                  // dark background rather than as a track — the width, the
                  // colour and the pill under the month label already say
                  // which bar is selected.
                ),
                if (showIncome)
                  BarChartRodData(
                    toY: point.income,
                    color: incomeBar(isSelected),
                    width: 7,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(3),
                    ),
                  ),
              ],
            );
          }),
        ),
      ),
    );
  }
}

/// The trend chart plus the figure for whichever month is selected.
///
/// The chart alone left most of its card empty — six months of bars against a
/// ceiling set by the tallest one, and nothing saying what any bar was worth.
/// The header answers that: it names the selected month, states its total,
/// and compares it with the month before.
///
/// Tapping a column moves the selection, so the same card answers "what did I
/// spend in June?" without a second screen. The selection lives here rather
/// than in the chart because the figure and the bars have to agree.
class MonthlyTrendCard extends StatefulWidget {
  const MonthlyTrendCard({
    super.key,
    required this.points,
    required this.currency,
    this.chartHeight = 168,
  });

  final List<MonthlyPoint> points;
  final String currency;
  final double chartHeight;

  @override
  State<MonthlyTrendCard> createState() => _MonthlyTrendCardState();
}

class _MonthlyTrendCardState extends State<MonthlyTrendCard> {
  /// Null means "the latest month", which is what the card opens on and what
  /// it falls back to when the data reloads with a different number of months.
  int? _selected;

  int get _index {
    final int last = widget.points.length - 1;
    if (last < 0) return 0;
    return (_selected ?? last).clamp(0, last);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (widget.points.isEmpty) return const SizedBox.shrink();

    final int index = _index;
    final MonthlyPoint point = widget.points[index];
    final double previous =
        index > 0 ? widget.points[index - 1].expense : -1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    Formatters.monthYear(point.month),
                    style: theme.textTheme.labelSmall,
                  ),
                  const SizedBox(height: AppSpacing.xxs),
                  MoneyText(
                    point.expense,
                    currency: widget.currency,
                    tone: AmountTone.negative,
                    // Counting between months makes the comparison legible
                    // as a change rather than a redraw.
                    animate: true,
                    fit: true,
                    style: theme.textTheme.headlineSmall,
                  ),
                ],
              ),
            ),
            // Only shown when there is a real comparison to make. A month
            // following an empty one has no percentage, and a bare "vs Aug"
            // badge states nothing while looking like it should.
            if (previous > 0) ...<Widget>[
              const SizedBox(width: AppSpacing.sm),
              _DeltaBadge(
                current: point.expense,
                previous: previous,
                previousLabel:
                    Formatters.shortMonth(widget.points[index - 1].month),
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        MonthlyTrendChart(
          points: widget.points,
          currency: widget.currency,
          height: widget.chartHeight,
          selectedIndex: index,
          onSelected: (int next) {
            if (next != index) setState(() => _selected = next);
          },
        ),
      ],
    );
  }
}

/// Month-on-month change in spending.
///
/// Up is red and down is green, which is the opposite of a stock ticker and
/// the right way round for an expense: spending less is the good outcome.
class _DeltaBadge extends StatelessWidget {
  const _DeltaBadge({
    required this.current,
    required this.previous,
    required this.previousLabel,
  });

  final double current;
  final double previous;
  final String previousLabel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // The caller only builds this when the previous month is non-zero, so
    // the percentage is always a real number.
    final double change = (current - previous) / previous;
    final bool up = current > previous;
    final Color tone =
        up ? ToneColors.expense(context) : ToneColors.income(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: ToneColors.wash(context, tone),
        borderRadius: BorderRadius.circular(AppSpacing.radiusXs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            up ? Icons.north_rounded : Icons.south_rounded,
            size: 11,
            color: tone,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            '${(change.abs() * 100).round()}% vs $previousLabel',
            style: theme.textTheme.labelSmall?.copyWith(
              color: tone,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Legend dot + label pairs shown beneath a chart.
class ChartLegend extends StatelessWidget {
  const ChartLegend({super.key, required this.entries});

  final List<({String label, Color color})> entries;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.lg,
      runSpacing: AppSpacing.sm,
      children: entries.map((({String label, Color color}) entry) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: entry.color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: AppSpacing.xs + 1),
            Text(entry.label, style: Theme.of(context).textTheme.bodySmall),
          ],
        );
      }).toList(),
    );
  }
}
