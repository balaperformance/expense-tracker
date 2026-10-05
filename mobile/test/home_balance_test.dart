// The Home hero's figures, from the same rows the web reads.
//
// test/fixtures/home_balance.json holds one month of data — last month's
// salary paid on its last day, a transfer, an ATM withdrawal into cash, a
// card bill, a card purchase, a purchase paid for someone else and a closed
// account. Its `expected` block is what the web's own code
// (`fetchAccountBalances` + `totalBalance`, and the dashboard's month totals)
// gives for those rows; the phone must give the same.
//
// Nothing here reaches the network: the repositories are fakes.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/analytics.dart';
import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/models/budget.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/income.dart';
import 'package:expense_tracker/providers/bank_account_provider.dart';
import 'package:expense_tracker/providers/dashboard_provider.dart';
import 'package:expense_tracker/repositories/bank_account_repository.dart';
import 'package:expense_tracker/repositories/budget_repository.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/income_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';
import 'package:expense_tracker/widgets/stat_tiles.dart';

final Map<String, dynamic> fixture =
    jsonDecode(File('test/fixtures/home_balance.json').readAsStringSync())
        as Map<String, dynamic>;

List<Map<String, dynamic>> rows(String key) =>
    (fixture[key] as List<dynamic>).cast<Map<String, dynamic>>();

double expected(String key) =>
    ((fixture['expected'] as Map<String, dynamic>)[key] as num).toDouble();

class Banks extends BankAccountRepository {
  Banks(super.client);

  @override
  Future<List<BankAccountBalance>> fetchWithBalances(String userId) async =>
      BankAccountRepository.balancesFrom(
        rows('accounts').map(BankAccount.fromMap).toList(),
        rows('movements'),
      );
}

class Expenses extends ExpenseRepository {
  Expenses(super.client);

  @override
  Future<Set<String>> fetchPaidForExpenseIds({required String userId}) async =>
      (fixture['paidFor'] as List<dynamic>).cast<String>().toSet();

  @override
  Future<List<Expense>> fetchForMonth({
    required String userId,
    required DateTime month,
  }) async =>
      rows('expenses').map(Expense.fromMap).toList();

  @override
  Future<Map<String, double>> fetchMonthlyTotals({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
    Set<String> exclude = const <String>{},
  }) async =>
      <String, double>{};
}

class Received extends IncomeRepository {
  Received(super.client);

  @override
  Future<List<Income>> fetchForMonth({
    required String userId,
    required DateTime month,
  }) async =>
      rows('income').map(Income.fromMap).toList();

  @override
  Future<Map<String, double>> fetchMonthlyTotals({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
  }) async =>
      <String, double>{};
}

class NoBudget extends BudgetRepository {
  NoBudget(super.client);

  @override
  Future<Budget?> fetchOverall({
    required String userId,
    required DateTime month,
  }) async =>
      null;
}

void main() {
  late SupabaseClient client;
  setUp(() {
    client = SupabaseClient('http://localhost:54321', 'test-anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    SchemaCapabilities.debugOverride(
      bankAccounts: true,
      cashAccount: true,
      treatments: true,
    );
  });

  test('the available balance is every bank and cash account, as on the web',
      () async {
    final BankAccountProvider accounts = BankAccountProvider(
      accounts: Banks(client),
      ledger: LedgerRepository(client),
    );
    await accounts.load(userId: 'u1');

    // Last month's salary is in it; a transfer and an ATM withdrawal only
    // move money between accounts; a card bill leaves the bank; a card
    // purchase does not touch it; a closed account still holds its money.
    expect(accounts.totalBalance, closeTo(expected('availableBalance'), 0.001));
    expect(accounts.cashAccount?.id, 'a-cash');
  });

  test('the month so far: income received and spending, never netted',
      () async {
    final DashboardProvider dashboard = DashboardProvider(
      expenses: Expenses(client),
      income: Received(client),
      budgets: NoBudget(client),
    );
    await dashboard.load(userId: 'u1', categories: const <ExpenseCategory>[]);

    final DashboardData data = dashboard.data!;
    expect(data.totalIncome, expected('incomeReceived'));
    // The card purchase counts; the purchase paid for someone else does not.
    expect(data.totalExpense, expected('spentThisMonth'));
  });

  testWidgets('the hero shows those figures', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(
          child: BalanceCard(
            income: expected('incomeReceived'),
            expense: expected('spentThisMonth'),
            currency: 'INR',
            monthLabel: 'Oct',
            bankTotal: expected('availableBalance'),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('AVAILABLE BALANCE'), findsOneWidget);
    expect(find.text('₹1,75,199.50'), findsOneWidget);
    expect(find.text('Income received'), findsOneWidget);
    expect(find.text('Spent this month'), findsOneWidget);
  });
}
