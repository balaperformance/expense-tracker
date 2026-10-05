import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_chart_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
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

/// The phone's counterpart of the web's features/reports/AnalyticsView.tsx.
/// Every figure and sentence comes from the shared insights engine through
/// [InsightsProvider]; this file only lays them out.

const List<({int value, String label})> _spans = <({int value, String label})>[
  (value: 3, label: '3 months'),
  (value: 6, label: '6 months'),
  (value: 12, label: '12 months'),
];

/// The long view's sections, which wait on the span's analysis.
const Set<String> _longView = <String>{'patterns', 'trends', 'cashflow', 'cards'};

const int _savingsLimit = 5;
const int _trendLimit = 6;

IconData _kindIcon(String kind) => switch (kind) {
      'subscription' => Icons.all_inclusive_rounded,
      'insurance' => Icons.shield_outlined,
      'fitness' => Icons.emoji_events_outlined,
      'loan' => Icons.account_balance_outlined,
      'utility' => Icons.lightbulb_outline_rounded,
      'rent' => Icons.home_outlined,
      'education' => Icons.notes_rounded,
      _ => Icons.calendar_month_outlined,
    };

/// Financial intelligence, most money at stake first: what changed, what
/// recurs, what could be saved, then the long view.
///
/// Setting [jump] to a section id ('changes', 'recurring', 'savings',
/// 'unusual', 'patterns', 'trends', 'cashflow', 'cards') scrolls that section
/// into view; the tab clears it again, so the same section can be asked for
/// twice.
class AnalyticsTab extends StatefulWidget {
  const AnalyticsTab({super.key, required this.jump});

  final ValueNotifier<String?> jump;

  @override
  State<AnalyticsTab> createState() => _AnalyticsTabState();
}

class _AnalyticsTabState extends State<AnalyticsTab> {
  final ScrollController _controller = ScrollController();
  final Map<String, GlobalKey> _keys = <String, GlobalKey>{
    for (final ({String id, String label}) s in reportSections) s.id: GlobalKey(debugLabel: 'analytics-${s.id}'),
  };

  /// Expanded lists and toggles, kept here so a section scrolled out of the
  /// list and back keeps its state.
  final Set<String> _open = <String>{};

  /// The sections on screen now, in order.
  List<String> _order = const <String>[];

  /// The long view is still loading: its placeholder stands in for it.
  bool _longViewPending = false;

