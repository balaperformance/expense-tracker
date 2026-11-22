import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../models/analytics.dart';
import '../../models/expense.dart';
import '../../providers/auth_provider.dart';
import '../../providers/category_provider.dart';
import '../../providers/category_spending_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/charts/category_breakdown.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import '../../widgets/month_picker.dart';
import '../../widgets/transaction_tile.dart';
import '../expenses/expense_form_screen.dart';

/// Every category's spending in one month — opened from the dashboard's
/// "Where it went" card, for the month the dashboard shows. The figures are
/// the dashboard's own (see [CategorySpendingProvider]); Previous / Next step
/// through the months, and a category opens its expenses.
class CategorySpendingScreen extends StatefulWidget {
  const CategorySpendingScreen({super.key, required this.month});

  /// The month to open on.
  final DateTime month;

  @override
  State<CategorySpendingScreen> createState() => _CategorySpendingScreenState();
}

class _CategorySpendingScreenState extends State<CategorySpendingScreen> {
  late DateTime _month = DateTime(widget.month.year, widget.month.month, 1);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool force = false}) =>
      _loadMonth(context, _month, force: force);

  void _show(DateTime month) {
    setState(() => _month = DateTime(month.year, month.month, 1));
    _load();
  }

  Future<void> _openCategory(CategorySpend spend) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => CategoryTransactionsScreen(
          categoryId: spend.categoryId,
          categoryName: spend.name,
          month: _month,
        ),
      ),
    );
    // An expense may have been edited there: this month is read again.
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final CategorySpendingProvider provider =
        context.watch<CategorySpendingProvider>();
    final String currency = context.watch<SettingsProvider>().currency;
    final CategoryMonthSpending? spending = provider.spendingFor(_month);
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Spending by category')),
      body: RefreshIndicator(
        onRefresh: () => _load(force: true),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.page,
            AppSpacing.sm,
            AppSpacing.page,
            AppSpacing.xxxl,
          ),
          children: <Widget>[
            MonthSwitcher(
              month: _month,
              onChanged: _show,
              earliest: () async => provider.earliest,
            ),
            const SizedBox(height: AppSpacing.md),
            if (spending == null)
              provider.hasError
                  ? ErrorView(
                      message: provider.errorMessage ?? 'Could not load spending.',
                      onRetry: () => _load(force: true),
                    )
                  : const SizedBox(height: 320, child: ListSkeleton(rows: 5))
            else if (spending.isEmpty)
              EmptyState(
                icon: Icons.pie_chart_outline_rounded,
                title: 'No expenses in ${Formatters.monthYear(_month)}',
                message: 'Expenses you record this month show here by category.',
              )
            else ...<Widget>[
              SurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text('Total spending', style: theme.textTheme.labelMedium),
                    const SizedBox(height: AppSpacing.xxs),
                    MoneyText(
                      spending.total,
                      currency: currency,
                      fit: true,
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    CategoryDonut(breakdown: spending.breakdown, currency: currency),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.section),
              SectionHeader(
                title: 'Categories',
                caption: '${spending.breakdown.length}',
              ),
              SurfaceCard(
                child: CategoryBreakdownList(
                  breakdown: spending.breakdown,
                  currency: currency,
                  showCounts: true,
                  onTap: _openCategory,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One category's expenses in a month, newest first — exactly the rows its
/// total on [CategorySpendingScreen] is made of. Previous / Next keep the
/// category; an expense opens for editing.
class CategoryTransactionsScreen extends StatefulWidget {
  const CategoryTransactionsScreen({
    super.key,
    required this.categoryId,
    required this.categoryName,
    required this.month,
  });

  /// Null for the uncategorised group.
  final String? categoryId;
  final String categoryName;
  final DateTime month;

  @override
  State<CategoryTransactionsScreen> createState() =>
      _CategoryTransactionsScreenState();
}

class _CategoryTransactionsScreenState extends State<CategoryTransactionsScreen> {
  late DateTime _month = DateTime(widget.month.year, widget.month.month, 1);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool force = false}) =>
      _loadMonth(context, _month, force: force);

  void _show(DateTime month) {
    setState(() => _month = DateTime(month.year, month.month, 1));
    _load();
  }

  Future<void> _edit(Expense expense) async {
    final bool? changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => ExpenseFormScreen(expense: expense)),
    );
    if (changed == true && mounted) {
      context.read<CategorySpendingProvider>().invalidate();
      _load(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final CategorySpendingProvider provider =
        context.watch<CategorySpendingProvider>();
    final String currency = context.watch<SettingsProvider>().currency;
    final CategoryMonthSpending? spending = provider.spendingFor(_month);
    final CategorySpend? spend = spending?.category(widget.categoryId);
    final ThemeData theme = Theme.of(context);
    final String monthLabel = Formatters.monthYear(_month);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(widget.categoryName, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              spending == null
                  ? monthLabel
                  : '$monthLabel · ${Formatters.currency(spend?.total ?? 0, currencyCode: currency)}',
              style: theme.textTheme.labelSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(force: true),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.page,
            AppSpacing.sm,
            AppSpacing.page,
            AppSpacing.xxxl,
          ),
          children: <Widget>[
            MonthSwitcher(
              month: _month,
              onChanged: _show,
              earliest: () async => provider.earliest,
            ),
            const SizedBox(height: AppSpacing.md),
            if (spending == null)
              provider.hasError
                  ? ErrorView(
                      message: provider.errorMessage ?? 'Could not load spending.',
                      onRetry: () => _load(force: true),
                    )
                  : const SizedBox(height: 320, child: ListSkeleton(rows: 5))
            else if (spend == null || spend.expenses.isEmpty)
              EmptyState(
                icon: Icons.receipt_long_outlined,
                title: 'No ${widget.categoryName} expenses in $monthLabel',
                message: 'Pick another month to see what was spent here.',
              )
            else
              CardList(
                dividerIndent: AppSpacing.rowDividerIndent,
                children: <Widget>[
                  for (final Expense e in spend.expenses)
                    ExpenseTile(
                      expense: e,
                      currency: currency,
                      onTap: () => _edit(e),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> _loadMonth(BuildContext context, DateTime month, {bool force = false}) async {
  final String? userId = context.read<AuthProvider>().userId;
  if (userId == null) return;
  await context.read<CategorySpendingProvider>().load(
        userId: userId,
        month: month,
        categories: context.read<CategoryProvider>().categories,
        force: force,
      );
}
