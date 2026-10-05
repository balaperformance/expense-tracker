import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_glass.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../../models/analytics.dart';
import '../../models/bank_account.dart';
import '../../models/budget.dart';
import '../../models/card_statement.dart';
import '../../providers/ai_chat_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/budget_provider.dart';
import '../../providers/category_provider.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/expense_provider.dart';
import '../../providers/income_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/schema_capabilities.dart';
import '../../widgets/budget_progress_tile.dart';
import '../../widgets/card_widgets.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/charts/category_breakdown.dart';
import '../../widgets/charts/monthly_trend_chart.dart';
import '../../widgets/common/card_carousel.dart';
import '../../widgets/common/notification_bell.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import '../../widgets/stat_tiles.dart';
import '../../widgets/transaction_tile.dart';
import '../accounts/accounts_screen.dart';
import '../assistant/ai_chat_screen.dart';
import '../cards/card_statement_screen.dart';
import '../cards/credit_cards_screen.dart';
import '../expenses/expense_form_screen.dart';
import '../income/income_form_screen.dart';
import '../settings/budgets_screen.dart';

/// The financial snapshot.
///
/// Ordered by what the user opens the app to find out, most urgent first:
///
///   1. net position this month, with income and expenses beside it
///   2. quick actions, so the common task is one tap from launch
///   3. anything demanding attention (a budget being breached)
///   4. bank balances
///   5. recent transactions — the "is my last entry there?" check
///   6. trend and category analysis, which are browsing rather than checking
///
/// Sections that have no data render nothing at all rather than an empty
/// placeholder, so a cash-only user never scrolls past a bank card.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // Revisions last reflected in the rendered figures. The dashboard lives in
  // an IndexedStack and is never re-created, so it watches the transaction
  // providers and re-aggregates only when they actually change.
  int _seenExpenseRevision = 0;
  int _seenIncomeRevision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) return;

    await context.read<DashboardProvider>().load(
          userId: userId,
          categories: context.read<CategoryProvider>().categories,
          force: force,
        );

    if (!mounted) return;
    await context.read<BudgetProvider>().load(userId: userId, force: force);

    if (!mounted) return;
    await context
        .read<BankAccountProvider>()
        .load(userId: userId, force: force);

    if (!mounted) return;
    await context
        .read<CreditCardProvider>()
        .load(userId: userId, force: force);
  }

  @override
  Widget build(BuildContext context) {
    final DashboardProvider dashboard = context.watch<DashboardProvider>();
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final ThemeData theme = Theme.of(context);

    final int expenseRevision = context.watch<ExpenseProvider>().revision;
    final int incomeRevision = context.watch<IncomeProvider>().revision;
    if (expenseRevision != _seenExpenseRevision ||
        incomeRevision != _seenIncomeRevision) {
      _seenExpenseRevision = expenseRevision;
      _seenIncomeRevision = incomeRevision;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _invalidateAndReload());
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              Formatters.greeting().toUpperCase(),
              style: AppTypography.eyebrow(theme.textTheme),
            ),
            const SizedBox(height: 1),
            Text(
              settings.displayName,
              style: theme.textTheme.titleLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: <Widget>[
          _HeaderAction(
            tooltip: 'Ask the assistant',
            onPressed: _openAssistant,
            icon: Icons.auto_awesome_outlined,
          ),
          const SizedBox(width: AppSpacing.sm),
          _HeaderAction(
            tooltip: 'Bank accounts',
            onPressed: _openAccounts,
            icon: Icons.account_balance_outlined,
          ),
          // The bell hides itself before migration 010.
          if (SchemaCapabilities.notificationInbox) ...const <Widget>[
            SizedBox(width: AppSpacing.sm),
            NotificationBell(),
          ],
          const SizedBox(width: AppSpacing.page),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(force: true),
        child: _buildBody(dashboard, settings),
      ),
    );
  }

  Widget _buildBody(DashboardProvider dashboard, SettingsProvider settings) {
    if (dashboard.isInitialLoad) {
      return const _DashboardSkeleton();
    }

    if (dashboard.hasError && dashboard.data == null) {
      return ScrollableCentered(
        child: ErrorView(
          message: dashboard.errorMessage!,
          onRetry: () => _load(force: true),
        ),
      );
    }

    final DashboardData? data = dashboard.data;
    if (data == null) return const SizedBox.shrink();

    final String currency = settings.currency;
    final BankAccountProvider accounts = context.watch<BankAccountProvider>();
    final bool hasAccounts = accounts.available && accounts.hasAccounts;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.sm,
        AppSpacing.page,
        AppSpacing.bottomListPadding,
      ),
      children: <Widget>[
        // The charts lead. They are what the user opens a spending app to
        // look at, and putting them under four other sections meant scrolling
        // to reach the answer every single time.
        if (data.hasAnyData) ...<Widget>[
          AppFadeIn(child: _chartsSection(data, currency)),
          const SizedBox(height: AppSpacing.section),
        ],

        BalanceCard(
          income: data.totalIncome,
          expense: data.totalExpense,
          currency: currency,
          monthLabel: Formatters.shortMonth(data.month),
          bankTotal: hasAccounts ? accounts.totalBalance : null,
          bankTotalHidden: settings.balancesHidden,
          onToggleBankTotal: settings.toggleBalancesHidden,
        ),
        const SizedBox(height: AppSpacing.md),

        QuickActions(
          actions: <QuickAction>[
            QuickAction(
              label: 'Expense',
              icon: Icons.remove_circle_outline_rounded,
              tone: ToneColors.expense(context),
              onTap: _addExpense,
            ),
            QuickAction(
              label: 'Income',
              icon: Icons.add_circle_outline_rounded,
              tone: ToneColors.income(context),
              onTap: _addIncome,
            ),
            QuickAction(
              label: 'Accounts',
              icon: Icons.account_balance_outlined,
              tone: Theme.of(context).colorScheme.primary,
              onTap: _openAccounts,
            ),
            QuickAction(
              label: 'Budgets',
              icon: Icons.donut_small_outlined,
              tone: Theme.of(context).colorScheme.secondary,
              onTap: _openBudgets,
              // Overspending shows as a red dot here; the Budgets screen has
              // the detail.
              alert: _overspent() ? 'over budget' : null,
            ),
          ],
        ),

        if (!data.hasAnyData) ...<Widget>[
          const SizedBox(height: AppSpacing.section),
          _FirstRunCard(onAdd: _addExpense),
        ] else ...<Widget>[
          _budgetSection(currency),
          _accountsSection(accounts, currency),
          _cardsSection(context.watch<CreditCardProvider>(), currency),
          _recentSection(data, currency),
        ],
      ],
    );
  }

  // -----------------------------------------------------------------------
  // Sections
  // -----------------------------------------------------------------------

  /// Any budget (overall or a category's) spent past its limit this month.
  bool _overspent() {
    final BudgetProvider budgets = context.watch<BudgetProvider>();
    return <BudgetProgress?>[budgets.overall, ...budgets.categoryBudgets]
        .any((BudgetProgress? p) => p != null && p.isOver);
  }

  /// The overall budget, when one is set. Overspending is the red dot on the
  /// Budgets action; warnings and setting a budget live on the Budgets screen.
  Widget _budgetSection(String currency) {
    final BudgetProvider budgets = context.watch<BudgetProvider>();
    final BudgetProgress? overall = budgets.overall;
    if (overall == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: AppSpacing.section),
        SectionHeader(
          title: 'Budget',
          actionLabel: 'Manage',
          onAction: _openBudgets,
        ),
        BudgetCard(
          progress: overall,
          currency: currency,
          showAvatar: false,
          onTap: _openBudgets,
        ),
      ],
    );
  }

  /// Bank balances as a compact swipeable carousel.
  ///
  /// Stacking all accounts was fine with two, but three or more made the
  /// section taller than the chart above it. A carousel keeps the height
  /// fixed at one card regardless of account count; the dots signal more.
  Widget _accountsSection(BankAccountProvider accounts, String currency) {
    if (!accounts.available || !accounts.hasAccounts) {
      return const SizedBox.shrink();
    }

    final bool masked = context.watch<SettingsProvider>().balancesHidden;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: AppSpacing.section),
        SectionHeader(
          title: 'Accounts',
          actionLabel: 'View',
          onAction: _openAccounts,
        ),
        _SwipeCarousel(
          slides: <_Slide>[
            for (final BankAccountBalance balance in accounts.balances)
              _Slide(
                key: balance.account.id,
                label: '${balance.account.nickname} account',
                onTap: _openAccounts,
                row: AppListRow(
                  leading: AccountAvatar(account: balance.account),
                  title: balance.account.nickname,
                  subtitle: balance.account.bankLine,
                  trailing: MoneyText(
                    balance.currentBalance,
                    currency: currency,
                    obscured: masked,
                    tone: balance.isOverdrawn
                        ? AmountTone.negative
                        : AmountTone.neutral,
                    // The balance leads the card, in the figure face.
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  onTap: _openAccounts,
                ),
              ),
          ],
        ),
      ],
    );
  }

  /// Cards in use, and closed ones still being paid off — what is owed and
  /// whether a bill is due — one per slide, like the accounts.
  Widget _cardsSection(CreditCardProvider cards, String currency) {
    if (!cards.available || !cards.hasCards) return const SizedBox.shrink();
    final List<CardOverview> shown = cards.overviews
        .where((CardOverview o) => o.card.isActive || o.summary.outstanding > 0)
        .toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    final bool masked = context.watch<SettingsProvider>().balancesHidden;
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: AppSpacing.section),
        SectionHeader(
          title: 'Credit cards',
          actionLabel: 'View',
          onAction: _openCards,
        ),
        _SwipeCarousel(
          slides: <_Slide>[
            for (final CardOverview o in shown)
              _Slide(
                key: o.card.id,
                label: '${o.card.cardName} credit card',
                onTap: () => _openCard(o.card.id),
                row: AppListRow(
                  leading: const CardAvatar(),
                  title: o.card.cardName,
                  subtitle: dueSummaryText(
                    o.summary,
                    (double v) => Formatters.currency(v, currencyCode: currency),
                    Formatters.dayMonth,
                  ),
                  trailing: MoneyText(
                    o.summary.outstanding,
                    currency: currency,
                    obscured: masked,
                    style: theme.textTheme.headlineSmall,
                  ),
                  onTap: () => _openCard(o.card.id),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _recentSection(DashboardData data, String currency) {
    if (data.recentExpenses.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(height: AppSpacing.section),
          const SectionHeader(title: 'Recent'),
          SurfaceCard(
            child: EmptyState(
              compact: true,
              icon: Icons.receipt_long_outlined,
              title: 'Nothing this month',
              message: 'Expenses you add will show up here.',
              actionLabel: 'Add expense',
              onAction: _addExpense,
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: AppSpacing.section),
        SectionHeader(
          title: 'Recent',
          caption: Formatters.monthYear(data.month),
        ),
        CardList(
          children: <Widget>[
            for (int i = 0; i < data.recentExpenses.length; i++)
              ExpenseTile(
                expense: data.recentExpenses[i],
                currency: currency,
                onTap: () => _editExpense(i, data),
              ),
          ],
        ),
      ],
    );
  }

  /// The two charts, as one swipeable card.
  ///
  /// Stacked, these were two full-height cards the user had to scroll past to
  /// reach anything below them. Side by side in a pager they cost one card's
  /// height, and the pair reads as what it is: two views of the same month.
  ///
  /// "Where it went" leads because it answers the question people actually
  /// open a spending app with. The trend is context, and context goes second.
  ///
  /// Either page is dropped when it has no data, and a single remaining page
  /// simply renders without a pager.
  Widget _chartsSection(DashboardData data, String currency) {
    final bool hasTrend =
        data.trend.any((MonthlyPoint p) => p.expense > 0 || p.income > 0);
    final bool hasBreakdown = data.categoryBreakdown.isNotEmpty;
    if (!hasTrend && !hasBreakdown) return const SizedBox.shrink();

    // No leading gap: this is now the first thing under the app bar, and the
    // list's own top padding is the only space it needs.
    return CardCarousel(
      height: DashboardCharts.cardHeight,
      interval: DashboardCharts.carouselInterval,
      pages: <CarouselPage>[
        if (hasBreakdown)
          CarouselPage(
            title: 'Where it went',
            caption: Formatters.shortMonth(data.month),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                CategoryDonut(
                  breakdown: data.categoryBreakdown,
                  currency: currency,
                  size: DashboardCharts.donutSize,
                ),
                const SizedBox(height: AppSpacing.md),
                CategoryBreakdownList(
                  breakdown: data.categoryBreakdown,
                  currency: currency,
                  limit: 3,
                ),
              ],
            ),
          ),
        if (hasTrend)
          CarouselPage(
            title: 'Monthly spending',
            child: MonthlyTrendCard(
              points: data.trend,
              currency: currency,
              chartHeight: DashboardCharts.trendHeight,
            ),
          ),
      ],
    );
  }


  // -----------------------------------------------------------------------
  // Navigation
  // -----------------------------------------------------------------------

  Future<void> _openCards() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const CreditCardsScreen()),
    );
    if (mounted) _invalidateAndReload();
  }

  Future<void> _openCard(String cardId) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => CardStatementScreen(cardId: cardId)),
    );
    if (mounted) _invalidateAndReload();
  }

  Future<void> _openAccounts() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AccountsScreen()),
    );
    if (mounted) _invalidateAndReload();
  }

  /// The assistant can record an expense, an income or a transfer. When it
  /// has, every figure on this screen is stale — the same situation as
  /// coming back from a form, handled the same way.
  Future<void> _openAssistant() async {
    final AiChatProvider chat = context.read<AiChatProvider>();
    final int before = chat.dataRevision;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AiChatScreen()),
    );
    if (!mounted || chat.dataRevision == before) return;
    context.read<ExpenseProvider>().refresh();
    context.read<IncomeProvider>().refresh();
    context.read<BankAccountProvider>().invalidate();
    _invalidateAndReload();
  }

  Future<void> _editExpense(int index, DashboardData data) async {
    final bool? changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ExpenseFormScreen(expense: data.recentExpenses[index]),
      ),
    );
    if (changed == true) _invalidateAndReload();
  }

  Future<void> _addExpense() async {
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const ExpenseFormScreen()),
    );
    if (saved == true) _invalidateAndReload();
  }

  Future<void> _addIncome() async {
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const IncomeFormScreen()),
    );
    if (saved == true) _invalidateAndReload();
  }

  Future<void> _openBudgets() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const BudgetsScreen()),
    );
    if (mounted) _invalidateAndReload();
  }

  void _invalidateAndReload() {
    if (!mounted) return;
    context.read<DashboardProvider>().invalidate();
    context.read<BudgetProvider>().invalidate();
    context.read<CreditCardProvider>().invalidate();
    _load(force: true);
  }
}

