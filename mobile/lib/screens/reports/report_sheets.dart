import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../models/expense.dart';
import '../../models/insights.dart';
import '../../providers/expense_provider.dart';
import '../../providers/insights_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import '../expenses/expense_form_screen.dart';
import 'report_parts.dart';

/// How many rows a drill-down lists; the newest are shown.
const int _sheetLimit = 200;

/// Opens the transactions behind a figure.
Future<void> showInsightRows(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<String> ids,
}) {
  return showAppSheet<void>(
    context: context,
    builder: (_) => _RowsSheet(title: title, subtitle: subtitle, ids: ids),
  );
}

/// Opens one recurring payment: what it costs, how sure the app is, and every
/// payment behind it.
Future<void> showRecurringSheet(BuildContext context, RecurringItem series) {
  return showAppSheet<void>(
    context: context,
    builder: (_) => _RecurringSheet(series: series),
  );
}

/// Follows a drill from a highlight or a saving idea: its transactions, its
/// recurring payment, or — through [onSection] — an analytics section.
Future<void> openInsightDrill(
  BuildContext context,
  InsightDrill drill, {
  required ValueChanged<String> onSection,
}) async {
  switch (drill.type) {
    case 'rows':
      await showInsightRows(context, title: drill.title, subtitle: drill.subtitle, ids: drill.ids);
    case 'recurring':
      final RecurringItem? series = context.read<InsightsProvider>().overview?.recurringByKey(drill.key ?? '');
      if (series != null) await showRecurringSheet(context, series);
    case 'section':
      if (drill.section != null) onSection(drill.section!);
  }
}

/// Opens the saved expense behind a report row.
Future<void> openInsightExpense(BuildContext context, String id) async {
  final InsightsProvider insights = context.read<InsightsProvider>();
  final NavigatorState navigator = Navigator.of(context);
  final Expense? expense = await insights.expense(id).catchError((Object _) => null);
  if (!context.mounted) return;
  if (expense == null) {
    AppFeedback.error(context, 'That expense is no longer available.');
    return;
  }
  final bool? changed = await navigator.push<bool>(
    MaterialPageRoute<bool>(builder: (_) => ExpenseFormScreen(expense: expense)),
  );
  if (changed == true && context.mounted) {
    // The expense list and the reports follow the change.
    await context.read<ExpenseProvider>().refresh();
  }
}

class _RowsSheet extends StatefulWidget {
  const _RowsSheet({required this.title, this.subtitle, required this.ids});

  final String title;
  final String? subtitle;
  final List<String> ids;

  @override
  State<_RowsSheet> createState() => _RowsSheetState();
}

class _RowsSheetState extends State<_RowsSheet> {
  late final Future<({double total, List<InsightRow> rows})> _rows =
      context.read<InsightsProvider>().rows(widget.ids);

  @override
  Widget build(BuildContext context) {
    final String currency = context.watch<SettingsProvider>().currency;
    return FutureBuilder<({double total, List<InsightRow> rows})>(
      future: _rows,
      builder: (BuildContext context, AsyncSnapshot<({double total, List<InsightRow> rows})> snapshot) {
        final ({double total, List<InsightRow> rows})? data = snapshot.data;
        final String counted = data == null
            ? ''
            : '${plural(data.rows.length, 'expense', 'expenses')} · '
                '${Formatters.currency(data.total, currencyCode: currency)}';
        return AppSheet(
          title: widget.title,
          subtitle: <String>[
            if (widget.subtitle != null) widget.subtitle!,
            if (counted.isNotEmpty) counted,
          ].join(' · '),
          children: <Widget>[
            if (snapshot.hasError)
              const InlineError(message: 'These transactions could not be loaded. Try again.')
            else if (data == null)
              // Not a ListSkeleton: that is a list of its own, inside the sheet's scroll.
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: AppLoader(),
              )
            else if (data.rows.isEmpty)
              const EmptyState(
                compact: true,
                icon: Icons.search_off_rounded,
                title: 'No transactions',
                message: 'Nothing is behind this figure.',
              )
            else ...<Widget>[
              CardList(
                children: <Widget>[
                  for (final InsightRow row in data.rows.take(_sheetLimit))
                    InsightRowTile(
                      row: row,
                      currency: currency,
                      onTap: () => openInsightExpense(context, row.id),
                    ),
                ],
              ),
              if (data.rows.length > _sheetLimit)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Text(
                    'Showing the newest $_sheetLimit of ${data.rows.length}.',
                    style: Theme.of(context).textTheme.labelSmall,
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

class _RecurringSheet extends StatelessWidget {
  const _RecurringSheet({required this.series});

  final RecurringItem series;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String currency = context.watch<SettingsProvider>().currency;
    final DateTime today = DateUtils.dateOnly(DateTime.now());
    final ({double from, double to, DateTime since})? price = series.priceChange;

    return AppSheet(
      title: series.label,
      subtitle: '${series.kindLabel} · ${series.cadenceLabel}',
      children: <Widget>[
        SurfaceCard(
          child: FigureRow(
            figures: <ReportFigure>[
              ReportFigure(series.variable ? 'Recent average' : 'Amount', Formatters.currency(series.amount, currencyCode: currency)),
              ReportFigure('In a row', '${series.streak} ${series.streak == 1 ? series.unitOne : series.unitMany}'),
              ReportFigure('A year (estimate)', Formatters.currency(series.yearlyCost, currencyCode: currency, compact: true)),
              ReportFigure('Paid so far', Formatters.currency(series.totalPaid, currencyCode: currency, compact: true)),
              ReportFigure('Last payment', Formatters.dayMonthYear(series.lastDate)),
              ReportFigure(
                series.active ? 'Next expected' : 'Status',
                series.active
                    ? (series.nextDate.isBefore(today) ? 'Due now' : '~${Formatters.dayMonthYear(series.nextDate)}')
                    : 'Not seen recently',
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (price != null)
          AppNotice(
            icon: Icons.arrow_upward_rounded,
            tone: ToneColors.warning(context),
            message: 'The price went up from ${Formatters.currency(price.from, currencyCode: currency)} '
                'to ${Formatters.currency(price.to, currencyCode: currency)} in ${Formatters.monthYear(price.since)}.',
          )
        else if (series.trend == 'up')
          AppNotice(
            icon: Icons.arrow_upward_rounded,
            tone: ToneColors.warning(context),
            message: 'The amount has been rising: the last three payments were over 15% above the first three.',
          ),
        if (price != null || series.trend == 'up') const SizedBox(height: AppSpacing.md),
        Text('Why it is listed', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        Text(series.explanation, style: theme.textTheme.bodySmall),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '${series.variable ? 'Yearly cost uses the recent average. ' : 'Yearly cost uses the latest price. '}'
          'The next date assumes the same rhythm. Both are estimates.',
          style: theme.textTheme.labelSmall,
        ),
        if (series.extraCount > 0) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          AppNotice(
            icon: Icons.warning_amber_rounded,
            tone: ToneColors.expense(context),
            message: '${series.extraCount == 1 ? 'One extra charge' : '${series.extraCount} extra charges'} came within '
                'a few days of a regular payment — worth checking for a double charge.',
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        Text('Payments', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.sm),
        CardList(
          children: <Widget>[
            for (final InsightRow row in series.payments)
              InsightRowTile(row: row, currency: currency, onTap: () => openInsightExpense(context, row.id)),
          ],
        ),
      ],
    );
  }
}
