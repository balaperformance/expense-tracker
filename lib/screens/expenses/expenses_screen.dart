import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../models/expense.dart';
import '../../models/expense_filter.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/budget_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/expense_provider.dart';
import '../../providers/reports_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/export/export_models.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import '../../widgets/transaction_tile.dart';
import '../export/export_screen.dart';
import '../shell/home_shell.dart';
import 'expense_filter_sheet.dart';
import 'expense_form_screen.dart';

/// The expense ledger.
///
/// Rows are grouped into day cards with the day's total on the header, which
/// is how a banking app presents a statement and the fastest way to answer
/// "what did I spend on Tuesday?" without reading every line.
class ExpensesScreen extends StatefulWidget {
  const ExpensesScreen({super.key});

  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) SessionScope.attachExpenses(context);
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  /// Requests the next page a little before the user hits the bottom, so the
  /// list feels continuous rather than stalling.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final double remaining =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 400) {
      context.read<ExpenseProvider>().loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ExpenseProvider provider = context.watch<ExpenseProvider>();
    final SettingsProvider settings = context.watch<SettingsProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Expenses'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Export',
            onPressed: () => _openExport(provider),
            icon: const Icon(Icons.ios_share_rounded),
          ),
          IconButton(
            tooltip: 'Sort',
            onPressed: () => _openSort(provider),
            icon: const Icon(Icons.swap_vert_rounded),
          ),
          _FilterButton(
            count: provider.filter.activeCount,
            onPressed: () => _openFilters(provider),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(
            provider.filter.activeCount > 0 ? 100 : 58,
          ),
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  0,
                  AppSpacing.page,
                  AppSpacing.md,
                ),
                child: SearchField(
                  controller: _search,
                  onChanged: provider.setSearch,
                  hintText: 'Search merchant, note or description',
                ),
              ),
              if (provider.filter.activeCount > 0)
                _ActiveFilterBar(
                  filter: provider.filter,
                  onClear: () {
                    provider.clearFilters();
                  },
                  onEdit: () => _openFilters(provider),
                ),
            ],
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: provider.refresh,
        child: _buildBody(provider, settings),
      ),
    );
  }

  Widget _buildBody(ExpenseProvider provider, SettingsProvider settings) {
    if (provider.isInitialLoad) return const ListSkeleton();

    if (provider.hasError && provider.expenses.isEmpty) {
      return ScrollableCentered(
        child: ErrorView(
          message: provider.errorMessage!,
          onRetry: provider.refresh,
        ),
      );
    }

    if (provider.showEmptyState) {
      return ScrollableCentered(
        child: EmptyState(
          icon: Icons.receipt_long_outlined,
          title: 'No expenses yet',
          message: 'Add your first expense to start seeing it here.',
          actionLabel: 'Add expense',
          onAction: _addExpense,
        ),
      );
    }

    if (provider.showNoResults) {
      return ScrollableCentered(
        child: EmptyState(
          icon: Icons.search_off_rounded,
          title: 'No matches',
          message: 'Nothing matches your search and filters.',
          actionLabel: 'Clear all',
          onAction: () {
            _search.clear();
            provider.clearFilters();
            provider.setSearch('');
          },
        ),
      );
    }

    final List<_DayGroup> groups = _groupByDay(provider.expenses);
    final String currency = settings.currency;

    return ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.sm,
        AppSpacing.page,
        AppSpacing.bottomListPadding,
      ),
      itemCount: groups.length + 1,
      itemBuilder: (BuildContext context, int index) {
        if (index == groups.length) {
          return _Footer(
            loading: provider.loadingMore,
            hasMore: provider.hasMore,
            count: provider.expenses.length,
          );
        }

        final _DayGroup group = groups[index];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            DayHeader(
              label: Formatters.relativeDay(group.day),
              total: group.total,
              currency: currency,
              isFirst: index == 0,
            ),
            CardList(
              children: <Widget>[
                for (final Expense expense in group.expenses)
                  Dismissible(
                    key: ValueKey<String>(expense.id),
                    direction: DismissDirection.endToStart,
                    background: const _DeleteBackground(),
                    confirmDismiss: (_) => _confirmDelete(expense),
                    child: ExpenseTile(
                      expense: expense,
                      currency: currency,
                      showDate: false,
                      sourceLabel: _sourceLabel(expense),
                      onTap: () => _editExpense(expense),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  /// Payment source as the user thinks of it: the bank nickname, or Cash.
  ///
  /// Falls back to the payment method when bank accounts are not in use, so
  /// the third meta slot is never blank.
  String? _sourceLabel(Expense expense) {
    final BankAccountProvider accounts = context.read<BankAccountProvider>();
    if (!accounts.available) return null;
    if (expense.bankAccountId == null) {
      return expense.paymentMethod?.name ?? 'Cash';
    }
    return accounts.byId(expense.bankAccountId)?.nickname;
  }

  /// Flattens the page into day groups so scanning a long list is easier.
  List<_DayGroup> _groupByDay(List<Expense> expenses) {
    final List<_DayGroup> groups = <_DayGroup>[];

    for (final Expense expense in expenses) {
      if (groups.isEmpty || groups.last.day != expense.expenseDate) {
        groups.add(_DayGroup(expense.expenseDate));
      }
      groups.last.expenses.add(expense);
      groups.last.total += expense.amount;
    }
    return groups;
  }

  Future<bool> _confirmDelete(Expense expense) async {
    final SettingsProvider settings = context.read<SettingsProvider>();
    final bool confirmed = await AppFeedback.confirm(
      context,
      title: 'Delete expense?',
      message:
          '${Formatters.currency(expense.amount, currencyCode: settings.currency)} '
          '· ${expense.title}. This cannot be undone.',
    );

    if (!confirmed || !mounted) return false;

    final ExpenseProvider provider = context.read<ExpenseProvider>();
    final bool ok = await provider.delete(expense);

    if (!mounted) return ok;
    if (ok) {
      AppFeedback.success(context, 'Expense deleted');
      _invalidateDerived();
    } else {
      AppFeedback.error(
        context,
        provider.errorMessage ?? 'Could not delete the expense.',
      );
    }
    return ok;
  }

  Future<void> _editExpense(Expense expense) async {
    final bool? changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ExpenseFormScreen(expense: expense),
      ),
    );
    if (changed == true) _invalidateDerived();
  }

  Future<void> _addExpense() async {
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const ExpenseFormScreen()),
    );
    if (saved == true) _invalidateDerived();
  }

  void _invalidateDerived() {
    if (!mounted) return;
    context.read<DashboardProvider>().invalidate();
    context.read<BudgetProvider>().invalidate();
    context.read<ReportsProvider>().invalidate();
  }

  /// Opens Export carrying whatever the list is already narrowed to, so
  /// "export what I am looking at" needs no re-picking.
  ///
  /// Only the date range and the categories travel: they are the two filters
  /// the export screen itself can express. A text search or a payment-method
  /// filter has no equivalent there, and silently ignoring them would produce
  /// a file that does not match what is on screen — so the export simply
  /// starts from the broader, honest selection.
  void _openExport(ExpenseProvider provider) {
    final ExpenseFilter filter = provider.filter;
    final DateTime? from = filter.from;
    final DateTime? to = filter.to;

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExportScreen(
          initialType: ExportReportType.expenses,
          initialRange: from != null && to != null
              ? ExportDateRange(from, to)
              : null,
        ),
      ),
    );
  }

  Future<void> _openFilters(ExpenseProvider provider) async {
    final ExpenseFilter? next = await showAppSheet<ExpenseFilter>(
      context: context,
      builder: (_) => ExpenseFilterSheet(initial: provider.filter),
    );
    if (next != null) provider.applyFilter(next);
  }

  Future<void> _openSort(ExpenseProvider provider) async {
    final ExpenseSort? picked = await showAppSheet<ExpenseSort>(
      context: context,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  0,
                  AppSpacing.xl,
                  AppSpacing.md,
                ),
                child: Text(
                  'Sort by',
                  style: Theme.of(sheetContext).textTheme.titleLarge,
                ),
              ),
              ...ExpenseSort.values.map(
                (ExpenseSort sort) => AppListRow(
                  title: sort.label,
                  onTap: () => Navigator.of(sheetContext).pop(sort),
                  trailing: provider.filter.sort == sort
                      ? Icon(
                          Icons.check_rounded,
                          size: AppSpacing.iconMd,
                          color: Theme.of(sheetContext).colorScheme.primary,
                        )
                      : null,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ),
        );
      },
    );
    if (picked != null) provider.setSort(picked);
  }
}

