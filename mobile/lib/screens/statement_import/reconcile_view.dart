import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../providers/reconciliation_provider.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import 'reconcile_item_sheet.dart';

/// The colour of each of the dashboard's five groups — the web app's
/// ✅ 🔴 🟠 🟡 🔵, shown with the same marks.
Color reconTone(BuildContext context, String status) {
  final bool dark = Theme.of(context).brightness == Brightness.dark;
  switch (status) {
    case 'matched':
      return ToneColors.income(context);
    case 'missing':
      return Theme.of(context).colorScheme.error;
    case 'duplicate':
      return dark ? const Color(0xFFFB923C) : const Color(0xFFEA580C);
    case 'mismatch':
      return dark ? const Color(0xFFFACC15) : const Color(0xFFB7791F);
    default:
      return dark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);
  }
}

IconData reconIcon(String status) => switch (status) {
      'matched' => Icons.check_circle_outline_rounded,
      'missing' => Icons.error_outline_rounded,
      'duplicate' => Icons.copy_rounded,
      'mismatch' => Icons.warning_amber_rounded,
      _ => Icons.help_outline_rounded,
    };

/// The reconciliation dashboard: does this statement agree with the app?
/// Balances first, then every discrepancy, each opening beside what it was
/// compared to. Nothing here changes a transaction — resolving is linking,
/// "not the same", accepting as is, or opening the transaction to fix it.
class ReconcileView extends StatefulWidget {
  const ReconcileView({
    super.key,
    required this.currency,
    required this.onAddToApp,
    required this.onOpen,
    required this.onRefresh,
    this.header = const <Widget>[],
  });

  final String currency;

  /// Shown above the dashboard, in the same scroll: the statements read.
  final List<Widget> header;

  /// Opens the statement row in the import review, to add it (or to choose
  /// its account). Null when rows cannot be imported from here (a card's).
  final void Function(String itemId)? onAddToApp;

  /// Opens a recorded transaction — {type, id, accountId?, cardId?, date}.
  final Future<void> Function(Map<String, Object?> target) onOpen;

  /// Reads the recorded transactions again.
  final Future<void> Function() onRefresh;

  @override
  State<ReconcileView> createState() => _ReconcileViewState();
}

class _ReconcileViewState extends State<ReconcileView> {
  static const int _page = 150;

  ReconFilter _filter = const ReconFilter();
  int _shown = _page;

  void _setFilter(ReconFilter filter) => setState(() {
        _filter = filter;
        _shown = _page;
      });

