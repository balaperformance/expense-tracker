import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../models/insights.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/surface_card.dart';
import '../../widgets/transaction_tile.dart';

/// The Reports screen's shared pieces — the phone's counterparts of the web's
/// features/reports/parts.tsx and sections.ts.

/// An amount for a sentence or a figure: whole units, no paise ("₹4,200").
/// Figures in summaries are estimates; exact amounts are on the rows.
String proseMoney(double amount, String currency) {
  final String text = Formatters.currency(amount.roundToDouble(), currencyCode: currency);
  return text.replaceAll(RegExp(r'[.,]00$'), '');
}

/// A short amount for tight spaces: "₹1.5K" from a thousand up.
String shortMoney(double amount, String currency) => amount.abs() >= 1000
    ? Formatters.currency(amount, currencyCode: currency, compact: true)
    : proseMoney(amount, currency);

String plural(int count, String one, String many) => '$count ${count == 1 ? one : many}';

/// The analytics sections a highlight or chip can jump to, in order.
const List<({String id, String label})> reportSections = <({String id, String label})>[
  (id: 'changes', label: 'What changed'),
  (id: 'recurring', label: 'Recurring'),
  (id: 'savings', label: 'Savings'),
  (id: 'unusual', label: 'Unusual'),
  (id: 'patterns', label: 'Patterns'),
  (id: 'trends', label: 'Trends'),
  (id: 'cashflow', label: 'Cash flow'),
  (id: 'cards', label: 'Cards'),
];

/// Red, orange, yellow, green, blue — through the theme's own tones.
Color highlightTone(BuildContext context, String tone) => switch (tone) {
      'alert' => ToneColors.expense(context),
      'warning' => ToneColors.warning(context),
      'caution' => Theme.of(context).colorScheme.secondary,
      'positive' => ToneColors.income(context),
      _ => Theme.of(context).colorScheme.primary,
    };

String highlightToneLabel(String tone) => switch (tone) {
      'alert' => 'Needs attention',
      'warning' => 'Worth a look',
      'caution' => 'Good to know',
      'positive' => 'Going well',
      _ => 'Coming up',
    };

/// A titled block of the screen, its caption under the title.
class ReportSection extends StatelessWidget {
  const ReportSection({
    super.key,
    required this.title,
    this.caption,
    required this.children,
  });

  final String title;
  final String? caption;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionHeader(
          title: title,
          padding: EdgeInsets.fromLTRB(
            AppSpacing.xs,
            0,
            AppSpacing.xs,
            caption == null ? AppSpacing.xs + 2 : 0,
          ),
        ),
        // Under the title, as on the web: a caption can be a whole sentence.
        if (caption != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.xs, 0, AppSpacing.xs, AppSpacing.sm),
            child: Text(caption!, style: Theme.of(context).textTheme.labelSmall),
          ),
        for (int i = 0; i < children.length; i++) ...<Widget>[
          if (i != 0) const SizedBox(height: AppSpacing.sm),
          children[i],
        ],
      ],
    );
  }
}

/// "▲ 22%" against an earlier figure. Spending going up is the warning colour.
class DeltaText extends StatelessWidget {
  const DeltaText({super.key, required this.change, this.label});

  final double? change;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final double? value = change;
    if (value == null) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final bool flat = value.abs() < 0.005;
    final bool up = value > 0;
    final Color tone = flat
        ? theme.colorScheme.onSurfaceVariant
        : (up ? ToneColors.expense(context) : ToneColors.income(context));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (!flat)
          Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 13, color: tone),
        Text(
          flat ? 'No change' : Formatters.percent(value.abs()),
          style: theme.textTheme.labelMedium?.copyWith(color: tone, fontWeight: FontWeight.w700),
        ),
        if (label != null) ...<Widget>[
          const SizedBox(width: AppSpacing.xs),
          Flexible(
            child: Text(
              label!,
              style: theme.textTheme.labelSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }
}

/// A small label over a figure; three to a row.
class ReportFigure {
  const ReportFigure(this.label, this.value, {this.tone});

  final String label;
  final String value;
  final Color? tone;
}

class FigureRow extends StatelessWidget {
  const FigureRow({super.key, required this.figures});

  final List<ReportFigure> figures;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Three across on a phone; never narrower than a figure can be read.
        final int perRow = math.max(1, math.min(3, (constraints.maxWidth / 96).floor()));
        final double width = (constraints.maxWidth - AppSpacing.md * (perRow - 1)) / perRow;
        return Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: <Widget>[
            for (final ReportFigure f in figures)
              SizedBox(
                width: width,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(f.label, style: theme.textTheme.labelSmall, maxLines: 2),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      f.value,
                      style: theme.textTheme.titleMedium?.copyWith(color: f.tone),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Plain-language findings as a short list.
class SentenceList extends StatelessWidget {
  const SentenceList({super.key, required this.lines, this.icon = Icons.lightbulb_outline_rounded});

  final List<String> lines;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final String line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(icon, size: 15, color: theme.colorScheme.secondary),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(line, style: theme.textTheme.bodySmall)),
              ],
            ),
          ),
      ],
    );
  }
}

/// A thin bar for a share or a ratio.
class ShareBar extends StatelessWidget {
  const ShareBar({super.key, required this.ratio, required this.tone});

  final double ratio;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
      child: LinearProgressIndicator(
        value: ratio.clamp(0, 1).toDouble(),
        minHeight: 6,
        color: tone,
        backgroundColor: ToneColors.wash(context, tone),
      ),
    );
  }
}