/// A round glass button for the dashboard header.
///
/// The glass disc is painted only; the IconButton inside keeps the full 48px
/// hit target and the tooltip.
class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      radius: 20,
      child: SizedBox(
        width: 40,
        height: 40,
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          iconSize: AppSpacing.iconMd,
          padding: EdgeInsets.zero,
          icon: Icon(icon),
        ),
      ),
    );
  }
}

/// Shown when the account has no transactions at all.
class _FirstRunCard extends StatelessWidget {
  const _FirstRunCard({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      child: EmptyState(
        icon: Icons.north_east_rounded,
        title: 'Start tracking',
        message: 'Add your first expense and this screen fills in with '
            'totals, categories and trends.',
        actionLabel: 'Add your first expense',
        onAction: onAdd,
      ),
    );
  }
}

/// Keeps the page shape while the first load runs, instead of a bare spinner.
class _DashboardSkeleton extends StatelessWidget {
  const _DashboardSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.sm,
        AppSpacing.page,
        AppSpacing.bottomListPadding,
      ),
      children: const <Widget>[
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Skeleton(height: 11, width: 90),
              SizedBox(height: AppSpacing.md),
              Skeleton(height: 30, width: 170),
              SizedBox(height: AppSpacing.lg),
              Skeleton(
                height: 54,
                width: double.infinity,
                radius: AppSpacing.radiusMd,
              ),
            ],
          ),
        ),
        SizedBox(height: AppSpacing.md),
        Row(
          children: <Widget>[
            Expanded(child: Skeleton(height: 62, radius: AppSpacing.radiusMd)),
            SizedBox(width: AppSpacing.sm),
            Expanded(child: Skeleton(height: 62, radius: AppSpacing.radiusMd)),
            SizedBox(width: AppSpacing.sm),
            Expanded(child: Skeleton(height: 62, radius: AppSpacing.radiusMd)),
            SizedBox(width: AppSpacing.sm),
            Expanded(child: Skeleton(height: 62, radius: AppSpacing.radiusMd)),
          ],
        ),
        SizedBox(height: AppSpacing.section),
        Skeleton(height: 11, width: 70),
        SizedBox(height: AppSpacing.md),
        Skeleton(height: 148, radius: AppSpacing.radiusLg),
      ],
    );
  }
}