  @override
  Widget build(BuildContext context) {
    final ReconciliationProvider recon = context.watch<ReconciliationProvider>();
    if (recon.isInitialLoad || (!recon.computed && !recon.hasError)) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.md, AppSpacing.page, AppSpacing.xxxl),
        children: <Widget>[...widget.header, const ListSkeleton(rows: 5)],
      );
    }
    if (recon.hasError && !recon.computed) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.md, AppSpacing.page, AppSpacing.xxxl),
        children: <Widget>[
          ...widget.header,
          ErrorView(
            message: recon.errorMessage ?? 'Could not read your recorded transactions to compare.',
            onRetry: widget.onRefresh,
          ),
        ],
      );
    }
    final ThemeData theme = Theme.of(context);
    final List<ReconItem> visible = recon.filtered(_filter);
    final int open = recon.count('open');
    final int matched = recon.count('matched');
    final int resolved = recon.count('resolved');
    final List<Widget> children = <Widget>[
      ...widget.header,
      SurfaceCard(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              open > 0
                  ? '$open ${open == 1 ? 'discrepancy' : 'discrepancies'} to resolve'
                  : recon.count('total') > 0
                      ? 'The statement and the app agree'
                      : 'Nothing to compare',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '$matched matched${resolved > 0 ? ' · $resolved accepted' : ''} · '
              'compared with every transaction recorded on the same '
              '${recon.scopes.length == 1 ? (recon.scopes.first.isCard ? 'card' : 'account') : 'accounts and cards'} '
              'for the same days.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.md),
      _Tiles(
        recon: recon,
        selected: _filter.status,
        onTap: (String status) =>
            _setFilter(_filter.copyWith(status: _filter.status == status ? 'open' : status)),
      ),
      if (!recon.persistent) ...<Widget>[
        const SizedBox(height: AppSpacing.md),
        const AppNotice(
          message: 'Your answers here are kept until you leave this screen. '
              'Run migration 015 to keep them, on every device.',
        ),
      ],
      for (final ReconScope scope in recon.scopes) ...<Widget>[
        const SizedBox(height: AppSpacing.md),
        _BalanceCard(scope: scope, recon: recon, currency: widget.currency),
      ],
      const SizedBox(height: AppSpacing.md),
      _FilterBar(recon: recon, filter: _filter, onChanged: _setFilter),
      const SizedBox(height: AppSpacing.sm),
    ];

    if (visible.isEmpty) {
      final bool cleared = _filter.status == 'open' && !_filter.narrowed;
      children.add(Padding(
        padding: const EdgeInsets.only(top: AppSpacing.lg),
        child: EmptyState(
          compact: true,
          icon: cleared ? Icons.check_circle_outline_rounded : Icons.filter_list_off_rounded,
          title: cleared ? 'Nothing left to resolve' : 'Nothing here',
          message: cleared
              ? 'Every row on the statement agrees with the app, or you have accepted it.'
              : 'No transactions match these filters.',
        ),
      ));
    } else {
      int budget = _shown;
      for (final String status in recon.statusOrder) {
        final List<ReconItem> group = visible.where((ReconItem i) => i.status == status).toList();
        if (group.isEmpty || budget <= 0) continue;
        final List<ReconItem> page = group.take(budget).toList();
        budget -= page.length;
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.lg, 0, AppSpacing.sm),
          child: Row(
            children: <Widget>[
              Text(recon.statusMark(status)),
              const SizedBox(width: AppSpacing.sm),
              Text(recon.statusLabel(status), style: theme.textTheme.titleSmall),
              const SizedBox(width: AppSpacing.sm),
              Text('${group.length}', style: theme.textTheme.bodySmall),
            ],
          ),
        ));
        children.add(CardList(
          children: page
              .map((ReconItem item) => _ItemRow(
                    item: item,
                    currency: widget.currency,
                    scopeLabel: recon.scopes.length > 1 ? _scopeLabel(recon, item.scope) : null,
                    onTap: () => _open(item),
                  ))
              .toList(),
        ));
      }
      if (visible.length > _shown) {
        children.addAll(<Widget>[
          const SizedBox(height: AppSpacing.md),
          AppButton(
            label: 'Show ${visible.length - _shown < _page ? visible.length - _shown : _page} more',
            variant: AppButtonVariant.secondary,
            onPressed: () => setState(() => _shown += _page),
          ),
        ]);
      }
    }

    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.md, AppSpacing.page, AppSpacing.xxxl),
        children: children,
      ),
    );
  }

  static String? _scopeLabel(ReconciliationProvider recon, String scope) {
    for (final ReconScope s in recon.scopes) {
      if (s.key == scope) return s.label;
    }
    return null;
  }

  Future<void> _open(ReconItem item) async {
    final ReconciliationProvider recon = context.read<ReconciliationProvider>();
    final ReconSheetResult? result = await showAppSheet<ReconSheetResult>(
      context: context,
      builder: (_) => ChangeNotifierProvider<ReconciliationProvider>.value(
        value: recon,
        child: ReconcileItemSheet(
          item: item,
          currency: widget.currency,
          canAdd: widget.onAddToApp != null && !item.scope.startsWith('card:'),
        ),
      ),
    );
    if (!mounted || result == null) return;
    switch (result.action) {
      case 'add':
        final String? itemId = item.line?['itemId'] as String?;
        if (itemId != null) widget.onAddToApp?.call(itemId);
      case 'open':
        if (result.target != null) await widget.onOpen(result.target!);
      case 'failed':
        AppFeedback.error(context, recon.errorMessage ?? 'That could not be saved.');
    }
  }
}

class _Tiles extends StatelessWidget {
  const _Tiles({required this.recon, required this.selected, required this.onTap});

