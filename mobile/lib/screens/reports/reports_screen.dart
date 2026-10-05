import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/category_provider.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/expense_provider.dart';
import '../../providers/income_provider.dart';
import '../../providers/insights_provider.dart';
import '../../providers/payment_method_provider.dart';
import '../../providers/reports_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/export/export_models.dart';
import '../../services/schema_capabilities.dart';
import '../../widgets/common/notification_bell.dart';
import '../../widgets/common/state_views.dart';
import '../export/export_screen.dart';
import 'analytics_view.dart';
import 'highlights_view.dart';
import 'month_report_view.dart';
import 'spending_view.dart';

enum _ReportView { highlights, spending, analytics }

/// Reports: what matters (Highlights), any slice of spending by tags and
/// filters (Spending), and the financial picture behind it (Analytics) — the
/// web's Reports, computed by the same insights. All three read one loaded
/// history, so switching between them is instant.
///
/// Where the insights engine cannot run, the month report is shown instead.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  _ReportView _view = _ReportView.highlights;

  /// An analytics section to scroll to; the Analytics tab clears it.
  final ValueNotifier<String?> _jump = ValueNotifier<String?>(null);

  int? _seenExpenseRevision;
  int? _seenIncomeRevision;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _jump.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) return;
    final BankAccountProvider accounts = context.read<BankAccountProvider>();
    final CreditCardProvider cards = context.read<CreditCardProvider>();
    // The names a row shows: accounts and cards may not be loaded yet.
    await Future.wait(<Future<void>>[
      accounts.load(userId: userId),
      if (SchemaCapabilities.creditCards) cards.load(userId: userId),
    ]);
    if (!mounted) return;
    await context.read<InsightsProvider>().load(
          userId: userId,
          currency: context.read<SettingsProvider>().currency,
          catalog: InsightsCatalog(
            categories: context.read<CategoryProvider>().categories,
            paymentMethods: context.read<PaymentMethodProvider>().methods,
            accounts: accounts.accounts,
            cards: cards.overviews,
          ),
          force: force,
        );
  }

  void _showSection(String section) {
    setState(() => _view = _ReportView.analytics);
    _jump.value = section;
  }

  /// The document form of the report: this month's spending report — or, in
  /// the month report, the month being shown.
  void _openExport(bool monthReport) {
    final DateTime month = monthReport
        ? context.read<ReportsProvider>().month
        : AppDateUtils.firstDayOf(AppDateUtils.today());
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExportScreen(
          initialType: ExportReportType.spendingReport,
          initialRange: ExportDateRange.month(month),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final InsightsProvider insights = context.watch<InsightsProvider>();

    // A recorded or edited expense or income: read again.
    final int expenseRevision = context.watch<ExpenseProvider>().revision;
    final int incomeRevision = context.watch<IncomeProvider>().revision;
    if (expenseRevision != _seenExpenseRevision || incomeRevision != _seenIncomeRevision) {
      // The first build only notes where the counters stand.
      final bool first = _seenExpenseRevision == null;
      _seenExpenseRevision = expenseRevision;
      _seenIncomeRevision = incomeRevision;
      if (!first) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          context.read<InsightsProvider>().invalidate();
          _load(force: true);
        });
      }
    }

    final bool monthReport = insights.engineUnavailable;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Export report',
            onPressed: () => _openExport(monthReport),
            icon: const Icon(Icons.ios_share_rounded),
          ),
          const NotificationBell(glass: false),
          const SizedBox(width: AppSpacing.xs),
        ],
        bottom: monthReport
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.page, 0, AppSpacing.page, AppSpacing.md),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<_ReportView>(
                      showSelectedIcon: false,
                      segments: const <ButtonSegment<_ReportView>>[
                        ButtonSegment<_ReportView>(value: _ReportView.highlights, label: Text('Highlights')),
                        ButtonSegment<_ReportView>(value: _ReportView.spending, label: Text('Spending')),
                        ButtonSegment<_ReportView>(value: _ReportView.analytics, label: Text('Analytics')),
                      ],
                      selected: <_ReportView>{_view},
                      onSelectionChanged: (Set<_ReportView> next) => setState(() => _view = next.first),
                    ),
                  ),
                ),
              ),
      ),
      body: monthReport ? const MonthReportView() : _body(insights),
    );
  }

  Widget _body(InsightsProvider insights) {
    if (insights.overview == null) {
      if (insights.hasError) {
        return ScrollableCentered(
          child: ErrorView(
            message: insights.errorMessage!,
            onRetry: () => _load(force: true),
          ),
        );
      }
      return const ListSkeleton(rows: 5);
    }

    Widget refreshable(Widget child) => RefreshIndicator(onRefresh: () => _load(force: true), child: child);

    return AnimatedOpacity(
      // Reloading keeps what is shown, dimmed, instead of a blank screen.
      opacity: insights.isLoading ? 0.85 : 1,
      duration: const Duration(milliseconds: 150),
      child: IndexedStack(
        index: _view.index,
        children: <Widget>[
          refreshable(HighlightsTab(onSection: _showSection)),
          refreshable(const SpendingTab()),
          refreshable(AnalyticsTab(jump: _jump)),
        ],
      ),
    );
  }
}
