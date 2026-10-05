import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_motion.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../models/analytics.dart';
import '../../models/insights.dart';
import '../../providers/insights_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/charts/monthly_trend_chart.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import 'report_parts.dart';
import 'report_sheets.dart';
import 'spending_sheets.dart';

/// The "Where it went" lenses, in order.
const List<({String value, String label})> _groupOptions = <({String value, String label})>[
  (value: 'tag', label: 'Tags'),
  (value: 'category', label: 'Categories'),
  (value: 'merchant', label: 'Merchants'),
  (value: 'source', label: 'Paid from'),
];

/// Groups shown before "Show all N groups".
const int _groupLimit = 8;

/// Reports › Spending: any slice of spending — by tags first — summarised,
/// compared, broken down and opened up. The phone's port of the web's
/// features/reports/SpendingView.tsx; every figure comes from the shared
/// insights engine through [InsightsProvider].
class SpendingTab extends StatelessWidget {
  const SpendingTab({super.key});

  @override
  Widget build(BuildContext context) => const _SpendingBody();
}

class _SpendingBody extends StatefulWidget {
  const _SpendingBody();

  @override
  State<_SpendingBody> createState() => _SpendingBodyState();
}

class _SpendingBodyState extends State<_SpendingBody> {
  /// The bar the trend card describes; null is the latest.
  int? _selected;
  bool _showAllGroups = false;

  /// A new range or filter starts the cards afresh.
  void _reset() {
    _selected = null;
    _showAllGroups = false;
  }

  Future<void> _applyFilter(SpendingFilter filter) async {
    setState(_reset);
    await context.read<InsightsProvider>().setFilter(filter);
  }

  Future<void> _openPeriod(SpendingView view) async {
    final InsightsProvider insights = context.read<InsightsProvider>();
    final SpendingPeriodChoice? choice = await showPeriodSheet(
      context,
      presets: insights.overview?.presets ?? spendingPeriodPresets,
      preset: insights.preset,
      custom: insights.custom,
      customLabel: insights.preset == 'custom' ? view.period.label : null,
      earliest: view.earliestCustomStart,
    );
    if (choice == null || !mounted) return;
    setState(_reset);
    await insights.setPeriod(choice.preset, custom: choice.custom);
  }

  Future<void> _openFilters(SpendingView view, SpendingFilterFocus focus) async {
    final SpendingFilter? next = await showSpendingFilterSheet(
      context,
      initial: context.read<InsightsProvider>().filter,
      options: view.options,
      focus: focus,
    );
    if (next == null || !mounted) return;
    await _applyFilter(next);
  }

