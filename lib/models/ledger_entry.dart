import '../core/utils/date_utils.dart';
import 'expense_category.dart';
import 'money_transfer.dart';

/// Direction of an account movement.
enum LedgerDirection { debit, credit }

extension LedgerDirectionWire on LedgerDirection {
  String get wire => this == LedgerDirection.debit ? 'debit' : 'credit';

  String get label => this == LedgerDirection.debit ? 'Debit' : 'Credit';

  static LedgerDirection parse(String? value) =>
      value == 'credit' ? LedgerDirection.credit : LedgerDirection.debit;
}

/// Filter for a statement view.
enum StatementTypeFilter { all, debitsOnly, creditsOnly }

extension StatementTypeFilterLabel on StatementTypeFilter {
  String get label => switch (this) {
        StatementTypeFilter.all => 'All',
        StatementTypeFilter.debitsOnly => 'Debits',
        StatementTypeFilter.creditsOnly => 'Credits',
      };

  bool matches(LedgerDirection direction) => switch (this) {
        StatementTypeFilter.all => true,
        StatementTypeFilter.debitsOnly => direction == LedgerDirection.debit,
        StatementTypeFilter.creditsOnly => direction == LedgerDirection.credit,
      };
}

/// Row of `public.account_transactions` — one movement on one account.
class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.userId,
    required this.accountId,
    required this.direction,
    required this.amount,
    required this.txnDate,
    this.description,
    this.categoryId,
    this.expenseId,
    this.incomeId,
    this.transferGroupId,
    this.counterpartyAccountId,
    this.createdAt,
    this.category,
  });

  final String id;
  final String userId;
  final String accountId;
  final LedgerDirection direction;

  /// Always positive. Direction carries the sign.
  final double amount;

  final DateTime txnDate;
  final String? description;
  final String? categoryId;

  /// Set when this movement was produced by an expense.
  final String? expenseId;

  /// Set when produced by an income entry.
  final String? incomeId;

  /// Set when this movement is one leg of a transfer between two of the
  /// user's own accounts. Both legs share the same value, which is how the
  /// pair is found, shown and deleted together.
  final String? transferGroupId;

  /// The account on the other side of a transfer.
  ///
  /// Held as an id rather than frozen text so a statement always renders the
  /// counterparty's current name. Null once that account is deleted, which
  /// leaves this movement intact and the balance unchanged.
  final String? counterpartyAccountId;

  final DateTime? createdAt;
  final ExpenseCategory? category;

  bool get isDebit => direction == LedgerDirection.debit;
  bool get isCredit => direction == LedgerDirection.credit;

  /// True for both legs of a self-account transfer.
  bool get isTransfer => transferGroupId != null;

  /// True when this movement belongs to an expense or income record and so
  /// must be edited or deleted there rather than on the statement.
  bool get isDocumentBacked => expenseId != null || incomeId != null;

  /// What the statement prints where a category would go.
  ///
  /// A transfer has no real category — it is not spending — so the label is
  /// derived here instead of being stored as a row in `categories`.
  String? get categoryLabel =>
      isTransfer ? moneyTransferLabel : category?.name;

  /// Signed contribution to a balance.
  double get signedAmount => isDebit ? -amount : amount;

  String get title {
    final String? text = description?.trim();
    if (text != null && text.isNotEmpty) return text;
    if (isTransfer) return moneyTransferLabel;
    if (expenseId != null) return 'Expense';
    if (incomeId != null) return 'Income';
    return isCredit ? 'Deposit' : 'Withdrawal';
  }

  factory LedgerEntry.fromMap(Map<String, dynamic> map) {
    final Object? categoryJoin = map['categories'];
    return LedgerEntry(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      accountId: map['account_id'] as String,
      direction: LedgerDirectionWire.parse(map['direction'] as String?),
      amount: (map['amount'] as num?)?.toDouble() ?? 0,
      txnDate: AppDateUtils.parseDate(map['txn_date'] as String),
      description: map['description'] as String?,
      categoryId: map['category_id'] as String?,
      expenseId: map['expense_id'] as String?,
      incomeId: map['income_id'] as String?,
      transferGroupId: map['transfer_group_id'] as String?,
      counterpartyAccountId: map['counterparty_account_id'] as String?,
      createdAt: map['created_at'] == null
          ? null
          : DateTime.parse(map['created_at'] as String),
      category: categoryJoin is Map<String, dynamic>
          ? ExpenseCategory.fromMap(categoryJoin)
          : null,
    );
  }

  Map<String, dynamic> toInsertMap() => <String, dynamic>{
        'user_id': userId,
        'account_id': accountId,
        'direction': direction.wire,
        'amount': amount,
        'txn_date': AppDateUtils.toDateString(txnDate),
        'description': _blankToNull(description),
        'category_id': categoryId,
        'expense_id': expenseId,
        'income_id': incomeId,
        'transfer_group_id': transferGroupId,
        // Omitted rather than sent as null when absent, so ordinary deposits
        // and expenses keep inserting cleanly against a database where
        // migration 003 has not been applied yet.
        if (counterpartyAccountId != null)
          'counterparty_account_id': counterpartyAccountId,
      };

  static String? _blankToNull(String? value) {
    final String? trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}