/// One row of a [_SwipeCarousel]: an account or a credit card.
class _Slide {
  const _Slide({
    required this.key,
    required this.label,
    required this.onTap,
    required this.row,
  });

  final String key;

  /// What a screen reader calls the slide.
  final String label;
  final VoidCallback onTap;
  final Widget row;
}

/// Compact horizontal pager: the accounts, and the credit cards, on Home.
///
/// One card fills the view at a time, and swiping reveals the next one.
/// No auto-advance — this is a reference section, not a slideshow. Dots
/// appear only when there is more than one to swipe through.
class _SwipeCarousel extends StatefulWidget {
  const _SwipeCarousel({required this.slides});

  final List<_Slide> slides;

  @override
  State<_SwipeCarousel> createState() => _SwipeCarouselState();
}

class _SwipeCarouselState extends State<_SwipeCarousel> {
  final PageController _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool multi = widget.slides.length > 1;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          // AppListRow min-height is 48; with avatar (34) + vertical padding
          // (rowPadY × 2) the natural height settles at about 66–72dp. A
          // fixed SizedBox lets the PageView stack without jumping as the
          // page turns, and keeps the section height independent of content.
          height: 72,
          child: PageView.builder(
            controller: _controller,
            itemCount: widget.slides.length,
            onPageChanged: multi
                ? (int i) => setState(() => _index = i)
                : null,
            itemBuilder: (BuildContext ctx, int i) {
              final _Slide slide = widget.slides[i];
              return Semantics(
                key: ValueKey<String>(slide.key),
                label: slide.label,
                child: SurfaceCard(
                  padding: EdgeInsets.zero,
                  onTap: slide.onTap,
                  child: slide.row,
                ),
              );
            },
          ),
        ),
        if (multi) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          _CarouselDots(count: widget.slides.length, index: _index),
        ],
      ],
    );
  }
}

