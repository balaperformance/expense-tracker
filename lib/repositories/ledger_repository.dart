import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors/app_exception.dart';
import '../core/utils/date_utils.dart';
import '../core/utils/uuid.dart';
import '../models/ledger_entry.dart';
import '../models/money_transfer.dart';
import '../services/schema_capabilities.dart';

/// Reads and writes `public.account_transactions`, the ledger that is the
/// source of truth for every bank account movement.
///
/// Movements produced by an expense or income row are written here by
/// [syncForExpense] / [syncForIncome]. Deletion is handled by the database
/// (`ON DELETE CASCADE`), so this class never has to clean up after a
/// deleted source document.
class LedgerRepository {
  const LedgerRepository(this._client);

  final SupabaseClient _client;

  static const String _table = 'account_transactions';

  /// The counterparty column only exists after migration 003, and PostgREST
  /// rejects the whole request if a selected column is missing — so asking for
  /// it unconditionally would break every statement on an un-migrated
  /// database. It is requested only once the probe has confirmed it.
  static String get _select =>
      'id, user_id, account_id, direction, amount, txn_date, description, '
      'category_id, expense_id, income_id, transfer_group_id, '
      '${SchemaCapabilities.transfers ? 'counterparty_account_id, ' : ''}'
      'created_at, categories(*)';