  String? _pending;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    widget.jump.addListener(_onJump);
    _onJump();
  }

  @override
  void didUpdateWidget(AnalyticsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.jump != widget.jump) {
      oldWidget.jump.removeListener(_onJump);
      widget.jump.addListener(_onJump);
      _onJump();
    }
  }

  @override
  void dispose() {
    widget.jump.removeListener(_onJump);
    _controller.dispose();
    super.dispose();
  }

  void _onJump() {
    final String? section = widget.jump.value;
    if (section == null) return;
    _pending = section;
    _schedule();
  }

  /// Scrolls after the frame, when the sections are laid out. The request is
  /// cleared there rather than here: [_onJump] can run during a build.
  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      if (widget.jump.value != null) widget.jump.value = null;
      final String? section = _pending;
      // Nothing to scroll through yet; the build that shows it asks again.
      if (section == null || _order.isEmpty) return;
      _pending = null;
      _scrollTo(section);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _toggle(String key) => setState(() => _open.contains(key) ? _open.remove(key) : _open.add(key));

  String? _resolve(String id) {
    if (_order.contains(id)) return id;
    if (_longViewPending && _longView.contains(id)) return 'patterns';
    return null;
  }

  /// Brings [id]'s section to the top of the list. A section far down is not
  /// built yet, so the list steps towards it a screen at a time until it is.
  Future<void> _scrollTo(String id) async {
    final String? target = _resolve(id);
    if (target == null) return;
    final bool reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    for (int step = 0; step < 40 && mounted; step++) {
      if (!_controller.hasClients) return;
      final ScrollPosition position = _controller.position;
      final RenderObject? box = _keys[target]!.currentContext?.findRenderObject();
      if (box != null && box.attached) {
        final double reveal = RenderAbstractViewport.of(box).getOffsetToReveal(box, 0).offset;
        final double offset = reveal.clamp(position.minScrollExtent, position.maxScrollExtent).toDouble();
        if (reduced) {
          position.jumpTo(offset);
        } else {
          await position.animateTo(offset, duration: AppMotion.slow, curve: AppMotion.standard);
        }
        return;
      }
      final double next = (position.pixels + (_isBelow(target) ? 1 : -1) * position.viewportDimension)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if (next == position.pixels) return;
      position.jumpTo(next);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  bool _isBelow(String target) {
    int? lastBuilt;
    for (int i = 0; i < _order.length; i++) {
      if (_keys[_order[i]]!.currentContext != null) lastBuilt = i;
    }
    return lastBuilt == null || _order.indexOf(target) > lastBuilt;
  }

  void _drill(InsightDrill drill) => openInsightDrill(context, drill, onSection: (String s) => widget.jump.value = s);

  @override
  Widget build(BuildContext context) {
    final InsightsProvider provider = context.watch<InsightsProvider>();
    final String currency = context.watch<SettingsProvider>().currency;
    final InsightsOverview? overview = provider.overview;
    if (overview == null) {
      _order = const <String>[];
      return const SizedBox.shrink();
    }
    final AnalyticsView? analytics = provider.analytics;
    final bool busy = provider.analyticsBusy;
    _longViewPending = analytics == null;
    _order = <String>[
      'changes',
      'recurring',
      'savings',
      'unusual',
      'patterns',
      if (analytics != null) ...<String>['trends', 'cashflow', if (overview.showCards) 'cards'],
    ];
    if (_pending != null) _schedule();

    Widget section(String id, Widget child) => KeyedSubtree(
          key: _keys[id],
          child: Padding(padding: const EdgeInsets.only(top: AppSpacing.section), child: child),
        );

    // The long view dims while a new span is computed; the last one stays.
    Widget dim(Widget child) =>
        AnimatedOpacity(opacity: busy ? 0.85 : 1, duration: AppMotion.fast, child: child);

    return ListView(
      controller: _controller,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.md,
        AppSpacing.page,
        AppSpacing.bottomListPaddingNoFab,
      ),
      children: <Widget>[
        _JumpBar(showCards: overview.showCards, onJump: _scrollTo),
        section('changes', _ChangesSection(changes: overview.changes, currency: currency)),
        section(
          'recurring',
          _RecurringSection(
            overview: overview,
            currency: currency,
            showStopped: _open.contains('stopped'),
            onToggleStopped: () => _toggle('stopped'),
          ),
        ),
        section(
          'savings',
          _SavingsSection(
            savings: overview.savings,
            currency: currency,
            expanded: _open.contains('savings'),
            onToggle: () => _toggle('savings'),
            onDrill: _drill,
          ),
        ),
        section('unusual', _UnusualSection(unusual: overview.unusual)),
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.section + AppSpacing.sm),
          child: _SpanBar(span: provider.span, onSpan: (int span) => provider.setSpan(span)),
        ),
        if (analytics == null)
          section('patterns', const _LongViewSkeleton())
        else ...<Widget>[
          section('patterns', dim(_PatternsSection(analytics: analytics, currency: currency))),
          section(
            'trends',
            dim(
              _TrendsSection(
                analytics: analytics,
                span: provider.span,
                currency: currency,
                open: _open,
                onToggle: _toggle,
              ),
            ),
          ),
          section('cashflow', dim(_CashflowSection(analytics: analytics, currency: currency))),
          if (overview.showCards) section('cards', dim(_CardsSection(analytics: analytics, currency: currency))),
        ],
      ],
    );
  }
}

/// [children] with [gap] between each — a stack with a gap.
List<Widget> _spaced(double gap, List<Widget> children) => <Widget>[
      for (int i = 0; i < children.length; i++) ...<Widget>[
        if (i != 0) SizedBox(height: gap),
        children[i],
      ],
    ];

/// A card's content, top to bottom with a gap.
class _Stack extends StatelessWidget {
  const _Stack({required this.gap, required this.children});

  final double gap;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: _spaced(gap, children),
    );
  }
}

/// The quiet line under a section's title. Set below it, as on the web,
/// so a long caption wraps instead of crowding the title.
class _Caption extends StatelessWidget {
  const _Caption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Text(text, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

/// A ghost "See …" button, left-aligned.
class _SeeButton extends StatelessWidget {
  const _SeeButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: AppButton(
        label: label,
        icon: Icons.arrow_forward_rounded,
        variant: AppButtonVariant.ghost,
        size: AppButtonSize.small,
        onPressed: onPressed,
      ),
    );
  }
}

