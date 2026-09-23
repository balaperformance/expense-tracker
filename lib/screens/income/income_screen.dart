import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../models/income.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/income_provider.dart';
import '../../providers/reports_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import '../../widgets/transaction_tile.dart';
import '../shell/home_shell.dart';
import 'income_form_screen.dart';

/// Money in.
///
/// Deliberately the same layout as Expenses — same search, same day grouping,
/// same row shape — so the only thing that changes between the two tabs is
/// the direction of the money. Sameness is what makes the green/red
/// distinction instant.
class IncomeScreen extends StatefulWidget {
  const IncomeScreen({super.key});

  @override
  State<IncomeScreen> createState() => _IncomeScreenState();
}

class _IncomeScreenState extends State<IncomeScreen> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) SessionScope.attachIncome(context);
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final double remaining =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 400) {
      context.read<IncomeProvider>().loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final IncomeProvider provider = context.watch<IncomeProvider>();
    final SettingsProvider settings = context.watch<SettingsProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Income'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(58),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              0,
              AppSpacing.page,
              AppSpacing.md,
            ),
            child: SearchField(
              controller: _search,
              onChanged: provider.setSearch,
              hintText: 'Search source or description',
            ),
          ),
        ),
      ),
      floatingActionButton: Padding(
        // The income screen is nested inside the shell Scaffold whose
        // bottomNavigationBar is the floating glass pill. Nested Scaffolds
        // do not inherit the parent's nav-bar inset for FAB positioning, so
        // the FAB ends up behind the pill without this nudge.
        padding: const EdgeInsets.only(bottom: AppSpacing.navBarHeight - 8),
        child: AppFab(
          heroTag: 'income_fab',
          onPressed: _addIncome,
          label: 'Income',
        ),
      ),
      body: RefreshIndicator(
        onRefresh: provider.refresh,
        child: _buildBody(provider, settings),
      ),
    );
  }

  Widget _buildBody(IncomeProvider provider, SettingsProvider settings) {
    if (provider.isInitialLoad) return const ListSkeleton();

    if (provider.hasError && provider.items.isEmpty) {
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
          icon: Icons.savings_outlined,
          title: 'No income yet',
          message: 'Record salary, freelance work or any other money in.',
          actionLabel: 'Add income',
          onAction: _addIncome,
        ),
      );
    }

    if (provider.showNoResults) {
      return ScrollableCentered(
        child: EmptyState(
          icon: Icons.search_off_rounded,
          title: 'No matches',
          message: 'Nothing matches "${provider.search}".',
          actionLabel: 'Clear search',
          onAction: () {
            _search.clear();
            provider.setSearch('');
          },
        ),
      );
    }

    final List<_DayGroup> groups = _groupByDay(provider.items);
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
            count: provider.items.length,
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
              tone: AmountTone.positive,
              isFirst: index == 0,
            ),
            CardList(
              children: <Widget>[
                for (final Income income in group.items)
                  Dismissible(
                    key: ValueKey<String>(income.id),
                    direction: DismissDirection.endToStart,
                    background: const _DeleteBackground(),
                    confirmDismiss: (_) => _confirmDelete(income),
                    child: IncomeTile(
                      income: income,
                      currency: currency,
                      showDate: false,
                      destinationLabel: _destinationLabel(income),
                      onTap: () => _editIncome(income),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  /// Bank account the money landed in, when one is linked.
  String? _destinationLabel(Income income) {
    final BankAccountProvider accounts = context.read<BankAccountProvider>();
    if (!accounts.available || income.bankAccountId == null) return null;
    return accounts.byId(income.bankAccountId)?.nickname;
  }

  List<_DayGroup> _groupByDay(List<Income> items) {
    final List<_DayGroup> groups = <_DayGroup>[];

    for (final Income income in items) {
      if (groups.isEmpty || groups.last.day != income.incomeDate) {
        groups.add(_DayGroup(income.incomeDate));
      }
      groups.last.items.add(income);
      groups.last.total += income.amount;
    }
    return groups;
  }

  Future<bool> _confirmDelete(Income income) async {
    final SettingsProvider settings = context.read<SettingsProvider>();
    final bool confirmed = await AppFeedback.confirm(
      context,
      title: 'Delete income?',
      message:
          '${Formatters.currency(income.amount, currencyCode: settings.currency)} '
          '· ${income.title}. This cannot be undone.',
    );

    if (!confirmed || !mounted) return false;

    final IncomeProvider provider = context.read<IncomeProvider>();
    final bool ok = await provider.delete(income);

    if (!mounted) return ok;
    if (ok) {
      AppFeedback.success(context, 'Income deleted');
      _invalidateDerived();
    } else {
      AppFeedback.error(
        context,
        provider.errorMessage ?? 'Could not delete the income.',
      );
    }
    return ok;
  }

  Future<void> _addIncome() async {
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const IncomeFormScreen()),
    );
    if (saved == true) _invalidateDerived();
  }

  Future<void> _editIncome(Income income) async {
    final bool? changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => IncomeFormScreen(income: income),
      ),
    );
    if (changed == true) _invalidateDerived();
  }

  void _invalidateDerived() {
    if (!mounted) return;
    context.read<DashboardProvider>().invalidate();
    context.read<ReportsProvider>().invalidate();
  }
}

class _DayGroup {
  _DayGroup(this.day);

  final DateTime day;
  final List<Income> items = <Income>[];
  double total = 0;
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
          '$count ${count == 1 ? 'entry' : 'entries'}',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    );
  }
}