  final ReconciliationProvider recon;
  final String? selected;
  final void Function(String status) onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return LayoutBuilder(builder: (BuildContext context, BoxConstraints box) {
      final double width = (box.maxWidth - AppSpacing.sm * 2) / 3;
      return Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: recon.tileOrder.map((String status) {
          final Color tone = reconTone(context, status);
          final bool on = selected == status;
          return SizedBox(
            width: width,
            child: Semantics(
              button: true,
              selected: on,
              label: '${recon.statusLabel(status)}: ${recon.count(status)}',
              child: Material(
                color: Color.alphaBlend(tone.withOpacity(on ? 0.16 : 0.07), theme.colorScheme.surface),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  side: BorderSide(color: tone.withOpacity(on ? 0.9 : 0.2), width: on ? 1.2 : 0.75),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  onTap: () => onTap(status),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '${recon.statusMark(status)} ${recon.statusLabel(status)}',
                          style: theme.textTheme.labelSmall,
                          maxLines: 2,
                        ),
                        const SizedBox(height: AppSpacing.xxs),
                        Text('${recon.count(status)}', style: theme.textTheme.titleLarge?.copyWith(color: tone)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      );
    });
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.scope, required this.recon, required this.currency});

  final ReconScope scope;
  final ReconciliationProvider recon;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool? agrees = scope.agrees;
    final Color tone = agrees == true
        ? ToneColors.income(context)
        : agrees == false
            ? theme.colorScheme.error
            : theme.colorScheme.primary;
    String money(double? v) => v == null ? '—' : Formatters.currency(v, currencyCode: currency);
    Widget diff(double? a, double? b) {
      if (a == null || b == null) return const Text('—', textAlign: TextAlign.end);
      final double d = ((a - b) * 100).round() / 100;
      return Text(
        d == 0 ? '✓' : '${d > 0 ? '+' : '−'}${Formatters.currency(d.abs(), currencyCode: currency)}',
        textAlign: TextAlign.end,
        style: TextStyle(color: d == 0 ? ToneColors.income(context) : theme.colorScheme.error, fontWeight: FontWeight.w600),
      );
    }

    final bool card = scope.isCard;
    final List<(String, double?, double?)> rows = <(String, double?, double?)>[
      (card ? 'Opening outstanding' : 'Opening', scope.statementOpening, scope.appOpening),
      (card ? 'Charges' : 'Money in', card ? scope.statementDebits : scope.statementCredits, card ? scope.appDebits : scope.appCredits),
      (card ? 'Payments' : 'Money out', card ? scope.statementCredits : scope.statementDebits, card ? scope.appCredits : scope.appDebits),
      (card ? 'Closing outstanding' : 'Closing', scope.statementClosing, scope.appClosing),
    ];
    final TextStyle? small = theme.textTheme.bodySmall;
    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconWell(
                icon: card ? Icons.credit_card_rounded : Icons.account_balance_outlined,
                tone: tone,
                size: AppSpacing.avatarSm,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(scope.label, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                    Text(
                      '${Formatters.dayMonthYear(scope.from)} – ${Formatters.dayMonthYear(scope.to)}'
                      '${scope.partial ? ' · payment app statement only' : ''}',
                      style: small,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                agrees == true
                    ? Icons.check_circle_outline_rounded
                    : agrees == false
                        ? Icons.warning_amber_rounded
                        : Icons.info_outline_rounded,
                size: 18,
                color: tone,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(scope.headline, style: theme.textTheme.titleSmall?.copyWith(color: tone))),
            ],
          ),
          if (!scope.partial) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            Table(
              columnWidths: const <int, TableColumnWidth>{0: FlexColumnWidth(1.1), 1: FlexColumnWidth(), 2: FlexColumnWidth(), 3: FlexColumnWidth()},
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: <TableRow>[
                TableRow(children: <Widget>[
                  const SizedBox.shrink(),
                  Text('Statement', style: small, textAlign: TextAlign.end),
                  Text('App', style: small, textAlign: TextAlign.end),
                  Text('Diff', style: small, textAlign: TextAlign.end),
                ]),
                for (final (String label, double? s, double? a) in rows)
                  TableRow(children: <Widget>[
                    Padding(padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs), child: Text(label, style: small)),
                    FittedBox(alignment: Alignment.centerRight, fit: BoxFit.scaleDown, child: Text(money(s))),
                    FittedBox(alignment: Alignment.centerRight, fit: BoxFit.scaleDown, child: Text(money(a))),
                    FittedBox(alignment: Alignment.centerRight, fit: BoxFit.scaleDown, child: diff(s, a)),
                  ]),
              ],
            ),
          ],
          for (final String line in scope.lines) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Text('• $line', style: small),
          ],
          if (scope.byKind.isNotEmpty)
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text('What the money was', style: theme.textTheme.labelLarge),
                children: <Widget>[
                  for (final Map<String, Object?> k in scope.byKind)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              '${recon.kindLabel(k['kind']! as String)}'
                              '${recon.countedKinds.contains(k['kind']) ? '' : ' · not spending or income'}',
                              style: small,
                            ),
                          ),
                          Text(
                            '${Formatters.currency((k['statement'] as num?) ?? 0, currencyCode: currency, compact: true)} / '
                            '${Formatters.currency((k['app'] as num?) ?? 0, currencyCode: currency, compact: true)}',
                            style: small,
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Statement / app. Only spending and income count in your reports and budgets: transfers between '
                    'your accounts, card bills, money paid for someone and their repayments move balances without being either.',
                    style: small,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Status, account, statement, type and dates.
class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.recon, required this.filter, required this.onChanged});

  final ReconciliationProvider recon;
  final ReconFilter filter;
  final void Function(ReconFilter filter) onChanged;

  Future<String?> _choose(BuildContext context, String title, List<(String?, String)> options, String? current) =>
      showAppSheet<String>(
        context: context,
        builder: (BuildContext sheet) => AppSheet(
          title: title,
          children: <Widget>[
            for (final (String? value, String label) in options)
              ListTile(
                title: Text(label),
                trailing: value == current ? const Icon(Icons.check_rounded) : null,
                onTap: () => Navigator.of(sheet).pop(value ?? ''),
              ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    String? label(List<(String?, String)> options, String? value) {
      for (final (String? v, String l) in options) {
        if (v == value) return l;
      }
      return null;
    }

    final List<(String?, String)> statuses = <(String?, String)>[
      (null, 'Everything'),
      ('open', 'To resolve'),
      for (final String s in recon.statusOrder) (s, '${recon.statusMark(s)} ${recon.statusLabel(s)}'),
      ('resolved', 'Accepted by you'),
    ];
    final List<(String?, String)> scopes = <(String?, String)>[
      (null, 'All accounts'),
      for (final ReconScope s in recon.scopes) (s.key, s.label),
    ];
    final List<(String?, String)> sources = <(String?, String)>[
      (null, 'All statements'),
      for (final MapEntry<String, String> s in recon.statementLabels.entries) (s.key, s.value),
    ];
    final List<(String?, String)> kinds = <(String?, String)>[
      (null, 'All types'),
      for (final String k in recon.kinds)
        if (recon.items.any((ReconItem i) => i.kind == k)) (k, recon.kindLabel(k)),
    ];

    Widget chip(String text, bool on, VoidCallback onTap, {IconData? icon}) => Padding(
          padding: const EdgeInsets.only(right: AppSpacing.sm),
          child: FilterChip(
            avatar: icon == null ? null : Icon(icon, size: 16),
            label: Text(text),
            selected: on,
            showCheckmark: false,
            onSelected: (_) => onTap(),
          ),
        );

    Future<void> pick(String title, List<(String?, String)> options, String? current, ReconFilter Function(String?) apply) async {
      final String? chosen = await _choose(context, title, options, current);
      if (chosen == null) return;
      onChanged(apply(chosen.isEmpty ? null : chosen));
    }

    final String dates = filter.from == null && filter.to == null
        ? 'Any date'
        : '${filter.from == null ? '…' : Formatters.dayMonth(filter.from!)} – ${filter.to == null ? '…' : Formatters.dayMonth(filter.to!)}';

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          chip(label(statuses, filter.status) ?? 'Everything', filter.status != null && filter.status != 'open',
              () => pick('Status', statuses, filter.status, (String? v) => filter.copyWith(status: v)),
              icon: Icons.tune_rounded),
          if (recon.scopes.length > 1)
            chip(label(scopes, filter.scope) ?? 'All accounts', filter.scope != null,
                () => pick('Account', scopes, filter.scope, (String? v) => filter.copyWith(scope: v))),
          if (recon.statementLabels.length > 1)
            chip(label(sources, filter.statementId) ?? 'All statements', filter.statementId != null,
                () => pick('Statement', sources, filter.statementId, (String? v) => filter.copyWith(statementId: v))),
          chip(label(kinds, filter.kind) ?? 'All types', filter.kind != null,
              () => pick('Type', kinds, filter.kind, (String? v) => filter.copyWith(kind: v))),
          chip(dates, filter.from != null || filter.to != null, () async {
            if (filter.from != null || filter.to != null) {
              onChanged(filter.copyWith(from: null, to: null));
              return;
            }
            final DateTimeRange? range = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
              initialDateRange: recon.scopes.isEmpty
                  ? null
                  : DateTimeRange(start: recon.scopes.first.from, end: recon.scopes.first.to),
            );
            if (range != null) onChanged(filter.copyWith(from: range.start, to: range.end));
          }, icon: Icons.date_range_rounded),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.currency, required this.scopeLabel, required this.onTap});

  final ReconItem item;
  final String currency;
  final String? scopeLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color tone = reconTone(context, item.status);
    final double? difference = item.difference;
    return Opacity(
      opacity: item.resolved ? 0.6 : 1,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
          child: Row(
            children: <Widget>[
              IconWell(icon: reconIcon(item.status), tone: tone, size: AppSpacing.avatarSm),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(item.name, style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      '${item.title} · ${Formatters.dayMonth(item.date)}'
                      '${scopeLabel != null ? ' · $scopeLabel' : ''}'
                      '${item.resolved ? ' · Accepted' : item.decision == 'link' ? ' · Linked' : ''}',
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  MoneyText(
                    item.isDebit ? -item.amount : item.amount,
                    currency: currency,
                    signed: true,
                    emphasis: true,
                    tone: item.isDebit ? AmountTone.neutral : AmountTone.positive,
                  ),
                  if (difference != null && difference != 0)
                    Text(
                      '${difference > 0 ? '+' : '−'}${Formatters.currency(difference.abs(), currencyCode: currency)} diff',
                      style: theme.textTheme.labelSmall?.copyWith(color: tone, fontWeight: FontWeight.w600),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