/// One printed statement line: a movement plus the balance after it.
class StatementRow {
  const StatementRow({required this.entry, required this.balanceAfter});

  final LedgerEntry entry;

  /// Running balance immediately after [entry] was applied.
  final double balanceAfter;
}

/// A complete statement for one account over one period.
///
/// Built by [buildStatement], which is a pure function so the running-balance
/// arithmetic is unit-testable without a database.
class AccountStatement {
  const AccountStatement({
    required this.openingBalance,
    required this.rows,
    required this.totalCredits,
    required this.totalDebits,
  });

  /// Balance carried into the period: the account opening balance plus every
  /// movement that happened before the period started.
  final double openingBalance;

  /// Newest first, the way a bank app lists them.
  final List<StatementRow> rows;

  final double totalCredits;
  final double totalDebits;

  double get closingBalance => openingBalance + totalCredits - totalDebits;

  bool get isEmpty => rows.isEmpty;

  int get movementCount => rows.length;
}

/// Computes running balances and period totals.
///
/// [entries] may arrive in any order. The running balance is accumulated
/// oldest-first (the only order in which it is meaningful), then the rows are
/// reversed so the caller can render newest-first.
///
/// [typeFilter] is applied *after* the balance walk, so hiding credits does
/// not corrupt the balances shown against the remaining debits. The totals,
/// however, describe the rows actually shown — otherwise the summary would
/// not reconcile with the visible list.
AccountStatement buildStatement({
  required double openingBalance,
  required List<LedgerEntry> entries,
  StatementTypeFilter typeFilter = StatementTypeFilter.all,
}) {
  final List<LedgerEntry> ordered = List<LedgerEntry>.of(entries)
    ..sort((LedgerEntry a, LedgerEntry b) {
      final int byDate = a.txnDate.compareTo(b.txnDate);
      if (byDate != 0) return byDate;
      // Same-day movements fall back to insertion order so the running
      // balance is stable and reproducible across reloads.
      final DateTime aCreated = a.createdAt ?? DateTime(1970);
      final DateTime bCreated = b.createdAt ?? DateTime(1970);
      final int byCreated = aCreated.compareTo(bCreated);
      return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
    });

  double running = openingBalance;
  final List<StatementRow> rows = <StatementRow>[];

  for (final LedgerEntry entry in ordered) {
    running += entry.signedAmount;
    if (typeFilter.matches(entry.direction)) {
      rows.add(StatementRow(entry: entry, balanceAfter: running));
    }
  }

  double credits = 0;
  double debits = 0;
  for (final StatementRow row in rows) {
    if (row.entry.isCredit) {
      credits += row.entry.amount;
    } else {
      debits += row.entry.amount;
    }
  }

  return AccountStatement(
    openingBalance: openingBalance,
    rows: rows.reversed.toList(),
    totalCredits: credits,
    totalDebits: debits,
  );
}
