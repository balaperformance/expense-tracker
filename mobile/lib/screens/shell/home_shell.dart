import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/bank_account.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/budget_provider.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/expense_provider.dart';
import '../../providers/income_provider.dart';
import '../../providers/notification_provider.dart';
import '../../providers/reports_provider.dart';
import '../../services/push/notification_route.dart';
import '../../services/schema_capabilities.dart';
import '../../widgets/common/glass_nav_bar.dart';
import '../../widgets/common/app_buttons.dart';
import '../accounts/account_statement_screen.dart';
import '../accounts/accounts_screen.dart';
import '../cards/card_statement_screen.dart';
import '../cards/credit_cards_screen.dart';
import '../dashboard/dashboard_screen.dart';
import '../expenses/expense_form_screen.dart';
import '../expenses/expenses_screen.dart';
import '../income/income_screen.dart';
import '../reports/reports_screen.dart';
import '../settings/settings_screen.dart';

/// Bottom-tab shell.
///
/// Five destinations, which is the most a bottom bar can carry before the
/// labels stop being readable — Bank accounts and Budgets are reached from
/// the Dashboard and Settings rather than taking a sixth slot.
///
/// Tabs live in an [IndexedStack] so each keeps its scroll position and
/// cached data when the user switches away and back.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const int _dashboard = 0;
  static const int _expenses = 1;
  static const int _reports = 3;

  NotificationProvider? _notifications;
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A tapped push notification opens the page it names — whether the app
      // was closed (the launch path), in the background or open (the stream).
      final NotificationProvider notifications =
          context.read<NotificationProvider>();
      _notifications = notifications..addListener(_onNotification);
      notifications.collectLaunchPath();
      _onNotification();
    });
    // Coming back to the app renews an enabled phone's registration (its
    // token and time zone), at most once an hour.
    _lifecycle = AppLifecycleListener(
      onResume: () => _notifications?.sync(),
    );
  }

  @override
  void dispose() {
    _notifications?.removeListener(_onNotification);
    _lifecycle?.dispose();
    super.dispose();
  }

  void _onNotification() {
    final String? path = _notifications?.takePendingPath();
    if (path != null && mounted) _openFromNotification(path);
  }

  /// The page a notification names, on top of the home tabs.
  Future<void> _openFromNotification(String path) async {
    final NotificationRoute route = NotificationRoute.parse(path);
    final NavigatorState navigator = Navigator.of(context);
    navigator.popUntil((Route<dynamic> r) => r.isFirst);
    switch (route.destination) {
      case NotificationDestination.home:
        setState(() => _index = _dashboard);
      case NotificationDestination.reports:
        setState(() => _index = _reports);
      case NotificationDestination.addExpense:
        await _addExpense();
      case NotificationDestination.account:
        final String? userId = context.read<AuthProvider>().userId;
        final BankAccountProvider accounts = context.read<BankAccountProvider>();
        if (userId != null && accounts.accounts.isEmpty) {
          await accounts.load(userId: userId);
        }
        if (!mounted) return;
        BankAccount? account;
        for (final BankAccount a in accounts.accounts) {
          if (a.id == route.id) account = a;
        }
        final BankAccount? found = account;
        await navigator.push(MaterialPageRoute<void>(
          builder: (_) => found != null
              ? AccountStatementScreen(account: found)
              : const AccountsScreen(),
        ));
      case NotificationDestination.card:
        await navigator.push(MaterialPageRoute<void>(
          builder: (_) => SchemaCapabilities.creditCards && route.id != null
              ? CardStatementScreen(cardId: route.id!)
              : const CreditCardsScreen(),
        ));
    }
  }

  /// One outline family throughout, so five icons read as one set rather
  /// than five separate metaphors.
  static const List<GlassNavItem> _destinations = <GlassNavItem>[
    GlassNavItem(
      label: 'Home',
      icon: Icons.home_outlined,
      activeIcon: Icons.home_rounded,
    ),
    GlassNavItem(
      label: 'Expenses',
      icon: Icons.receipt_long_outlined,
      activeIcon: Icons.receipt_long_rounded,
    ),
    GlassNavItem(
      label: 'Income',
      icon: Icons.savings_outlined,
      activeIcon: Icons.savings_rounded,
    ),
    GlassNavItem(
      label: 'Reports',
      icon: Icons.bar_chart_rounded,
      activeIcon: Icons.bar_chart_rounded,
    ),
    GlassNavItem(
      label: 'Settings',
      icon: Icons.settings_outlined,
      activeIcon: Icons.settings_rounded,
    ),
  ];

  /// Add Expense is offered only where it is the obvious next action.
  ///
  /// Income and Budgets own their own primary action, and showing the shell
  /// FAB there as well stacked two floating buttons on top of each other.
  /// Settings and Reports have no primary action at all.
  bool get _showFab => _index == _dashboard || _index == _expenses;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The body runs to the bottom of the screen so the list scrolls under
      // the translucent bar. Every tab already reserves
      // [AppSpacing.bottomListPadding] at the end of its scroll, so nothing
      // is ever stranded behind it.
      extendBody: true,
      body: IndexedStack(
        index: _index,
        children: <Widget>[
          for (int i = 0; i < _tabs.length; i++)
            // An IndexedStack keeps every tab alive, which is what preserves
            // scroll position — but it also leaves their animations running
            // unwatched. Muting the ticker for hidden tabs stops the loading
            // shimmer and the dashboard carousel from burning frames behind
            // a tab nobody is looking at.
            TickerMode(enabled: i == _index, child: _tabs[i]),
        ],
      ),
      floatingActionButton: _showFab
          ? AppFab(
              heroTag: 'shell_add_fab',
              onPressed: _addExpense,
              label: 'Add',
            )
          : null,
      bottomNavigationBar: GlassNavBar(
        items: _destinations,
        index: _index,
        onSelected: (int next) => setState(() => _index = next),
      ),
    );
  }

  static const List<Widget> _tabs = <Widget>[
    DashboardScreen(),
    ExpensesScreen(),
    IncomeScreen(),
    ReportsScreen(),
    SettingsScreen(),
  ];

  Future<void> _addExpense() async {
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const ExpenseFormScreen()),
    );

    if (saved == true && mounted) _invalidateDerivedData();
  }

  /// A new expense changes dashboard totals, budget progress and reports.
  /// Marking them stale is cheaper than refetching tabs the user may not open.
  void _invalidateDerivedData() {
    context.read<DashboardProvider>().invalidate();
    context.read<BudgetProvider>().invalidate();
    context.read<ReportsProvider>().invalidate();
    context.read<CreditCardProvider>().invalidate();
  }
}

/// Keeps user-scoped providers pointed at the current session.
///
/// Placed here (not in each screen) so attaching happens once, and lazily —
/// a tab that is never opened never issues a query.
class SessionScope {
  const SessionScope._();

  static void attachExpenses(BuildContext context) {
    final String? userId = context.read<AuthProvider>().userId;
    if (userId != null) context.read<ExpenseProvider>().attachUser(userId);
  }


  static void attachIncome(BuildContext context) {
    final String? userId = context.read<AuthProvider>().userId;
    if (userId != null) context.read<IncomeProvider>().attachUser(userId);
  }
}