  @override
  Widget build(BuildContext context) {
    final InsightsProvider insights = context.watch<InsightsProvider>();
    final String currency = context.watch<SettingsProvider>().currency;
    final SpendingView? view = insights.spending;

    if (view == null) {
      if (insights.viewError != null && !insights.spendingBusy) {
        return ScrollableCentered(
          child: ErrorView(message: insights.viewError!, onRetry: insights.refreshSpending),
        );
      }
      return const ListSkeleton(rows: 5);
    }

    final SpendingFilter filter = insights.filter;
    final Map<String, String> tagNames = <String, String>{
      for (final ({String id, String name, int count}) t in view.options.tags) t.id: t.name,
    };
    final List<String> chosenTags = <String>[for (final String id in filter.tagIds) '#${tagNames[id] ?? 'tag'}'];
    final int extra = filter.extraCount;
    final bool anyFilter = chosenTags.isNotEmpty || extra > 0;
    // Without any tags there is nothing to group by tag: categories instead.
    final String groupBy = insights.groupBy == 'tag' && view.options.tags.isEmpty ? 'category' : insights.groupBy;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.md,
        AppSpacing.page,
        AppSpacing.bottomListPaddingNoFab,
      ),
      children: <Widget>[
        _FilterBar(
          periodLabel: view.period.label,
          tagsLabel: chosenTags.isEmpty
              ? 'All tags'
              : (chosenTags.length <= 2
                  ? chosenTags.join(', ')
                  : '${chosenTags.take(2).join(', ')} +${chosenTags.length - 2}'),
          tagsSelected: chosenTags.isNotEmpty,
          extra: extra,
          anyFilter: anyFilter,
          onPeriod: () => _openPeriod(view),
          onTags: () => _openFilters(view, SpendingFilterFocus.tags),
          onFilters: () => _openFilters(view, SpendingFilterFocus.all),
          onClear: () => _applyFilter(SpendingFilter.empty),
        ),
        const SizedBox(height: AppSpacing.md),
        if (insights.viewError != null) ...<Widget>[
          InlineError(message: insights.viewError!),
          const SizedBox(height: AppSpacing.md),
        ],
        // A refresh keeps the last view on screen, a little dimmed, rather
        // than blanking it for the moment the engine takes.
        AnimatedOpacity(
          opacity: insights.spendingBusy ? 0.85 : 1,
          duration: AppMotion.fast,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: view.count == 0
                ? <Widget>[
                    SurfaceCard(
                      child: EmptyState(
                        compact: true,
                        icon: Icons.search_off_rounded,
                        title: 'No spending matches',
                        message: anyFilter
                            ? 'Nothing in ${view.period.short} matches these filters.'
                            : 'No expenses recorded in ${view.period.short}.',
                        actionLabel: anyFilter ? 'Clear filters' : null,
                        onAction: anyFilter ? () => _applyFilter(SpendingFilter.empty) : null,
                      ),
                    ),
                  ]
                : _report(context, view, currency, filtered: anyFilter, groupBy: groupBy),
          ),
        ),
      ],
    );
  }

  List<Widget> _report(
    BuildContext context,
    SpendingView view,
    String currency, {
    required bool filtered,
    required String groupBy,
  }) {
    final List<SpendGroup> groups = view.groups[groupBy] ?? const <SpendGroup>[];
    return <Widget>[
      _SummaryCard(
        view: view,
        currency: currency,
        filtered: filtered,
        onSeeAll: () => showInsightRows(
          context,
          title: filtered ? 'Matching expenses' : 'All expenses',
          subtitle: view.period.short,
          ids: view.ids,
        ),
      ),
      if (view.trend.isNotEmpty) ...<Widget>[
        const SizedBox(height: AppSpacing.section),
        ReportSection(
          title: 'Spending over time',
          caption: view.byWeek ? 'By week' : 'By month',
          children: <Widget>[
            _TrendCard(
              view: view,
              currency: currency,
              selected: _selected,
              onSelected: (int index) {
                if (index != _selected) setState(() => _selected = index);
              },
              onView: (SpendBucket bucket, String title) =>
                  showInsightRows(context, title: title, ids: bucket.ids),
            ),
          ],
        ),
      ],
      const SizedBox(height: AppSpacing.section),
      ReportSection(
        title: 'Where it went',
        children: <Widget>[
          _BreakdownCard(
            view: view,
            currency: currency,
            groupBy: groupBy,
            groups: groups,
            showAll: _showAllGroups,
            onGroupBy: (String next) {
              setState(() => _showAllGroups = false);
              context.read<InsightsProvider>().setGroupBy(next);
            },
            onToggleAll: () => setState(() => _showAllGroups = !_showAllGroups),
            onOpen: (SpendGroup group) =>
                showInsightRows(context, title: group.label, subtitle: view.period.short, ids: group.ids),
          ),
        ],
      ),
      if (view.largest.isNotEmpty) ...<Widget>[
        const SizedBox(height: AppSpacing.section),
        ReportSection(
          title: 'Largest expenses',
          caption: view.period.short,
          children: <Widget>[
            CardList(
              children: <Widget>[
                for (final InsightRow row in view.largest)
                  InsightRowTile(
                    row: row,
                    currency: currency,
                    onTap: () => openInsightExpense(context, row.id),
                  ),
              ],
            ),
          ],
        ),
      ],
    ];
  }
}