/// A row of a list card whose subtitle wraps — the web's rows do on a phone.
class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.titleTrailing,
    this.trailing,
    this.chevron = false,
  });

  final Widget leading;
  final String title;
  final Widget? titleTrailing;
  final String subtitle;
  final Widget? trailing;
  final bool chevron;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSpacing.minTouch),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.rowPadY),
          child: Row(
            children: <Widget>[
              leading,
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            title,
                            style: theme.textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (titleTrailing != null) ...<Widget>[
                          const SizedBox(width: AppSpacing.xs),
                          titleTrailing!,
                        ],
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(subtitle, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              if (trailing != null) ...<Widget>[
                const SizedBox(width: AppSpacing.sm),
                trailing!,
              ],
              if (chevron) ...<Widget>[
                const SizedBox(width: AppSpacing.xs),
                Icon(Icons.chevron_right_rounded, size: AppSpacing.iconMd, color: theme.colorScheme.onSurfaceVariant),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _JumpBar extends StatelessWidget {
  const _JumpBar({required this.showCards, required this.onJump});

  final bool showCards;
  final ValueChanged<String> onJump;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Analytics sections',
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            for (final ({String id, String label}) s in reportSections)
              if (s.id != 'cards' || showCards)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: AppChoiceChip(label: s.label, selected: false, onSelected: () => onJump(s.id)),
                ),
          ],
        ),
      ),
    );
  }
}

class _ChangesSection extends StatelessWidget {
  const _ChangesSection({required this.changes, required this.currency});