/// Minimal dot indicators for a [_SwipeCarousel].
class _CarouselDots extends StatelessWidget {
  const _CarouselDots({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        for (int i = 0; i < count; i++) ...<Widget>[
          if (i != 0) const SizedBox(width: AppSpacing.xs),
          AnimatedContainer(
            duration: AppMotion.fast,
            curve: AppMotion.standard,
            width: i == index ? 14 : 5,
            height: 5,
            decoration: BoxDecoration(
              color: i == index
                  ? scheme.primary
                  : scheme.onSurfaceVariant.withOpacity(0.35),
              borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
            ),
          ),
        ],
      ],
    );
  }
}

/// Sizes for the two charts that share the dashboard carousel.
///
/// Public because the carousel viewport is a fixed height and the content has
/// to be proven to fit inside it — a test that hard-coded its own numbers
/// would pass while the real screen overflowed. The height is set by the
/// taller page: the donut plus three categories.
class DashboardCharts {
  const DashboardCharts._();

  static const double donutSize = 136;

  /// Fills what the card has left after the figure above it. Measured on a
  /// 360x720 device: the trend page was leaving roughly 70px of empty card
  /// below the axis labels, which is the gap this closes.
  static const double trendHeight = 244;
  static const double cardHeight = 326;

  /// Long enough to read a chart before it moves. Five seconds was not.
  static const Duration carouselInterval = Duration(seconds: 10);
}
