import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../models/bank_account.dart';
import '../../models/expense.dart';
import '../../models/expense_filter.dart';
import '../../models/receivable.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/budget_provider.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/expense_provider.dart';
import '../../providers/receivable_provider.dart';
import '../../providers/reports_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/export/export_models.dart';
import '../../services/schema_capabilities.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/notification_bell.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import '../../widgets/transaction_tile.dart';
import '../accounts/account_statement_screen.dart';
import '../cards/card_statement_screen.dart';
import '../export/export_screen.dart';
import '../shell/home_shell.dart';
import 'expense_filter_sheet.dart';
import 'expense_form_screen.dart';
import 'paid_for_view.dart';
import 'repayment_sheet.dart';

/// The expense ledger.
///
/// Rows are grouped into day cards with the day's total on the header, which
/// is how a banking app presents a statement and the fastest way to answer
/// "what did I spend on Tuesday?" without reading every line.
///
/// Everything paid for someone — a purchase made for them or money lent to
/// them — is marked on its row with what is still owed, never counts in the
/// day's spending total, and has a view of its own ("Paid for someone") with
/// what each person owes and a button to record each repayment.
class ExpensesScreen extends StatefulWidget {
  const ExpensesScreen({super.key, this.initialPaidFor = false});

  /// Opens on the "Paid for someone" view (from the income screen's EMI
  /// reimbursements line).
  final bool initialPaidFor;

  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  final TextEditingController _search = TextEditingController();
  final TextEditingController _paidForSearch = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// Showing the "Paid for someone" view instead of every expense.
  late bool _paidForView = widget.initialPaidFor;
  PaidForShow _show = PaidForShow.open;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      SessionScope.attachExpenses(context);
      // Card purchases are labelled with their card's name.
      final String? userId = context.read<AuthProvider>().userId;
      if (SchemaCapabilities.creditCards && userId != null) {
        context.read<CreditCardProvider>().load(userId: userId);
      }
      // What each row paid for someone still has owed.
      _loadClaims();
    });
  }

  Future<void> _loadClaims({bool force = false}) async {
    final String? userId = context.read<AuthProvider>().userId;
    if (!SchemaCapabilities.treatments || userId == null) return;
    // The accounts name where each one's money came from, and where a
    // repayment can arrive.
    final BankAccountProvider? accounts = context.read<BankAccountProvider?>();
    await Future.wait(<Future<void>>[
      context.read<ReceivableProvider>().load(userId: userId, force: force),
      if (accounts != null) accounts.load(userId: userId),
    ]);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _search.dispose();
    _paidForSearch.dispose();
    super.dispose();
  }

  /// Requests the next page a little before the user hits the bottom, so the
  /// list feels continuous rather than stalling.
  void _onScroll() {
    if (!_scroll.hasClients || _paidForView) return;
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
    // Rebuild when the cards arrive, so a purchase shows its card's name.
    context.watch<CreditCardProvider>();
    final ReceivableProvider claims = context.watch<ReceivableProvider>();
    final bool treatments = SchemaCapabilities.treatments;
    final bool paidForView = treatments && _paidForView;
    final bool filtered = !paidForView && provider.filter.activeCount > 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Expenses'),
        actions: <Widget>[
          if (!paidForView) ...<Widget>[
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
          ] else
            // As on the web: Add from the paid-for view starts as paid for someone.
            IconButton(
              tooltip: 'Add expense paid for someone',
              onPressed: _addExpense,
              icon: const Icon(Icons.add_rounded),
            ),
          const NotificationBell(glass: false),
          const SizedBox(width: AppSpacing.xs),
        ],
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(
            (filtered ? 100 : 58) + (treatments ? 52 : 0),
          ),
          child: Column(
            children: <Widget>[
              if (treatments)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.page,
                    0,
                    AppSpacing.page,
                    AppSpacing.sm,
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<bool>(
                      segments: const <ButtonSegment<bool>>[
                        ButtonSegment<bool>(value: false, label: Text('All expenses')),
                        ButtonSegment<bool>(value: true, label: Text('Paid for someone')),
                      ],
                      selected: <bool>{paidForView},
                      showSelectedIcon: false,
                      onSelectionChanged: (Set<bool> value) {
                        setState(() => _paidForView = value.first);
                        if (value.first) _loadClaims(force: true);
                      },
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  0,
                  AppSpacing.page,
                  AppSpacing.md,
                ),
                child: paidForView
                    ? SearchField(
                        key: const ValueKey<String>('paid-for-search'),
                        controller: _paidForSearch,
                        onChanged: (_) => setState(() {}),
                        hintText: 'Search by person or what was paid',
                      )
                    : SearchField(
                        controller: _search,
                        onChanged: provider.setSearch,
                        hintText: 'Search merchant, note or description',
                      ),
              ),
              if (filtered)
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
      body: paidForView
          ? RefreshIndicator(
              onRefresh: () => _loadClaims(force: true),
              child: PaidForView(
                provider: claims,
                show: _show,
                onShow: (PaidForShow show) => setState(() => _show = show),
                search: _paidForSearch.text,
                accounts: context.watch<BankAccountProvider?>()?.accounts ?? const <BankAccount>[],
                cards: context.watch<CreditCardProvider>().cards,
                currency: settings.currency,
                onRefresh: () => _loadClaims(force: true),
                onOpen: _openClaim,
                onRepay: _repay,
              ),
            )
          : RefreshIndicator(
              onRefresh: () async {
                await Future.wait(<Future<void>>[provider.refresh(), _loadClaims(force: true)]);
              },
              child: _buildBody(provider, settings, claims),
            ),
    );
  }

  Widget _buildBody(ExpenseProvider provider, SettingsProvider settings, ReceivableProvider claims) {
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

    final String currency = settings.currency;
    final Map<String, ClaimSummary> paidFor = <String, ClaimSummary>{
      for (final ClaimSummary c in claims.claims)
        if (c.receivable.expenseId != null) c.receivable.expenseId!: c,
    };
    final List<_DayGroup> groups = _groupByDay(provider.expenses, paidFor);

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
                      paidForPerson: paidFor[expense.id]?.receivable.person,
                      paidForStatus: _paidForStatus(paidFor[expense.id], currency),
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
    if (expense.creditCardId != null) {
      return context.read<CreditCardProvider>().byId(expense.creditCardId)?.displayLabel ??
          'Credit card';
    }
    final BankAccountProvider accounts = context.read<BankAccountProvider>();
    if (!accounts.available) return null;
    if (expense.bankAccountId == null) {
      return expense.paymentMethod?.name ?? 'Cash';
    }
    return accounts.byId(expense.bankAccountId)?.nickname;
  }

  /// "₹3,000 owed" or "Settled" for an expense paid for someone; null
  /// otherwise.
  static String? _paidForStatus(ClaimSummary? claim, String currency) {
    if (claim == null) return null;
    return claim.status.isOpen
        ? '${Formatters.currency(amountLeft(claim), currencyCode: currency, compact: true)} owed'
        : 'Settled';
  }

  /// Flattens the page into day groups so scanning a long list is easier. A
  /// day's total is the user's own spending: what was paid for someone is
  /// owed back, not spent.
  List<_DayGroup> _groupByDay(List<Expense> expenses, Map<String, ClaimSummary> paidFor) {
    final List<_DayGroup> groups = <_DayGroup>[];

    for (final Expense expense in expenses) {
      if (groups.isEmpty || groups.last.day != expense.expenseDate) {
        groups.add(_DayGroup(expense.expenseDate));
      }
      groups.last.expenses.add(expense);
      if (!paidFor.containsKey(expense.id)) groups.last.total += expense.amount;
    }
    return groups;
  }

  /// Opens what was paid for someone: its expense — or, for money lent before
  /// migration 014 (no expense of its own), its account statement.
  Future<void> _openClaim(ClaimSummary claim) async {
    if (_opening) return;
    final String? userId = context.read<AuthProvider>().userId;
    final ClaimSource? source = claim.source;
    if (userId == null || source == null) return;
    final String? expenseId = claim.receivable.expenseId;
    if (expenseId != null) {
      setState(() => _opening = true);
      Expense? expense;
      try {
        expense = await context.read<ExpenseProvider>().fetchById(userId: userId, id: expenseId);
      } catch (_) {
        expense = null;
      }
      if (!mounted) return;
      setState(() => _opening = false);
      if (expense == null) {
        AppFeedback.error(context, 'That expense could not be opened.');
        return;
      }
      await _editExpense(expense);
      return;
    }
    // An EMI paid back by someone else lives on its card: open that card.
    final String? cardId = source.cardId;
    if (source.accountId == null && cardId != null) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => CardStatementScreen(cardId: cardId)),
      );
      if (mounted) await _loadClaims(force: true);
      return;
    }
    final String? accountId = source.accountId;
    final BankAccount? account = accountId == null ? null : context.read<BankAccountProvider>().byId(accountId);
    if (account == null) {
      AppFeedback.error(context, 'That account is no longer available.');
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => AccountStatementScreen(account: account)),
    );
    if (mounted) await _loadClaims(force: true);
  }

  Future<void> _repay(ClaimSummary claim) async {
    await recordRepayment(context, claim);
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
      MaterialPageRoute<bool>(
        // From the paid-for view, a new expense starts as paid for someone.
        builder: (_) => ExpenseFormScreen(
          initialPaidFor: SchemaCapabilities.treatments && _paidForView,
        ),
      ),
    );
    if (saved == true) _invalidateDerived();
  }

  void _invalidateDerived() {
    if (!mounted) return;
    // Saving or deleting an expense can mark, unmark or remove what is owed.
    context.read<ReceivableProvider?>()?.invalidate();
    context.read<DashboardProvider>().invalidate();
    context.read<BudgetProvider>().invalidate();
    context.read<ReportsProvider>().invalidate();
    context.read<CreditCardProvider>().invalidate();
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
