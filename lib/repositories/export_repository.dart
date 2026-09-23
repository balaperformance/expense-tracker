/// Gathers the raw data one export needs.
///
/// Deliberately thin. It owns no arithmetic and no formatting — it reuses the
/// existing repositories, and the totals, percentages and running balances are
/// all computed by the same pure code the screens already use. That is what
/// keeps an exported figure identical to the one on screen: there is only one
/// implementation of each.
library;

import '../core/constants/app_constants.dart';
import '../core/errors/app_exception.dart';
import '../models/bank_account.dart';
import '../models/expense.dart';
import '../models/income.dart';
import '../models/ledger_entry.dart';
import '../services/export/export_models.dart';
import 'expense_repository.dart';
import 'income_repository.dart';
import 'ledger_repository.dart';

/// Raw rows for one export request, before any aggregation.
class ExportSource {
  const ExportSource({
    this.expenses = const <Expense>[],
    this.income = const <Income>[],
    this.statement,
    this.account,
    this.truncated = false,
  });

  final List<Expense> expenses;
  final List<Income> income;

  /// Set for a bank statement export only.
  final AccountStatement? statement;
  final BankAccount? account;

  /// True when a query came back at its row cap, so the report is a partial
  /// view. Surfaced to the user rather than hidden.
  final bool truncated;

  bool get isEmpty =>
      expenses.isEmpty &&
      income.isEmpty &&
      (statement == null || statement!.isEmpty);
}

class ExportRepository {
  const ExportRepository({
    required ExpenseRepository expenses,
    required IncomeRepository income,
    required LedgerRepository ledger,
  })  : _expenses = expenses,
        _income = income,
        _ledger = ledger;

  final ExpenseRepository _expenses;
  final IncomeRepository _income;
  final LedgerRepository _ledger;

  /// Fetches exactly what [request] needs and nothing more.
  Future<ExportSource> load({
    required String userId,
    required ExportRequest request,
    BankAccount? account,
  }) async {
    switch (request.type) {
      case ExportReportType.bankStatement:
        // The chosen account can disappear between the choice and the load —
        // deleted on another device, or the whole list reloaded. Saying so
        // beats the generic failure a null dereference would produce.
        if (account == null) {
          throw const AppException(
            'That account is no longer available. Choose another one.',
          );
        }
        return _bankStatement(
          userId: userId,
          request: request,
          account: account,
        );

      case ExportReportType.expenses:
      case ExportReportType.spendingReport:
      case ExportReportType.categoryReport:
        final List<Expense> rows = await _expenses.fetchRange(
          userId: userId,
          from: request.range.start,
          toExclusive: request.range.endExclusive,
          categoryIds: request.categoryIds,
        );
        return ExportSource(
          expenses: rows,
          truncated: _atCap(rows.length),
        );

      case ExportReportType.income:
        final List<Income> rows = await _income.fetchRange(
          userId: userId,
          from: request.range.start,
          toExclusive: request.range.endExclusive,
        );
        return ExportSource(income: rows, truncated: _atCap(rows.length));

      case ExportReportType.incomeVsExpense:
        final List<Object> results = await Future.wait(<Future<Object>>[
          _expenses.fetchRange(
            userId: userId,
            from: request.range.start,
            toExclusive: request.range.endExclusive,
          ),
          _income.fetchRange(
            userId: userId,
            from: request.range.start,
            toExclusive: request.range.endExclusive,
          ),
        ]);
        final List<Expense> spent = results[0] as List<Expense>;
        final List<Income> received = results[1] as List<Income>;
        return ExportSource(
          expenses: spent,
          income: received,
          truncated: _atCap(spent.length) || _atCap(received.length),
        );
    }
  }

  /// A statement export is built exactly the way the screen builds one: the
  /// period's movements, plus everything before the period collapsed into a
  /// brought-forward figure, fed through the same [buildStatement].
  Future<ExportSource> _bankStatement({
    required String userId,
    required ExportRequest request,
    required BankAccount account,
  }) async {
    final List<Object> results = await Future.wait(<Future<Object>>[
      _ledger.fetchForAccount(
        userId: userId,
        accountId: account.id,
        from: request.range.start,
        toExclusive: request.range.endExclusive,
      ),
      _ledger.netBefore(
        userId: userId,
        accountId: account.id,
        before: request.range.start,
      ),
    ]);

    final List<LedgerEntry> entries = results[0] as List<LedgerEntry>;
    final double priorNet = results[1] as double;

    return ExportSource(
      account: account,
      statement: buildStatement(
        openingBalance: account.openingBalance + priorNet,
        entries: entries,
      ),
    );
  }

  /// A page that comes back exactly full is the signal that more was left
  /// behind — PostgREST gives no total count without asking for one.
  static bool _atCap(int rows) => rows >= _rowCap;

  static const int _rowCap = AppConstants.exportRowLimit;
}