/// The range, the tags and the other filters, as chips that open their sheet.
/// Scrolls sideways rather than wrapping, as the web's bar does.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.periodLabel,
    required this.tagsLabel,
    required this.tagsSelected,
    required this.extra,
    required this.anyFilter,
    required this.onPeriod,
    required this.onTags,
    required this.onFilters,
    required this.onClear,
  });

  final String periodLabel;
  final String tagsLabel;
  final bool tagsSelected;
  final int extra;
  final bool anyFilter;
  final VoidCallback onPeriod;
  final VoidCallback onTags;
  final VoidCallback onFilters;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Spending filters',
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            AppChoiceChip(
              label: periodLabel,
              icon: Icons.calendar_today_rounded,
              selected: false,
              onSelected: onPeriod,
            ),
            const SizedBox(width: AppSpacing.sm),
            AppChoiceChip(
              label: tagsLabel,
              icon: Icons.sell_outlined,
              selected: tagsSelected,
              onSelected: onTags,
            ),
            const SizedBox(width: AppSpacing.sm),
            AppChoiceChip(
              label: extra > 0 ? 'Filters · $extra' : 'Filters',
              icon: Icons.tune_rounded,
              selected: extra > 0,
              onSelected: onFilters,
            ),
            if (anyFilter) ...<Widget>[
              const SizedBox(width: AppSpacing.xs),
              AppButton(
                label: 'Clear',
                variant: AppButtonVariant.ghost,
                size: AppButtonSize.small,
                onPressed: onClear,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The slice's total against the period before, three figures, and what the
/// engine found worth saying about it.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.view,
    required this.currency,
    required this.filtered,
    required this.onSeeAll,
  });

  final SpendingView view;
  final String currency;
  final bool filtered;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // The change wraps beneath the figure rather than squeezing it.
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.xs,
            children: <Widget>[
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    (filtered ? 'Matching spending' : 'Total spending').toUpperCase(),
                    style: AppTypography.eyebrow(theme.textTheme),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  MoneyText(
                    view.total,
                    currency: currency,
                    style: theme.textTheme.displaySmall,
                    fit: true,
                    animate: true,
                  ),
                ],
              ),
              if (!view.previousIncomplete)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: DeltaText(change: view.change, label: 'vs ${view.previous.short}'),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          FigureRow(
            figures: <ReportFigure>[
              ReportFigure('Expenses', '${view.count}'),
              ReportFigure('Average', shortMoney(view.average, currency)),
              ReportFigure(
                filtered ? 'Of all spending' : 'Before',
                filtered
                    ? Formatters.percent(view.shareOfAll)
                    : (view.previousIncomplete ? '—' : shortMoney(view.previousTotal, currency)),
              ),
            ],
          ),
          if (view.summary.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            SentenceList(lines: view.summary),
          ] else
            const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              label: 'See all ${plural(view.count, 'expense', 'expenses')}',
              icon: Icons.arrow_forward_rounded,
              variant: AppButtonVariant.tonal,
              size: AppButtonSize.small,
              onPressed: onSeeAll,
            ),
          ),
        ],
      ),
    );
  }
}

/// Bars by week or month; the selected one is named, totalled and opened.
class _TrendCard extends StatelessWidget {
  const _TrendCard({
    required this.view,
    required this.currency,
    required this.selected,
    required this.onSelected,
    required this.onView,
  });

