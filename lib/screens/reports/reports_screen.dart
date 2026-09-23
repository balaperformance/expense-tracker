import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../models/analytics.dart';
import '../../providers/auth_provider.dart';
import '../../providers/category_provider.dart';
import '../../providers/expense_provider.dart';
import '../../providers/income_provider.dart';
import '../../providers/reports_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/export/export_models.dart';
import '../../widgets/charts/category_breakdown.dart';
import '../../widgets/charts/monthly_trend_chart.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import '../../widgets/stat_tiles.dart';
import '../export/export_screen.dart';

/// Monthly analysis.
///
/// Three questions in order: what came in and went out, how this month
/// compares to recent ones, and where the money went. Each gets one card and
/// one chart — no chart is included that needs a legend to be understood.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  int _seenExpenseRevision = 0;
  int _seenIncomeRevision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// Opens Export on the month being reported, as a spending report — the
  /// document form of exactly what this screen shows.
  void _openExport(DateTime month) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExportScreen(
          initialType: ExportReportType.spendingReport,
          initialRange: ExportDateRange.month(month),
        ),
      ),
    );
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) return;

    await context.read<ReportsProvider>().load(
          userId: userId,
          categories: context.read<CategoryProvider>().categories,
          force: force,
        );
  }

  @override
  Widget build(BuildContext context) {
    final ReportsProvider reports = context.watch<ReportsProvider>();
    final SettingsProvider settings = context.watch<SettingsProvider>();

    final int expenseRevision = context.watch<ExpenseProvider>().revision;
    final int incomeRevision = context.watch<IncomeProvider>().revision;
    if (expenseRevision != _seenExpenseRevision ||
        incomeRevision != _seenIncomeRevision) {
      _seenExpenseRevision = expenseRevision;
      _seenIncomeRevision = incomeRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        context.read<ReportsProvider>().invalidate();
        _load(force: true);
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Export report',
            onPressed: () => _openExport(reports.month),
            icon: const Icon(Icons.ios_share_rounded),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: Column(
        children: <Widget>[
          MonthStepper(
            month: reports.month,
            onPrevious: () => _step(-1),
            onNext: reports.canGoForward ? () => _step(1) : null,
          ),
          const Divider(height: 1),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _load(force: true),
              child: _buildBody(reports, settings),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _step(int delta) async {
    await context
        .read<ReportsProvider>()
        .stepMonth(delta, context.read<CategoryProvider>().categories);
  }

  Widget _buildBody(ReportsProvider reports, SettingsProvider settings) {
    if (reports.isLoading && reports.report == null) {
      return const ListSkeleton(rows: 5);
    }

    if (reports.hasError && reports.report == null) {
      return ScrollableCentered(
        child: ErrorView(
          message: reports.errorMessage!,
          onRetry: () => _load(force: true),
        ),
      );
    }

    final ReportData? data = reports.report;
    if (data == null) return const SizedBox.shrink();

    if (data.isEmpty) {
      return ScrollableCentered(
        child: EmptyState(
          icon: Icons.insights_outlined,
          title: 'Nothing to report',
          message: 'No income or expenses recorded in '
              '${Formatters.monthYear(data.month)}.',
        ),
      );
    }

    final String currency = settings.currency;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.md,
        AppSpacing.page,
        AppSpacing.bottomListPaddingNoFab,
      ),
      children: <Widget>[
        _SummaryCard(data: data, currency: currency),

        const SizedBox(height: AppSpacing.section),
        const SectionHeader(title: 'Income vs expenses'),
        SurfaceCard(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          child: Column(
            children: <Widget>[
              MonthlyTrendChart(
                points: data.trend,
                currency: currency,
                showIncome: true,
                height: 176,
              ),
              const SizedBox(height: AppSpacing.md),
              ChartLegend(
                entries: <({Color color, String label})>[
                  (label: 'Expenses', color: ToneColors.expense(context)),
                  (label: 'Income', color: ToneColors.income(context)),
                ],
              ),
            ],
          ),
        ),

        if (data.categoryBreakdown.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.section),
          SectionHeader(
            title: 'Spending by category',
            caption: '${data.transactionCount} '
                '${data.transactionCount == 1 ? 'expense' : 'expenses'}',
          ),
          SurfaceCard(
            child: Column(
              children: <Widget>[
                CategoryDonut(
                  breakdown: data.categoryBreakdown,
                  currency: currency,
                ),
                const SizedBox(height: AppSpacing.lg),
                CategoryBreakdownList(
                  breakdown: data.categoryBreakdown,
                  currency: currency,
                ),
              ],
            ),
          ),
        ],

        if (data.topCategory != null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          SurfaceCard(
            padding: EdgeInsets.zero,
            child: AppListRow(
              leading: IconWell(
                icon: Icons.emoji_events_outlined,
                tone: Theme.of(context).colorScheme.primary,
              ),
              title: data.topCategory!.name,
              subtitle: 'Biggest category this month',
              trailing: MoneyText(
                data.topCategory!.total,
                currency: currency,
                compact: true,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Income, expenses, net and average — the month in four figures.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.data, required this.currency});

  final ReportData data;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool saved = data.net >= 0;

    return SurfaceCard(
      child: Column(
        children: <Widget>[
          // Net is the headline: it is the only one of the four that answers
          // "did this month go well?".
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      saved ? 'Saved this month' : 'Overspent this month',
                      style: theme.textTheme.labelMedium,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    MoneyText(
                      data.net,
                      currency: currency,
                      signed: data.net != 0,
                      tone: AmountTone.auto,
                      fit: true,
                      style: theme.textTheme.displaySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              IconWell(
                icon: saved
                    ? Icons.savings_outlined
                    : Icons.warning_amber_rounded,
                tone: saved
                    ? ToneColors.income(context)
                    : ToneColors.expense(context),
                size: 44,
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Divider(height: 1),
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: StatTile(
                  label: 'Income',
                  amount: data.totalIncome,
                  currency: currency,
                  icon: Icons.south_west_rounded,
                  tone: ToneColors.income(context),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: StatTile(
                  label: 'Expenses',
                  amount: data.totalExpense,
                  currency: currency,
                  icon: Icons.north_east_rounded,
                  tone: ToneColors.expense(context),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: StatTile(
                  label: 'Avg spend',
                  amount: data.averagePerTransaction,
                  currency: currency,
                  icon: Icons.tag_rounded,
                  tone: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
