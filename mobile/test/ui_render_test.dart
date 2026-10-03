// Rendering tests for the design system.
//
// These exist to catch the failures a redesign actually produces: RenderFlex
// overflows, unbounded-constraint errors and dark-mode regressions. Flutter
// reports an overflow as a thrown FlutterError during layout, so a widget
// that overflows fails these tests simply by being pumped.
//
// Every component is rendered:
//   * in light and dark, because the two themes are authored separately and
//     a colour that only exists in one of them is a real bug,
//   * at 320, 360 and 411 logical pixels wide — 320 is narrower than any
//     phone the app targets, so passing there means the layouts have genuine
//     headroom rather than fitting one device exactly,
//   * with deliberately hostile data: 40-character merchant names and
//     nine-figure amounts, which is where fixed-width rows break.

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/analytics.dart';
import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/models/budget.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/income.dart';
import 'package:expense_tracker/models/ledger_entry.dart';
import 'package:expense_tracker/widgets/budget_progress_tile.dart';
import 'package:expense_tracker/widgets/category_avatar.dart';
import 'package:expense_tracker/widgets/charts/category_breakdown.dart';
import 'package:expense_tracker/widgets/charts/monthly_trend_chart.dart';
import 'package:expense_tracker/widgets/common/app_fields.dart';
import 'package:expense_tracker/widgets/common/app_buttons.dart';
import 'package:expense_tracker/widgets/common/state_views.dart';
import 'package:expense_tracker/widgets/common/surface_card.dart';
import 'package:expense_tracker/widgets/stat_tiles.dart';
import 'package:expense_tracker/widgets/transaction_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widths worth proving. 320 is below every target device.
const List<double> _widths = <double>[320, 360, 411];

const String _longName =
    'Extraordinarily Long Merchant Name Pvt Ltd';

/// Renders [child] in both themes at every width and fails on any layout
/// exception, including an overflow.
Future<void> _rendersEverywhere(
  WidgetTester tester,
  Widget child, {
  bool scrollable = true,

  /// False for anything containing a deliberately endless animation — the
  /// skeleton shimmer, a spinner. `pumpAndSettle` waits for the tree to go
  /// quiet, which those never do, so they are pumped a fixed number of
  /// frames instead. Layout is still fully exercised.
  bool settle = true,
}) async {
  for (final Brightness brightness in Brightness.values) {
    for (final double width in _widths) {
      tester.view.physicalSize = Size(width * 3, 780 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
          home: Scaffold(
            body: scrollable
                ? SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: child,
                    ),
                  )
                : Padding(padding: const EdgeInsets.all(16), child: child),
          ),
        ),
      );
      if (settle) {
        await tester.pumpAndSettle(const Duration(milliseconds: 700));
      } else {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      expect(
        tester.takeException(),
        isNull,
        reason: 'failed at ${width}px in $brightness',
      );
    }
  }
}

ExpenseCategory _category() => const ExpenseCategory(
      id: 'c1',
      userId: 'u1',
      name: 'Food & Dining Out',
      icon: 'restaurant',
      color: '#EF6C4D',
    );

Expense _expense({double amount = 123456789.99}) => Expense(
      id: 'e1',
      userId: 'u1',
      amount: amount,
      expenseDate: DateTime(2026, 9, 21),
      categoryId: 'c1',
      merchant: _longName,
      category: _category(),
    );

Income _income() => Income(
      id: 'i1',
      userId: 'u1',
      amount: 987654321.50,
      incomeDate: DateTime(2026, 9, 21),
      source: _longName,
    );

BankAccount _account() => const BankAccount(
      id: 'a1',
      userId: 'u1',
      bankName: 'Hypothetical National Banking Corporation',
      nickname: 'Primary Salary And Savings Account',
      last4: '4821',
      openingBalance: 10000,
    );

BudgetProgress _budget({double spent = 98765.43, double limit = 100000}) {
  return BudgetProgress(
    budget: Budget(
      id: 'b1',
      userId: 'u1',
      amount: limit,
      month: DateTime(2026, 9, 1),
      category: _category(),
      categoryId: 'c1',
    ),
    spent: spent,
  );
}

