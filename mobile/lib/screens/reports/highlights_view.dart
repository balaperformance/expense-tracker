import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../models/insights.dart';
import '../../providers/insights_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import 'report_parts.dart';
import 'report_sheets.dart';

/// How many highlights show before "Show N more".
const int _feedLimit = 6;

IconData _topicIcon(String topic) => switch (topic) {
      'increase' || 'price' => Icons.arrow_upward_rounded,
      'decrease' => Icons.arrow_downward_rounded,
      'recurring' => Icons.event_repeat_rounded,
      'habit' => Icons.storefront_outlined,
      'charges' => Icons.warning_amber_rounded,
      'unusual' => Icons.fact_check_outlined,
      'card' => Icons.credit_card_rounded,
      'income' => Icons.south_west_rounded,
      'upcoming' => Icons.schedule_rounded,
      _ => Icons.insights_outlined,
    };

/// The few discoveries most worth attention, most money at stake first.
class HighlightsTab extends StatefulWidget {
  const HighlightsTab({super.key, required this.onSection});

  /// Jumps to an analytics section (the glance tiles, a highlight's Details).
  final ValueChanged<String> onSection;

  @override
  State<HighlightsTab> createState() => _HighlightsTabState();
}

class _HighlightsTabState extends State<HighlightsTab> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final InsightsOverview? insights = context.watch<InsightsProvider>().overview;
    final String currency = context.watch<SettingsProvider>().currency;
    if (insights == null) return const SizedBox.shrink();

    final List<Widget> children;
    if (!insights.enoughData) {
      children = const <Widget>[
        SurfaceCard(
          child: EmptyState(
            icon: Icons.insights_outlined,
            title: 'Insights need a little more history',
            message: 'Keep adding expenses for a few weeks. Changes, recurring '
                'payments and saving ideas appear here as soon as there is '
                'enough to go on.',
          ),
        ),
      ];
    } else {
      final List<InsightHighlight> highlights = insights.highlights;
      final List<InsightHighlight> shown =
          _expanded || highlights.length <= _feedLimit ? highlights : highlights.sublist(0, _feedLimit);
      final SavingIdea? topSaving = insights.savings.isEmpty ? null : insights.savings.first;
      children = <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: _GlanceTile(
                icon: Icons.event_repeat_rounded,
                label: 'Recurring',
                value: insights.runningCount == 0 ? '—' : shortMoney(insights.recurringMonthly, currency),
                caption: insights.runningCount == 0
                    ? 'None found yet'
                    : '${plural(insights.runningCount, 'payment', 'payments')} a month',
                onTap: () => widget.onSection('recurring'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _GlanceTile(
                icon: Icons.account_balance_wallet_outlined,
                label: 'Saving ideas',
                value: '${insights.savings.length}',
                caption: topSaving == null
                    ? 'Nothing stands out'
                    : 'Largest ~${shortMoney(topSaving.saving.yearly.roundToDouble(), currency)}/yr',
                onTap: () => widget.onSection('savings'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _GlanceTile(
                icon: Icons.fact_check_outlined,
                label: 'To check',
                value: '${insights.unusual.length}',
                caption: insights.unusual.isEmpty ? 'Nothing unusual' : 'Unusual transactions',
                onTap: () => widget.onSection('unusual'),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.section),
        if (shown.isEmpty)
          const SurfaceCard(
            child: EmptyState(
              compact: true,
              icon: Icons.check_circle_outline_rounded,
              title: 'Nothing needs your attention',
              message: 'Your spending looks steady. Explore Spending and '
                  'Analytics for the detail.',
            ),
          )
        else ...<Widget>[
          for (final InsightHighlight h in shown) ...<Widget>[
            _HighlightCard(
              highlight: h,
              currency: currency,
              onDrill: (InsightDrill drill) => openInsightDrill(context, drill, onSection: widget.onSection),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          if (highlights.length > _feedLimit)
            Align(
              child: AppButton(
                label: _expanded ? 'Show fewer' : 'Show ${highlights.length - _feedLimit} more',
                variant: AppButtonVariant.ghost,
                size: AppButtonSize.small,
                onPressed: () => setState(() => _expanded = !_expanded),
              ),
            ),
        ],
        const SizedBox(height: AppSpacing.md),
        const AppNotice(
          message: 'Figures come from your recorded expenses, the same ones '
              'Home and Budgets count. Transfers, loans and card bill payments '
              'are never spending. Savings, yearly costs and next dates are '
              'estimates from your history.',
        ),
      ];
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.md,
        AppSpacing.page,
        AppSpacing.bottomListPaddingNoFab,
      ),
      children: children,
    );
  }
}

class _GlanceTile extends StatelessWidget {
  const _GlanceTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.caption,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final String caption;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 15, color: theme.colorScheme.primary),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(label, style: theme.textTheme.labelSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: theme.textTheme.titleLarge),
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(caption, style: theme.textTheme.labelSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

class _HighlightCard extends StatelessWidget {
  const _HighlightCard({required this.highlight, required this.currency, required this.onDrill});

  final InsightHighlight highlight;
  final String currency;
  final ValueChanged<InsightDrill> onDrill;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color tone = highlightTone(context, highlight.tone);
    final InsightDrill? drill = highlight.drill;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: ToneColors.wash(context, tone),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(_topicIcon(highlight.topic), size: 18, color: tone),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      highlightToneLabel(highlight.tone).toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(color: tone, fontWeight: FontWeight.w700, letterSpacing: 0.6),
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(highlight.title, style: theme.textTheme.titleMedium),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(highlight.why, style: theme.textTheme.bodySmall),
          if (highlight.action != null) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(Icons.lightbulb_outline_rounded, size: 15, color: theme.colorScheme.secondary),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(highlight.action!, style: theme.textTheme.bodySmall)),
              ],
            ),
          ],
          if (highlight.saving != null || drill != null) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: <Widget>[
                if (highlight.saving != null) SavingPill(saving: highlight.saving!, currency: currency),
                if (drill != null)
                  AppButton(
                    label: drill.type == 'rows'
                        ? (drill.ids.length == 1 ? 'See transaction' : 'See transactions')
                        : 'Details',
                    icon: Icons.arrow_forward_rounded,
                    variant: AppButtonVariant.ghost,
                    size: AppButtonSize.small,
                    onPressed: () => onDrill(drill),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