  final SpendingView view;
  final String currency;
  final int? selected;
  final ValueChanged<int> onSelected;
  final void Function(SpendBucket bucket, String title) onView;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<SpendBucket> trend = view.trend;
    final int index = math.min(selected ?? trend.length - 1, trend.length - 1);
    final SpendBucket bucket = trend[index];
    final String title = view.byWeek ? 'Week of ${bucket.label}' : bucket.label;
    final bool running = DateUtils.isSameDay(bucket.end, AppDateUtils.today());
    final ({String current, String previous, double currentTotal, double previousTotal, double? change})? mom =
        view.monthOverMonth;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          MonthlyTrendChart(
            points: <MonthlyPoint>[
              for (final SpendBucket b in trend) MonthlyPoint(month: b.start, expense: b.total, income: 0),
            ],
            currency: currency,
            height: 180,
            selectedIndex: index,
            onSelected: onSelected,
            labelOf: (int i) => i >= 0 && i < trend.length ? trend[i].label : '',
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '$title${running ? ' · so far' : ''}',
                      style: theme.textTheme.labelSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      '${Formatters.currency(bucket.total, currencyCode: currency)} · '
                      '${plural(bucket.count, 'expense', 'expenses')}',
                      style: AppTypography.money(theme.textTheme.titleSmall),
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
              if (bucket.count > 0) ...<Widget>[
                const SizedBox(width: AppSpacing.sm),
                AppButton(
                  label: 'View',
                  icon: Icons.arrow_forward_rounded,
                  variant: AppButtonVariant.ghost,
                  size: AppButtonSize.small,
                  onPressed: () => onView(bucket, title),
                ),
              ],
            ],
          ),
          if (mom != null && mom.previousTotal > 0) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Text.rich(
              TextSpan(
                text: 'Month over month: ${shortMoney(mom.currentTotal, currency)} in ${mom.current} against '
                    '${shortMoney(mom.previousTotal, currency)} in ${mom.previous} ',
                children: <InlineSpan>[
                  if (mom.change != null)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: DeltaText(change: mom.change),
                    ),
                ],
              ),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

/// "Where it went": the slice by tag, category, merchant or source.
class _BreakdownCard extends StatelessWidget {
  const _BreakdownCard({
    required this.view,
    required this.currency,
    required this.groupBy,
    required this.groups,
    required this.showAll,
    required this.onGroupBy,
    required this.onToggleAll,
    required this.onOpen,
  });

  final SpendingView view;
  final String currency;
  final String groupBy;
  final List<SpendGroup> groups;
  final bool showAll;
  final ValueChanged<String> onGroupBy;
  final VoidCallback onToggleAll;
  final ValueChanged<SpendGroup> onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool noTags = groupBy == 'tag' && view.options.tags.isEmpty;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (groupBy == 'tag' && view.multiTagged) ...<Widget>[
            Text('An expense with several tags counts under each', style: theme.textTheme.labelSmall),
            const SizedBox(height: AppSpacing.sm),
          ],
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: <ButtonSegment<String>>[
                for (final ({String value, String label}) option in _groupOptions)
                  ButtonSegment<String>(
                    value: option.value,
                    // Four segments share 268dp on a 320dp phone: a label
                    // shrinks a little rather than breaking mid-word.
                    label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(option.label, maxLines: 1, softWrap: false),
                    ),
                  ),
              ],
              selected: <String>{groupBy},
              showSelectedIcon: false,
              style: const ButtonStyle(
                padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
                  EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                ),
              ),
              onSelectionChanged: (Set<String> next) => onGroupBy(next.first),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (noTags)
            const AppNotice(
              icon: Icons.sell_outlined,
              message: 'No tags yet. Tag expenses (for example #carspending or #family) to see '
                  'spending by tag here.',
            )
          else ...<Widget>[
            RankedRows(
              items: <RankedItem>[
                for (final SpendGroup g in groups)
                  RankedItem(
                    key: g.key,
                    label: g.label,
                    total: g.total,
                    count: g.count,
                    share: g.share,
                    tone: groupBy == 'category' ? hexColor(g.color) : null,
                    detail: '${Formatters.percent(g.share)} · ${plural(g.count, 'expense', 'expenses')}',
                  ),
              ],
              currency: currency,
              limit: showAll ? null : _groupLimit,
              onOpen: (RankedItem item) {
                for (final SpendGroup g in groups) {
                  if (g.key == item.key) return onOpen(g);
                }
              },
            ),
            MoreToggle(
              shown: _groupLimit,
              total: groups.length,
              expanded: showAll,
              onToggle: onToggleAll,
              noun: 'groups',
            ),
          ],
        ],
      ),
    );
  }
}
