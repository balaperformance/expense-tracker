import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../providers/budget_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/expense_provider.dart';
import '../../providers/income_provider.dart';
import '../../providers/reports_provider.dart';
import '../../widgets/common/glass_nav_bar.dart';
import '../../widgets/common/app_buttons.dart';
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