/// One ranked row's content.
class RankedItem {
  const RankedItem({
    required this.key,
    required this.label,
    required this.total,
    required this.count,
    required this.share,
    this.tone,
    this.detail,
  });

  final String key;
  final String label;
  final double total;
  final int count;
  final double share;
  final Color? tone;
  final String? detail;
}

/// Ranked rows with a share bar; a tap opens what is behind the row.
class RankedRows extends StatelessWidget {
  const RankedRows({
    super.key,
    required this.items,
    required this.currency,
    required this.onOpen,
    this.limit,
  });

  final List<RankedItem> items;
  final String currency;
  final ValueChanged<RankedItem> onOpen;
  final int? limit;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<Color> palette = chartTones(context);
    final List<RankedItem> shown = limit == null || items.length <= limit! ? items : items.sublist(0, limit);
    return Column(
      children: <Widget>[
        for (int i = 0; i < shown.length; i++)
          Semantics(
            button: true,
            label: '${shown[i].label}: show transactions',
            excludeSemantics: true,
            child: InkWell(
              onTap: () => onOpen(shown[i]),
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: shown[i].tone ?? palette[i % palette.length],
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  shown[i].label,
                                  style: theme.textTheme.titleSmall,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              MoneyText(shown[i].total, currency: currency, compact: true, style: theme.textTheme.titleSmall),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          ShareBar(ratio: shown[i].share, tone: shown[i].tone ?? palette[i % palette.length]),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            shown[i].detail ?? '${Formatters.percent(shown[i].share)} · ${shown[i].count}',
                            style: theme.textTheme.labelSmall,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Icon(Icons.chevron_right_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The six chart tones, for rows without a colour of their own.
List<Color> chartTones(BuildContext context) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  return <Color>[
    ToneColors.expense(context),
    scheme.primary,
    ToneColors.warning(context),
    ToneColors.income(context),
    scheme.secondary,
    ToneColors.transfer(context),
  ];
}

/// A stored category colour, or null.
Color? hexColor(String? hex) {
  if (hex == null) return null;
  final String digits = hex.replaceFirst('#', '');
  if (digits.length != 6) return null;
  final int? value = int.tryParse(digits, radix: 16);
  return value == null ? null : Color(0xFF000000 | value);
}

/// "Show all 14 groups" / "Show fewer".
class MoreToggle extends StatelessWidget {
  const MoreToggle({
    super.key,
    required this.shown,
    required this.total,
    required this.expanded,
    required this.onToggle,
    required this.noun,
  });

  final int shown;
  final int total;
  final bool expanded;
  final VoidCallback onToggle;
  final String noun;

  @override
  Widget build(BuildContext context) {
    if (total <= shown && !expanded) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: AppButton(
        label: expanded ? 'Show fewer' : 'Show all $total $noun',
        variant: AppButtonVariant.ghost,
        size: AppButtonSize.small,
        onPressed: onToggle,
      ),
    );
  }
}

/// An estimated saving, always marked as one.
class SavingPill extends StatelessWidget {
  const SavingPill({super.key, required this.saving, required this.currency});

  final InsightSaving saving;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color tone = ToneColors.income(context);
    return Tooltip(
      message: 'An estimate from your own history',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
        decoration: BoxDecoration(
          color: ToneColors.wash(context, tone),
          borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.account_balance_wallet_outlined, size: 14, color: tone),
            const SizedBox(width: AppSpacing.xs),
            Flexible(
              child: Text(
                'Could save ~${shortMoney(saving.monthly.roundToDouble(), currency)}/mo · '
                '~${shortMoney(saving.yearly.roundToDouble(), currency)}/yr',
                style: theme.textTheme.labelSmall?.copyWith(color: tone, fontWeight: FontWeight.w700),
                maxLines: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A tiny line of monthly figures, for a trend at a glance.
class SparkLine extends StatelessWidget {
  const SparkLine({super.key, required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (values.length < 2) return const SizedBox(width: 64, height: 22);
    return ExcludeSemantics(
      child: CustomPaint(size: const Size(64, 22), painter: _SparkPainter(values, color)),
    );
  }
}

class _SparkPainter extends CustomPainter {
  const _SparkPainter(this.values, this.color);

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double maxValue = values.fold<double>(0, math.max);
    final double step = size.width / (values.length - 1);
    final Path path = Path();
    for (int i = 0; i < values.length; i++) {
      final double y = size.height - 2 - (maxValue > 0 ? values[i] / maxValue * (size.height - 4) : 0);
      if (i == 0) {
        path.moveTo(0, y);
      } else {
        path.lineTo(i * step, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.values != values || old.color != color;
}

/// One expense from the insights, as a list row.
class InsightRowTile extends StatelessWidget {
  const InsightRowTile({super.key, required this.row, required this.currency, this.onTap});

  final InsightRow row;
  final String currency;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return TransactionRow(
      leading: CategoryAvatar(icon: row.categoryIcon, color: row.categoryColor),
      title: row.title,
      meta: <String>[
        Formatters.relativeDay(row.date),
        row.categoryName,
        if (row.funding != null) row.funding!,
        if (row.refunded > 0) '${Formatters.currency(row.refunded, currencyCode: currency)} refunded',
      ],
      amount: -row.amount,
      currency: currency,
      tone: AmountTone.negative,
      onTap: onTap,
    );
  }
}