  /// Entries for one account, optionally bounded by a date window.
  Future<List<LedgerEntry>> fetchForAccount({
    required String userId,
    required String accountId,
    DateTime? from,
    DateTime? toExclusive,
  }) async {
    try {
      PostgrestFilterBuilder<List<Map<String, dynamic>>> query = _client
          .from(_table)
          .select(_select)
          .eq('user_id', userId)
          .eq('account_id', accountId);

      if (from != null) {
        query = query.gte('txn_date', AppDateUtils.toDateString(from));
      }
      if (toExclusive != null) {
        query = query.lt('txn_date', AppDateUtils.toDateString(toExclusive));
      }

      final List<Map<String, dynamic>> rows =
          await query.order('txn_date', ascending: false).limit(2000);

      return rows.map(LedgerEntry.fromMap).toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Net movement strictly before [before], used as the opening balance for a
  /// filtered statement period.
  ///
  /// Returned as credits minus debits; the caller adds the account opening
  /// balance to get the true brought-forward figure.
  Future<double> netBefore({
    required String userId,
    required String accountId,
    required DateTime before,
  }) =>
      _net(userId: userId, accountId: accountId, before: before);

  /// Net movement over the account's whole history.
  ///
  /// Used to re-derive a live balance immediately before a transfer, so the
  /// sufficient-funds check is made against the ledger rather than against
  /// whatever the screen happened to be showing.
  Future<double> netFor({
    required String userId,
    required String accountId,
  }) =>
      _net(userId: userId, accountId: accountId, before: null);

  Future<double> _net({
    required String userId,
    required String accountId,
    required DateTime? before,
  }) async {
    try {
      PostgrestFilterBuilder<List<Map<String, dynamic>>> query = _client
          .from(_table)
          .select('direction, amount')
          .eq('user_id', userId)
          .eq('account_id', accountId);

      if (before != null) {
        query = query.lt('txn_date', AppDateUtils.toDateString(before));
      }

      final List<Map<String, dynamic>> rows = await query;

      double net = 0;
      for (final Map<String, dynamic> row in rows) {
        final double amount = (row['amount'] as num?)?.toDouble() ?? 0;
        net += row['direction'] == 'credit' ? amount : -amount;
      }
      return net;
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Moves money between two accounts the user owns, as one transfer.
  ///
  /// Writes exactly two ledger rows — a debit on [fromAccountId] and a credit
  /// on [toAccountId] — sharing one `transfer_group_id`, in a **single**
  /// insert. PostgREST executes a multi-row insert as one statement, so both
  /// legs commit together or neither does. That matters more here than
  /// anywhere else in the app: a half-written transfer would make money
  /// disappear from one balance without arriving in the other.
  ///
  /// No expense and no income row is created, which is what keeps a transfer
  /// out of the Dashboard, Reports, budgets and spending analytics.
  ///
  /// Returns the shared group id.
  Future<String> transfer({
    required String userId,
    required String fromAccountId,
    required String toAccountId,
    required String fromLabel,
    required String toLabel,
    required double amount,
    required DateTime date,
    String? note,
  }) async {
    try {
      final String groupId = Uuid.v4();
      final String txnDate = AppDateUtils.toDateString(date);

      final List<Map<String, dynamic>> legs = <Map<String, dynamic>>[
        <String, dynamic>{
          'user_id': userId,
          'account_id': fromAccountId,
          'direction': LedgerDirection.debit.wire,
          'amount': amount,
          'txn_date': txnDate,
          'description': transferDescription(
            note: note,
            isOutgoing: true,
            counterpartyLabel: toLabel,
          ),
          'transfer_group_id': groupId,
          'counterparty_account_id': toAccountId,
        },
        <String, dynamic>{
          'user_id': userId,
          'account_id': toAccountId,
          'direction': LedgerDirection.credit.wire,
          'amount': amount,
          'txn_date': txnDate,
          'description': transferDescription(
            note: note,
            isOutgoing: false,
            counterpartyLabel: fromLabel,
          ),
          'transfer_group_id': groupId,
          'counterparty_account_id': fromAccountId,
        },
      ];

      await _client.from(_table).insert(legs);
      return groupId;
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Removes both legs of a transfer.
  ///
  /// Deleting one side alone would leave the money looking like it had been
  /// created or destroyed, so the delete is always by group and always in one
  /// statement.
  Future<void> deleteTransfer({
    required String userId,
    required String transferGroupId,
  }) async {
    try {
      await _client
          .from(_table)
          .delete()
          .eq('user_id', userId)
          .eq('transfer_group_id', transferGroupId);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Records a standalone credit (deposit / top-up) not tied to any income
  /// row.
  Future<LedgerEntry> deposit({
    required String userId,
    required String accountId,
    required double amount,
    required DateTime date,
    String? description,
  }) async {
    try {
      final Map<String, dynamic> row = await _client
          .from(_table)
          .insert(LedgerEntry(
            id: '',
            userId: userId,
            accountId: accountId,
            direction: LedgerDirection.credit,
            amount: amount,
            txnDate: date,
            description: description,
          ).toInsertMap())
          .select(_select)
          .single();

      return LedgerEntry.fromMap(row);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Records a standalone debit (withdrawal / bank charge).
  Future<LedgerEntry> withdraw({
    required String userId,
    required String accountId,
    required double amount,
    required DateTime date,
    String? description,
  }) async {
    try {
      final Map<String, dynamic> row = await _client
          .from(_table)
          .insert(LedgerEntry(
            id: '',
            userId: userId,
            accountId: accountId,
            direction: LedgerDirection.debit,
            amount: amount,
            txnDate: date,
            description: description,
          ).toInsertMap())
          .select(_select)
          .single();

      return LedgerEntry.fromMap(row);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<void> deleteEntry({
    required String userId,
    required String id,
  }) async {
    try {
      await _client.from(_table).delete().eq('id', id).eq('user_id', userId);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Makes the ledger agree with an expense.
  ///
  /// Cash expenses ([accountId] null) must leave no movement at all, which is
  /// why the "no account" branch deletes any row a previous edit created.
  /// A unique index on `expense_id` guarantees at most one row per expense,
  /// so a retried insert cannot double-debit.
  Future<void> syncForExpense({
    required String userId,
    required String expenseId,
    required String? accountId,
    required double amount,
    required DateTime date,
    String? description,
    String? categoryId,
  }) async {
    try {
      final List<Map<String, dynamic>> existing = await _client
          .from(_table)
          .select('id')
          .eq('user_id', userId)
          .eq('expense_id', expenseId);

      if (accountId == null) {
        // Switched to Cash: remove the movement it used to make.
        if (existing.isNotEmpty) {
          await _client
              .from(_table)
              .delete()
              .eq('expense_id', expenseId)
              .eq('user_id', userId);
        }
        return;
      }

      final Map<String, dynamic> payload = <String, dynamic>{
        'account_id': accountId,
        'direction': LedgerDirection.debit.wire,
        'amount': amount,
        'txn_date': AppDateUtils.toDateString(date),
        'description': description,
        'category_id': categoryId,
      };

      if (existing.isEmpty) {
        await _client.from(_table).insert(<String, dynamic>{
          'user_id': userId,
          'expense_id': expenseId,
          ...payload,
        });
      } else {
        await _client
            .from(_table)
            .update(payload)
            .eq('expense_id', expenseId)
            .eq('user_id', userId);
      }
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Makes the ledger agree with an income row. Mirror of [syncForExpense],
  /// but the movement is a credit.
  Future<void> syncForIncome({
    required String userId,
    required String incomeId,
    required String? accountId,
    required double amount,
    required DateTime date,
    String? description,
  }) async {
    try {
      final List<Map<String, dynamic>> existing = await _client
          .from(_table)
          .select('id')
          .eq('user_id', userId)
          .eq('income_id', incomeId);

      if (accountId == null) {
        if (existing.isNotEmpty) {
          await _client
              .from(_table)
              .delete()
              .eq('income_id', incomeId)
              .eq('user_id', userId);
        }
        return;
      }

      final Map<String, dynamic> payload = <String, dynamic>{
        'account_id': accountId,
        'direction': LedgerDirection.credit.wire,
        'amount': amount,
        'txn_date': AppDateUtils.toDateString(date),
        'description': description,
      };

      if (existing.isEmpty) {
        await _client.from(_table).insert(<String, dynamic>{
          'user_id': userId,
          'income_id': incomeId,
          ...payload,
        });
      } else {
        await _client
            .from(_table)
            .update(payload)
            .eq('income_id', incomeId)
            .eq('user_id', userId);
      }
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }
}