void main() {
  group('money and rows', () {
    testWidgets('MoneyText renders every tone', (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        const Column(
          children: <Widget>[
            MoneyText(1234.5, currency: 'INR', tone: AmountTone.positive),
            MoneyText(-1234.5, currency: 'INR', tone: AmountTone.negative),
            MoneyText(1234.5, currency: 'INR', tone: AmountTone.transfer),
            MoneyText(1234.5, currency: 'INR', tone: AmountTone.warning),
            MoneyText(-1234.5, currency: 'INR', tone: AmountTone.auto,
                signed: true),
            MoneyText(999999999.99, currency: 'INR', fit: true),
          ],
        ),
      );
    });

    testWidgets('expense row survives a long name and a huge amount',
        (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        CardList(
          children: <Widget>[
            ExpenseTile(
              expense: _expense(),
              currency: 'INR',
              sourceLabel: 'Primary Salary Account',
            ),
          ],
        ),
      );
    });

    testWidgets('income row survives the same', (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        CardList(
          children: <Widget>[
            IncomeTile(
              income: _income(),
              currency: 'INR',
              destinationLabel: 'Primary Salary Account',
            ),
          ],
        ),
      );
    });

    testWidgets('statement row with a running balance',
        (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        const CardList(
          children: <Widget>[
            TransactionRow(
              leading: TransferAvatar(),
              title: 'Transfer to $_longName',
              amount: -123456.78,
              currency: 'INR',
              tone: AmountTone.transfer,
              meta: <String>['Money Transfer', 'to Savings Account'],
              trailingBelow: '₹9.9L',
            ),
          ],
        ),
      );
    });

    testWidgets('day header', (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        const DayHeader(
          label: 'Yesterday',
          total: 123456789,
          currency: 'INR',
          isFirst: true,
        ),
      );
    });
  });

  group('dashboard components', () {
    testWidgets('balance card with a nine-figure net',
        (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        const BalanceCard(
          income: 987654321,
          expense: 123456789,
          currency: 'INR',
          monthLabel: 'Sep',
          bankTotal: 555555555,
        ),
      );
    });

    testWidgets('balance card with a negative net', (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        const BalanceCard(
          income: 1000,
          expense: 95000,
          currency: 'INR',
          monthLabel: 'Sep',
        ),
      );
    });

    testWidgets('four quick actions fit the narrowest phone',
        (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        QuickActions(
          actions: <QuickAction>[
            QuickAction(
                label: 'Expense', icon: Icons.remove, onTap: () {}),
            QuickAction(label: 'Income', icon: Icons.add, onTap: () {}),
            QuickAction(
                label: 'Accounts', icon: Icons.account_balance, onTap: () {}),
            QuickAction(
                label: 'Budgets', icon: Icons.donut_small, onTap: () {}),
          ],
        ),
      );
    });

    testWidgets('three stat tiles in a row', (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        const Row(
          children: <Widget>[
            Expanded(
              child: StatTile(
                label: 'Income',
                amount: 987654321,
                currency: 'INR',
                icon: Icons.south_west_rounded,
                tone: Colors.green,
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: StatTile(
                label: 'Expenses',
                amount: 123456789,
                currency: 'INR',
                icon: Icons.north_east_rounded,
                tone: Colors.red,
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: StatTile(
                label: 'Avg spend',
                amount: 4567.89,
                currency: 'INR',
                icon: Icons.tag_rounded,
                tone: Colors.indigo,
              ),
            ),
          ],
        ),
      );
    });

    testWidgets('month stepper', (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        MonthStepper(
          month: DateTime(2026, 9, 1),
          onPrevious: () {},
          onNext: () {},
          trailing: TextButton(onPressed: () {}, child: const Text('All')),
        ),
      );
    });
  });

  group('budgets', () {
    testWidgets('on track, approaching and over all render',
        (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        Column(
          children: <Widget>[
            BudgetCard(progress: _budget(spent: 1000), currency: 'INR'),
            const SizedBox(height: 8),
            BudgetCard(progress: _budget(spent: 85000), currency: 'INR'),
            const SizedBox(height: 8),
            BudgetCard(progress: _budget(spent: 150000), currency: 'INR'),
          ],
        ),
      );
    });

    testWidgets('alert banner', (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        BudgetAlertBanner(
          alerts: <BudgetProgress>[_budget(spent: 150000)],
          currency: 'INR',
        ),
      );
    });
  });

  group('cards, rows and badges', () {
    testWidgets('list row with every slot filled', (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        CardList(
          children: <Widget>[
            AppListRow(
              leading: const BankAvatar(initial: 'H'),
              title: _longName,
              subtitle: 'Hypothetical National Banking Corporation •••• 4821',
              trailing: const MoneyText(123456789, currency: 'INR'),
              onTap: () {},
            ),
            AppListRow(
              leading: const IconWell(
                icon: Icons.category_outlined,
                tone: Colors.indigo,
              ),
              title: 'With a chevron',
              subtitle: 'And a subtitle',
              showChevron: true,
              onTap: () {},
            ),
          ],
        ),
      );
    });

    testWidgets('section header, badge and notice',
        (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        Column(
          children: <Widget>[
            SectionHeader(
              title: 'Accounts',
              actionLabel: 'View all',
              onAction: () {},
            ),
            const SectionHeader(title: 'Recent', caption: 'September 2026'),
            const Row(
              children: <Widget>[
                AppBadge(label: 'Cash'),
                SizedBox(width: 8),
                AppBadge(label: 'Over', icon: Icons.warning_amber_rounded),
              ],
            ),
            const SizedBox(height: 8),
            const AppNotice(
              message: 'A reasonably long explanatory notice that has to wrap '
                  'onto several lines without overflowing its container.',
            ),
          ],
        ),
      );
    });

    testWidgets('avatars', (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        const Row(
          children: <Widget>[
            CategoryAvatar(icon: 'restaurant', color: '#EF6C4D'),
            SizedBox(width: 8),
            IncomeAvatar(),
            SizedBox(width: 8),
            TransferAvatar(),
            SizedBox(width: 8),
            LedgerAvatar(isCredit: true),
            SizedBox(width: 8),
            BankAvatar(initial: 'H'),
          ],
        ),
      );
    });
  });

  group('state views', () {
    testWidgets('loader, empty, error and inline error',
        (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        Column(
          children: <Widget>[
            const SizedBox(height: 90, child: AppLoader(message: 'Loading…')),
            EmptyState(
              icon: Icons.receipt_long_outlined,
              title: 'No expenses yet',
              message: 'Add your first expense to start seeing it here.',
              actionLabel: 'Add expense',
              onAction: () {},
            ),
            const EmptyState(
              compact: true,
              icon: Icons.search_off_rounded,
              title: 'No matches',
              message: 'Nothing matches your search and filters.',
            ),
            ErrorView(message: 'Could not reach the database.', onRetry: () {}),
            const InlineError(
              message: 'Choose a category for this expense before saving it.',
            ),
          ],
        ),
        settle: false,
      );
    });

    testWidgets('list skeleton', (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        const SizedBox(height: 420, child: ListSkeleton()),
        scrollable: false,
        settle: false,
      );
    });
  });

  group('form fields', () {
    testWidgets('amount, select, date, search and chips',
        (WidgetTester tester) async {
      final TextEditingController amount =
          TextEditingController(text: '123456.78');
      final TextEditingController search = TextEditingController();
      addTearDown(amount.dispose);
      addTearDown(search.dispose);

      await _rendersEverywhere(
        tester,
        Form(
          child: Column(
            children: <Widget>[
              AmountField(
                controller: amount,
                symbol: '₹',
                autofocus: false,
              ),
              const SizedBox(height: 12),
              const FieldLabel('Category', isRequired: true, hint: 'Pick one'),
              SelectField(
                value: _longName,
                icon: Icons.calendar_today_rounded,
                onTap: () {},
              ),
              const SizedBox(height: 12),
              DateField(date: DateTime(2026, 9, 21), onChanged: (_) {}),
              const SizedBox(height: 12),
              SearchField(
                controller: search,
                onChanged: (_) {},
                hintText: 'Search merchant, note or description',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  AppChoiceChip(
                    label: 'Cash',
                    icon: Icons.payments_outlined,
                    selected: true,
                    onSelected: () {},
                  ),
                  AppChoiceChip(
                    label: _longName,
                    selected: false,
                    onSelected: () {},
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    });

    testWidgets('submit button in both states', (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        Column(
          children: <Widget>[
            AppButton.submit(label: 'Add expense', onPressed: () {}),
            const SizedBox(height: 8),
            AppButton.submit(
              label: 'Add expense',
              busyLabel: 'Saving…',
              busy: true,
              onPressed: () {},
            ),
            const SizedBox(height: 8),
            AppButton(
              label: 'Secondary',
              variant: AppButtonVariant.secondary,
              onPressed: () {},
            ),
            const SizedBox(height: 8),
            AppButton(
              label: 'Tonal with icon',
              icon: Icons.swap_horiz_rounded,
              variant: AppButtonVariant.tonal,
              onPressed: () {},
            ),
            const SizedBox(height: 8),
            AppButton(
              label: 'Small',
              size: AppButtonSize.small,
              onPressed: () {},
            ),
            const SizedBox(height: 8),
            AppButton(
              label: 'Danger',
              variant: AppButtonVariant.danger,
              onPressed: () {},
            ),
            const SizedBox(height: 8),
            AppButtonRow(
              confirmLabel: 'Delete',
              confirmVariant: AppButtonVariant.danger,
              onCancel: () {},
              onConfirm: () {},
            ),
          ],
        ),
        settle: false,
      );
    });
  });

  group('charts', () {
    List<CategorySpend> breakdown() => <CategorySpend>[
          const CategorySpend(
            categoryId: 'c1',
            name: 'Food & Dining Out With A Long Name',
            color: '#EF6C4D',
            icon: 'restaurant',
            total: 123456,
            transactionCount: 12,
          ),
          const CategorySpend(
            categoryId: 'c2',
            name: 'Transport',
            color: '#3B82F6',
            icon: 'directions_bus',
            total: 45678,
            transactionCount: 8,
          ),
          const CategorySpend(
            categoryId: 'c3',
            name: 'Bills',
            color: '#A855F7',
            icon: 'receipt_long',
            total: 9876,
            transactionCount: 3,
          ),
        ];

    testWidgets('donut and breakdown list', (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        Column(
          children: <Widget>[
            CategoryDonut(breakdown: breakdown(), currency: 'INR'),
            const SizedBox(height: 16),
            CategoryBreakdownList(breakdown: breakdown(), currency: 'INR'),
          ],
        ),
      );
    });

    testWidgets('monthly trend, expenses only and with income',
        (WidgetTester tester) async {
      final List<MonthlyPoint> points = <MonthlyPoint>[
        for (int i = 0; i < 6; i++)
          MonthlyPoint(
            month: DateTime(2026, i + 4, 1),
            expense: 10000.0 * (i + 1),
            income: 25000.0 * (i + 1),
          ),
      ];

      await _rendersEverywhere(
        tester,
        Column(
          children: <Widget>[
            MonthlyTrendChart(points: points, currency: 'INR'),
            const SizedBox(height: 16),
            MonthlyTrendChart(
              points: points,
              currency: 'INR',
              showIncome: true,
            ),
            const SizedBox(height: 16),
            const ChartLegend(
              entries: <({Color color, String label})>[
                (label: 'Expenses', color: Colors.red),
                (label: 'Income', color: Colors.green),
              ],
            ),
          ],
        ),
      );
    });

    testWidgets('an all-zero trend does not divide by zero',
        (WidgetTester tester) async {
      await _rendersEverywhere(
        tester,
        MonthlyTrendChart(
          points: <MonthlyPoint>[
            for (int i = 0; i < 6; i++)
              MonthlyPoint(
                month: DateTime(2026, i + 4, 1),
                expense: 0,
                income: 0,
              ),
          ],
          currency: 'INR',
        ),
      );
    });
  });

  group('statement rows', () {
    testWidgets('credit, debit and transfer legs render together',
        (WidgetTester tester) async {
      LedgerEntry entry(LedgerDirection d, {String? group}) => LedgerEntry(
            id: 'l${d.index}${group ?? ''}',
            userId: 'u1',
            accountId: 'a1',
            direction: d,
            amount: 12345.67,
            txnDate: DateTime(2026, 9, 21),
            description: _longName,
            transferGroupId: group,
          );

      await _rendersEverywhere(
        tester,
        CardList(
          children: <Widget>[
            TransactionRow(
              leading: const LedgerAvatar(isCredit: true),
              title: entry(LedgerDirection.credit).title,
              amount: 12345.67,
              currency: 'INR',
              tone: AmountTone.positive,
              trailingBelow: '₹1.2L',
            ),
            TransactionRow(
              leading: const LedgerAvatar(isCredit: false),
              title: entry(LedgerDirection.debit).title,
              amount: -12345.67,
              currency: 'INR',
              tone: AmountTone.negative,
              trailingBelow: '₹1.1L',
            ),
            TransactionRow(
              leading: const TransferAvatar(),
              title: entry(LedgerDirection.debit, group: 'g1').title,
              amount: -12345.67,
              currency: 'INR',
              tone: AmountTone.transfer,
              meta: const <String>['Money Transfer', 'to Savings'],
              trailingBelow: '₹1.0L',
            ),
          ],
        ),
      );
    });
  });

  group('account card', () {
    testWidgets('long bank and nickname', (WidgetTester tester) async {
      final BankAccount account = _account();
      await _rendersEverywhere(
        tester,
        CardList(
          children: <Widget>[
            AppListRow(
              leading: BankAvatar(initial: account.initial),
              title: account.nickname,
              subtitle: '${account.bankName} •••• ${account.last4}',
              trailing: const MoneyText(999999999.99, currency: 'INR'),
              onTap: () {},
            ),
          ],
        ),
      );
    });
  });
}