class _DayGroup {
  _DayGroup(this.day);

  final DateTime day;
  final List<Expense> expenses = <Expense>[];
  double total = 0;
}

/// Strip below the search field summarising what is currently filtered.
///
/// Without it an empty-looking list after a filter is applied reads as a bug
/// rather than as a filter still being on.
class _ActiveFilterBar extends StatelessWidget {
  const _ActiveFilterBar({
    required this.filter,
    required this.onClear,
    required this.onEdit,
  });

  final ExpenseFilter filter;
  final VoidCallback onClear;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int count = filter.activeCount;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        0,
        AppSpacing.page,
        AppSpacing.md,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: InkWell(
              onTap: onEdit,
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.filter_alt_rounded,
                    size: AppSpacing.iconSm,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    '$count ${count == 1 ? 'filter' : 'filters'} applied',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          TextButton(onPressed: onClear, child: const Text('Clear')),
        ],
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.count, required this.onPressed});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        IconButton(
          tooltip: 'Filter',
          onPressed: onPressed,
          icon: Icon(
            count > 0 ? Icons.filter_alt_rounded : Icons.tune_rounded,
            color: count > 0 ? scheme.primary : null,
          ),
        ),
        if (count > 0)
          Positioned(
            right: 5,
            top: 7,
            child: Container(
              constraints: const BoxConstraints(minWidth: 15),
              height: 15,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
                border: Border.all(color: scheme.surface, width: 1.5),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontSize: 9.5,
                  height: 1,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _DeleteBackground extends StatelessWidget {
  const _DeleteBackground();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: AppSpacing.xl),
      color: scheme.error,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.delete_outline_rounded,
            color: scheme.onError,
            size: AppSpacing.iconMd,
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            'Delete',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: scheme.onError,
                ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.loading,
    required this.hasMore,
    required this.count,
  });

  final bool loading;
  final bool hasMore;
  final int count;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
        ),
      );
    }

    if (hasMore || count == 0) return const SizedBox(height: AppSpacing.lg);

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xl),
      child: Center(
        child: Text(
          '$count ${count == 1 ? 'expense' : 'expenses'}',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    );
  }
}