  final ChangesView changes;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<ChangeMover> movers = changes.movers;
    final double largest = movers.fold<double>(1, (double m, ChangeMover d) => math.max(m, d.delta.abs()));
    return ReportSection(
      title: 'What changed',
      children: <Widget>[
        _Caption('${changes.current.label} vs ${changes.previous.short}'),
        SurfaceCard(
          child: _Stack(
            gap: AppSpacing.md,
            children: <Widget>[
              Text(
                changes.compared
                    ? changes.headline
                    : 'Not enough history yet to compare ${changes.current.short} with ${changes.previous.short}.',
                style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
              ),
              if (changes.compared && changes.reasons.isNotEmpty)
                SentenceList(lines: changes.reasons, icon: Icons.info_outline_rounded),
              if (changes.compared && movers.isNotEmpty)
                RankedRows(
                  items: <RankedItem>[
                    for (final ChangeMover d in movers)
                      RankedItem(
                        key: d.key,
                        label: d.label,
                        total: d.delta.abs(),
                        count: d.currentCount,
                        share: d.delta.abs() / largest,
                        tone: d.delta > 0 ? ToneColors.expense(context) : ToneColors.income(context),
                        detail: '${d.delta > 0 ? 'Up' : 'Down'} · ${d.reason}',
                      ),
                  ],
                  currency: currency,
                  onOpen: (RankedItem item) {
                    for (final ChangeMover d in movers) {
                      if (d.key == item.key) {
                        showInsightRows(context, title: d.label, subtitle: changes.current.short, ids: d.ids);
                        return;
                      }
                    }
                  },
                ),
              if (changes.currentCount > 0)
                _SeeButton(
                  label: 'See ${plural(changes.currentCount, 'expense', 'expenses')} in ${changes.current.short}',
                  onPressed: () => showInsightRows(
                    context,
                    title: 'Spending',
                    subtitle: changes.current.short,
                    ids: changes.ids,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RecurringSection extends StatelessWidget {
  const _RecurringSection({
    required this.overview,
    required this.currency,
    required this.showStopped,
    required this.onToggleStopped,
  });

  final InsightsOverview overview;
  final String currency;
  final bool showStopped;
  final VoidCallback onToggleStopped;

  @override
  Widget build(BuildContext context) {
    final List<RecurringItem> running = overview.running;
    final List<RecurringItem> stopped = overview.recurring.where((RecurringItem r) => !r.active).toList();
    final DateTime today = DateUtils.dateOnly(DateTime.now());
    return ReportSection(
      title: 'Recurring payments',
      children: <Widget>[
        const _Caption('Subscriptions, bills, EMIs and renewals found in your history'),
        if (running.isNotEmpty) ...<Widget>[
          SurfaceCard(
            child: FigureRow(
              figures: <ReportFigure>[
                ReportFigure('Running', '${overview.runningCount}'),
                ReportFigure('A month (estimate)', shortMoney(overview.recurringMonthly, currency)),
                ReportFigure('A year (estimate)', shortMoney(overview.recurringMonthly * 12, currency)),
              ],
            ),
          ),
          CardList(
            children: <Widget>[
              for (final RecurringItem series in running) _RecurringRow(series: series, currency: currency, today: today),
            ],
          ),
        ] else
          const SurfaceCard(
            child: EmptyState(
              compact: true,
              icon: Icons.calendar_month_outlined,
              title: 'No recurring payments found yet',
              message: 'A payment is listed once it repeats at a steady rhythm — for a subscription, three months '
                  'in a row with the same merchant and amount.',
            ),
          ),
        if (stopped.isNotEmpty) ...<Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              label: showStopped ? 'Hide payments not seen recently' : 'Not seen recently (${stopped.length})',
              variant: AppButtonVariant.ghost,
              size: AppButtonSize.small,
              onPressed: onToggleStopped,
            ),
          ),
          if (showStopped)
            CardList(
              children: <Widget>[
                for (final RecurringItem series in stopped) _RecurringRow(series: series, currency: currency, today: today),
              ],
            ),
        ],
      ],
    );
  }
}

class _RecurringRow extends StatelessWidget {
  const _RecurringRow({required this.series, required this.currency, required this.today});

  final RecurringItem series;
  final String currency;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String when = !series.active
        ? 'last paid ${Formatters.dayMonth(series.lastDate)}'
        : series.nextDate.isBefore(today)
            ? 'due now'
            : 'next ~${Formatters.dayMonth(series.nextDate)}';
    final String unit = series.streak == 1 ? series.unitOne : series.unitMany;
    return Semantics(
      label: '${series.label}, ${series.cadenceLabel.toLowerCase()}',
      child: _ListRow(
        leading: IconWell(
          icon: _kindIcon(series.kind),
          tone: series.active ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
        ),
        title: series.label,
        titleTrailing: series.trend == 'up'
            ? Icon(Icons.arrow_upward_rounded, size: 14, color: ToneColors.warning(context))
            : null,
        subtitle: '${series.cadenceLabel} · ${series.streak} $unit in a row · $when',
        trailing: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              MoneyText(series.amount, currency: currency, fit: true),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                '~${shortMoney(series.yearlyCost, currency)}/yr',
                style: theme.textTheme.labelSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        onTap: () => showRecurringSheet(context, series),
      ),
    );
  }
}

class _SavingsSection extends StatelessWidget {
  const _SavingsSection({
    required this.savings,
    required this.currency,
    required this.expanded,
    required this.onToggle,
    required this.onDrill,
  });

  final List<SavingIdea> savings;
  final String currency;
  final bool expanded;
  final VoidCallback onToggle;
  final ValueChanged<InsightDrill> onDrill;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<SavingIdea> shown =
        expanded || savings.length <= _savingsLimit ? savings : savings.sublist(0, _savingsLimit);
    return ReportSection(
      title: 'Savings opportunities',
      children: <Widget>[
        const _Caption('Optional ideas from your own spending — estimates, and some may overlap'),
        if (shown.isEmpty)
          const SurfaceCard(
            child: EmptyState(
              compact: true,
              icon: Icons.account_balance_wallet_outlined,
              title: 'Nothing stands out right now',
              message: 'No subscription, habit or category is costing noticeably more than usual.',
            ),
          )
        else ...<Widget>[
          for (final SavingIdea item in shown)
            SurfaceCard(
              child: _Stack(
                gap: AppSpacing.sm,
                children: <Widget>[
                  Text(item.title, style: theme.textTheme.titleMedium),
                  for (final String line in item.evidence) Text(line, style: theme.textTheme.bodySmall),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(Icons.lightbulb_outline_rounded, size: 15, color: theme.colorScheme.secondary),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(child: Text(item.suggestion, style: theme.textTheme.bodyMedium)),
                    ],
                  ),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: <Widget>[
                      SavingPill(saving: item.saving, currency: currency),
                      if (item.drill != null)
                        AppButton(
                          label: 'Details',
                          icon: Icons.arrow_forward_rounded,
                          variant: AppButtonVariant.ghost,
                          size: AppButtonSize.small,
                          onPressed: () => onDrill(item.drill!),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          MoreToggle(
            shown: _savingsLimit,
            total: savings.length,
            expanded: expanded,
            onToggle: onToggle,
            noun: 'ideas',
          ),
        ],
      ],
    );
  }
}

class _UnusualSection extends StatelessWidget {
  const _UnusualSection({required this.unusual});

  final List<UnusualItem> unusual;

  @override
  Widget build(BuildContext context) {
    return ReportSection(
      title: 'Worth a second look',
      children: <Widget>[
        const _Caption('Last 45 days'),
        if (unusual.isEmpty)
          const SurfaceCard(
            child: EmptyState(
              compact: true,
              icon: Icons.check_circle_outline_rounded,
              title: 'Nothing unusual',
              message: 'No outsized expense or repeated charge in the last 45 days.',
            ),
          )
        else
          CardList(
            children: <Widget>[
              for (final UnusualItem item in unusual)
                _ListRow(
                  leading: IconWell(
                    icon: item.isLarge ? Icons.arrow_upward_rounded : Icons.content_copy_rounded,
                    tone: item.isLarge ? Theme.of(context).colorScheme.secondary : ToneColors.expense(context),
                  ),
                  title: item.isLarge ? 'Unusually large' : 'Possible duplicate',
                  subtitle: item.explanation,
                  chevron: true,
                  onTap: () => showInsightRows(
                    context,
                    title: item.isLarge ? 'Unusually large' : 'Possible duplicate',
                    ids: item.ids,
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _SpanBar extends StatelessWidget {
  const _SpanBar({required this.span, required this.onSpan});

  final int span;
  final ValueChanged<int> onSpan;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Text('The long view', style: Theme.of(context).textTheme.labelMedium),
        ),
        const SizedBox(height: AppSpacing.sm),
        Semantics(
          label: 'Analysis range',
          child: SegmentedButton<int>(
            segments: <ButtonSegment<int>>[
              for (final ({int value, String label}) s in _spans)
                ButtonSegment<int>(value: s.value, label: Text(s.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
            selected: <int>{span},
            showSelectedIcon: false,
            onSelectionChanged: (Set<int> value) => onSpan(value.first),
          ),
        ),
      ],
    );
  }
}

/// Stands in for the long view until its first analysis arrives.
class _LongViewSkeleton extends StatelessWidget {
  const _LongViewSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _spaced(AppSpacing.cardGap, <Widget>[
        for (int i = 0; i < 3; i++)
          const SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Skeleton(height: 16, width: 140),
                SizedBox(height: AppSpacing.md),
                Skeleton(height: 12),
                SizedBox(height: AppSpacing.sm),
                Skeleton(height: 12, width: 200),
                SizedBox(height: AppSpacing.lg),
                Skeleton(height: 90),
              ],
            ),
          ),
      ]),
    );
  }
}

class _PatternsSection extends StatelessWidget {
  const _PatternsSection({required this.analytics, required this.currency});

  final AnalyticsView analytics;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final AnalyticsView a = analytics;
    final ChartColors palette = ChartColors.of(context);
    final ({double weekdayPerDay, double weekendPerDay})? week = a.week;
    final ({double typical, int largeCount, List<String> largeIds})? size = a.size;
    return ReportSection(
      title: 'Spending patterns',
      children: <Widget>[
        _Caption(a.range.label),
        SurfaceCard(
          child: a.patternCount < 10
              ? const EmptyState(
                  compact: true,
                  icon: Icons.insights_outlined,
                  title: 'Not enough to see a pattern',
                  message: 'Patterns appear once there are a few weeks of expenses in this range.',
                )
              : _Stack(
                  gap: AppSpacing.md,
                  children: <Widget>[
                    if (a.patternSentences.isNotEmpty) SentenceList(lines: a.patternSentences),
                    if (a.classifiedShare >= 0.5)
                      _NecessityBar(necessity: a.necessity, label: a.range.short, currency: currency)
                    else
                      const AppNotice(
                        message: 'Essential and discretionary spending need recognisable categories (for example '
                            'Bills, Health, Shopping, Entertainment); most of this range could not be classified.',
                      ),
                    if (week != null)
                      Column(
                        children: _spaced(AppSpacing.sm, <Widget>[
                          _CompareBar(
                            label: 'A weekday',
                            value: week.weekdayPerDay,
                            max: math.max(week.weekdayPerDay, week.weekendPerDay),
                            currency: currency,
                            tone: palette.segments[1],
                          ),
                          _CompareBar(
                            label: 'A weekend day',
                            value: week.weekendPerDay,
                            max: math.max(week.weekdayPerDay, week.weekendPerDay),
                            currency: currency,
                            tone: palette.segments[0],
                          ),
                        ]),
                      ),
                    FigureRow(
                      figures: <ReportFigure>[
                        if (size != null) ReportFigure('Typical purchase', shortMoney(size.typical, currency)),
                        ReportFigure('Top 3 categories', Formatters.percent(a.topCategoriesShare)),
                        ReportFigure('Recurring share', Formatters.percent(a.recurringShare)),
                      ],
                    ),
                    if (size != null)
                      _SeeButton(
                        label: 'See the ${size.largeCount} largest purchases',
                        onPressed: () => showInsightRows(
                          context,
                          title: 'Largest purchases',
                          subtitle: a.range.short,
                          ids: size.largeIds,
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Essential, discretionary and unclassified spending as one stacked bar,
/// with a legend row for each that opens its expenses.
class _NecessityBar extends StatelessWidget {
  const _NecessityBar({required this.necessity, required this.label, required this.currency});

  final List<({String key, String name, double total, double share, List<String> ids})> necessity;
  final String label;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ChartColors palette = ChartColors.of(context);
    Color toneOf(String key) => switch (key) {
          'essential' => palette.segments[1],
          'discretionary' => palette.segments[0],
          _ => palette.idle,
        };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Semantics(
          label: necessity.map((p) => '${p.name} ${Formatters.percent(p.share)}').join(', '),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
            child: Container(
              height: 12,
              color: ToneColors.wash(context, theme.colorScheme.onSurfaceVariant),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int i = 0; i < necessity.length; i++) ...<Widget>[
                    if (i != 0) const SizedBox(width: 2),
                    Expanded(
                      // A sliver of a share still shows as a sliver.
                      flex: math.max(15, (necessity[i].share * 1000).round()),
                      child: ColoredBox(color: toneOf(necessity[i].key)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        for (final ({String key, String name, double total, double share, List<String> ids}) p in necessity)
          InkWell(
            onTap: () => showInsightRows(context, title: p.name, subtitle: label, ids: p.ids),
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(color: toneOf(p.key), shape: BoxShape.circle),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(p.name, style: theme.textTheme.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(Formatters.percent(p.share), style: theme.textTheme.labelSmall),
                  const SizedBox(width: AppSpacing.sm),
                  MoneyText(p.total, currency: currency, compact: true, style: theme.textTheme.titleSmall),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _CompareBar extends StatelessWidget {
  const _CompareBar({
    required this.label,
    required this.value,
    required this.max,
    required this.currency,
    required this.tone,
  });

  final String label;
  final double value;
  final double max;
  final String currency;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle labelStyle = theme.textTheme.labelSmall!;
    final TextStyle valueStyle = AppTypography.money(theme.textTheme.titleSmall);
    final String figure = '${shortMoney(value, currency)}/day';
    final Widget bar = ShareBar(ratio: max > 0 ? value / max : 0, tone: tone);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        double widthOf(String text, TextStyle style) {
          final TextPainter painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final double width = painter.width;
          painter.dispose();
          return width;
        }

        final double valueWidth = math.max(72, widthOf(figure, valueStyle));
        // Label, bar and figure on one line, as on the web — unless the
        // words leave the bar no room, when the bar drops beneath them.
        final bool oneLine =
            widthOf(label, labelStyle) + valueWidth + AppSpacing.md * 2 + 48 <= constraints.maxWidth;
        final Widget value = Text(figure, textAlign: TextAlign.right, style: valueStyle, maxLines: 1);
        if (oneLine) {
          return Row(
            children: <Widget>[
              Text(label, style: labelStyle, maxLines: 1),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: bar),
              const SizedBox(width: AppSpacing.md),
              SizedBox(width: valueWidth, child: value),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: Text(label, style: labelStyle, maxLines: 1, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: AppSpacing.sm),
                Flexible(child: value),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            bar,
          ],
        );
      },
    );
  }
}

/// The months as chart points; a long span labels every other month, so the
/// labels never run into each other on a phone.
List<MonthlyPoint> _points(AnalyticsView a) => <MonthlyPoint>[
      for (final ({DateTime month, double spent, double income, bool partial}) m in a.months)
        MonthlyPoint(month: m.month, expense: m.spent, income: m.income),
    ];

String Function(int index)? _sparseLabels(List<MonthlyPoint> points) {
  if (points.length <= 8) return null;
  final int last = points.length - 1;
  return (int index) => (last - index).isEven ? Formatters.shortMonth(points[index].month) : '';
}

class _TrendsSection extends StatelessWidget {
  const _TrendsSection({
    required this.analytics,
    required this.span,
    required this.currency,
    required this.open,
    required this.onToggle,
  });

  final AnalyticsView analytics;
  final int span;
  final String currency;
  final Set<String> open;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AnalyticsView a = analytics;
    final List<MonthlyPoint> points = _points(a);
    final String subtitle = 'Last $span months';
    return ReportSection(
      title: 'Trends',
      children: <Widget>[
        const _Caption('Complete months, with this month so far shown last'),
        SurfaceCard(
          child: _Stack(
            gap: AppSpacing.md,
            children: <Widget>[
              Wrap(
                spacing: AppSpacing.md,
                runSpacing: AppSpacing.sm,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: <Widget>[
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text('AVERAGE MONTH', style: AppTypography.eyebrow(theme.textTheme)),
                      const SizedBox(height: AppSpacing.xxs),
                      MoneyText(
                        a.averageSpent.roundToDouble(),
                        currency: currency,
                        style: theme.textTheme.displayMedium,
                        fit: true,
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    child: DeltaText(change: a.change, label: 'vs the $span months before'),
                  ),
                ],
              ),
              MonthlyTrendChart(points: points, currency: currency, height: 170, labelOf: _sparseLabels(points)),
              if (a.averages.length > 1)
                FigureRow(
                  figures: <ReportFigure>[
                    for (final ({int span, double average}) avg in a.averages)
                      ReportFigure('${avg.span}-month average', shortMoney(avg.average, currency)),
                  ],
                ),
              if (a.trendSentences.isNotEmpty) SentenceList(lines: a.trendSentences),
            ],
          ),
        ),
        if (a.categoryTrends.isNotEmpty)
          _TrendList(
            title: 'Category trends',
            noun: 'categories',
            subtitle: subtitle,
            trends: a.categoryTrends,
            currency: currency,
            expanded: open.contains('categoryTrends'),
            onToggle: () => onToggle('categoryTrends'),
          ),
        if (a.tagTrends.isNotEmpty)
          _TrendList(
            title: 'Tag trends',
            noun: 'tags',
            subtitle: subtitle,
            trends: a.tagTrends,
            currency: currency,
            expanded: open.contains('tagTrends'),
            onToggle: () => onToggle('tagTrends'),
          ),
      ],
    );
  }
}

class _TrendList extends StatelessWidget {
  const _TrendList({
    required this.title,
    required this.noun,
    required this.subtitle,
    required this.trends,
    required this.currency,
    required this.expanded,
    required this.onToggle,
  });

  final String title;

  /// What the rows are, for "Show all 9 categories".
  final String noun;
  final String subtitle;
  final List<TrendLine> trends;
  final String currency;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<TrendLine> shown = expanded || trends.length <= _trendLimit ? trends : trends.sublist(0, _trendLimit);
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xxs),
                Text('Average a month · $subtitle', style: theme.textTheme.labelSmall),
              ],
            ),
          ),
          for (int i = 0; i < shown.length; i++) ...<Widget>[
            if (i != 0) const Divider(height: 1, indent: AppSpacing.lg, endIndent: AppSpacing.lg),
            _TrendRow(
              trend: shown[i],
              currency: currency,
              onTap: () => showInsightRows(context, title: shown[i].label, subtitle: subtitle, ids: shown[i].ids),
            ),
          ],
          if (trends.length > _trendLimit || expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.sm, 0, AppSpacing.sm, AppSpacing.sm),
              child: MoreToggle(
                shown: _trendLimit,
                total: trends.length,
                expanded: expanded,
                onToggle: onToggle,
                noun: noun,
              ),
            )
          else
            const SizedBox(height: AppSpacing.xs),
        ],
      ),
    );
  }
}

class _TrendRow extends StatelessWidget {
  const _TrendRow({required this.trend, required this.currency, required this.onTap});

  final TrendLine trend;
  final String currency;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double? previous = trend.previousAverage;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(trend.label, style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                    '${shortMoney(trend.average, currency)}/mo'
                    '${previous != null ? ' · was ${shortMoney(previous, currency)}' : ''}',
                    style: theme.textTheme.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            SparkLine(values: trend.months, color: hexColor(trend.color) ?? theme.colorScheme.primary),
            const SizedBox(width: AppSpacing.md),
            // A fixed column, so the sparks line up row under row.
            SizedBox(
              width: 64,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: trend.change != null
                    ? DeltaText(change: trend.change)
                    : Text('—', style: theme.textTheme.labelSmall),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CashflowSection extends StatelessWidget {
  const _CashflowSection({required this.analytics, required this.currency});

  final AnalyticsView analytics;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ChartColors palette = ChartColors.of(context);
    final ({double income, double spent, double saved, double? rate, int overspentMonths}) flow = analytics.cashflow;
    final double? rate = flow.rate;
    final List<MonthlyPoint> points = _points(analytics);
    final Color income = ToneColors.income(context);
    final Color expense = ToneColors.expense(context);
    return ReportSection(
      title: 'Cash flow',
      children: <Widget>[
        const _Caption('Income recorded against spending'),
        SurfaceCard(
          child: rate == null
              ? const EmptyState(
                  compact: true,
                  icon: Icons.south_west_rounded,
                  title: 'No income recorded',
                  message: 'Record income to see how much of it you keep each month.',
                )
              : _Stack(
                  gap: AppSpacing.md,
                  children: <Widget>[
                    FigureRow(
                      figures: <ReportFigure>[
                        ReportFigure('Income', shortMoney(flow.income, currency), tone: income),
                        ReportFigure('Spent', shortMoney(flow.spent, currency), tone: expense),
                        ReportFigure(
                          flow.saved >= 0 ? 'Kept' : 'Overspent',
                          Formatters.percent(rate.abs()),
                          tone: flow.saved >= 0 ? income : expense,
                        ),
                      ],
                    ),
                    MonthlyTrendChart(
                      points: points,
                      currency: currency,
                      showIncome: true,
                      height: 170,
                      labelOf: _sparseLabels(points),
                    ),
                    ChartLegend(
                      entries: <({String label, Color color})>[
                        (label: 'Spending', color: palette.expense),
                        (label: 'Income', color: palette.income),
                      ],
                    ),
                    if (analytics.cashflowSentences.isNotEmpty) SentenceList(lines: analytics.cashflowSentences),
                    if (flow.overspentMonths > 0)
                      Text(
                        'Spending was above income in ${flow.overspentMonths} of these '
                        '${flow.overspentMonths == 1 ? 'month' : 'months'}.',
                        style: theme.textTheme.bodySmall,
                      ),
                    Text(
                      'Complete months with income recorded. Transfers, loans and card bill payments are neither '
                      'income nor spending.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _CardsSection extends StatelessWidget {
  const _CardsSection({required this.analytics, required this.currency});

  final AnalyticsView analytics;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AnalyticsView a = analytics;
    final double? share = a.cardShare;
    final int purchases = a.cardPurchaseIds.length;
    return ReportSection(
      title: 'Credit cards',
      children: <Widget>[
        const _Caption('Use of each limit today'),
        SurfaceCard(
          child: _Stack(
            gap: AppSpacing.md,
            children: <Widget>[
              if (a.cardUses.isNotEmpty)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final ({String id, String name, double utilisation}) card in a.cardUses) ...<Widget>[
                      _CardUseRow(name: card.name, utilisation: card.utilisation),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    Text(
                      'Using under about 30% of a limit is generally better for a credit score.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              FigureRow(
                figures: <ReportFigure>[
                  ReportFigure(
                    'Card spending',
                    share != null ? Formatters.percent(share) : '—',
                    tone: ToneColors.expense(context),
                  ),
                  ReportFigure('Fees & interest, 12 mo', shortMoney(a.cardCharged, currency)),
                  ReportFigure(
                    'Refunds & cashback, 12 mo',
                    shortMoney(a.cardBack, currency),
                    tone: ToneColors.income(context),
                  ),
                ],
              ),
              if (purchases > 0)
                _SeeButton(
                  label: 'See ${plural(purchases, 'card purchase', 'card purchases')}',
                  onPressed: () => showInsightRows(
                    context,
                    title: 'Card purchases',
                    subtitle: a.range.short,
                    ids: a.cardPurchaseIds,
                  ),
                ),
              Text(
                'Refunds and cashback are shown here and are not taken off spending — the same as everywhere '
                'else in the app.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CardUseRow extends StatelessWidget {
  const _CardUseRow({required this.name, required this.utilisation});

  final String name;
  final double utilisation;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color tone = utilisation >= 0.75
        ? ToneColors.expense(context)
        : utilisation >= 0.3
            ? ToneColors.warning(context)
            : ToneColors.income(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) => Row(
        children: <Widget>[
          SizedBox(
            width: math.min(constraints.maxWidth * 0.4, 200),
            child: Text(name, style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(child: ShareBar(ratio: math.min(utilisation, 1), tone: tone)),
          const SizedBox(width: AppSpacing.md),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 44),
            child: Text(
              Formatters.percent(utilisation),
              textAlign: TextAlign.right,
              style: AppTypography.money(theme.textTheme.titleSmall),
            ),
          ),
        ],
      ),
    );
  }
}
