import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors/app_exception.dart';
import '../core/utils/date_utils.dart';
import '../core/utils/uuid.dart';
import '../models/ledger_entry.dart';
import '../models/money_transfer.dart';
import '../services/schema_capabilities.dart';
import 'paging.dart';

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
      '${SchemaCapabilities.creditCards ? 'credit_card_id, ' : ''}'
      '${SchemaCapabilities.treatments ? 'receivable_id, ' : ''}'
      '${SchemaCapabilities.statementDetails ? 'reference, upi_id, txn_time, ' : ''}'
      'created_at, categories(*)';

  /// What a statement printed about a movement, as columns — nothing at all
  /// until migration 007 can store it, so every write keeps working without.
  static Map<String, dynamic> _detailsColumns(MovementDetails? details) =>
      details == null || !SchemaCapabilities.statementDetails
          ? const <String, dynamic>{}
          : details.toColumns();

  /// Entries for one account, optionally bounded by a date window.
  Future<List<LedgerEntry>> fetchForAccount({
    required String userId,
    required String accountId,
    DateTime? from,
    DateTime? toExclusive,
  }) async {
    try {
      // Every row, page by page: a running balance built from a truncated
      // list would be silently wrong.
      final List<Map<String, dynamic>> rows =
          await fetchAllPages(postgrestPages(() {
        PostgrestFilterBuilder<List<Map<String, dynamic>>> query = _client
            .from(_table)
            .select(_select)
            .eq('user_id', userId)
            .eq('account_id', accountId);
        if (from != null) {
          query = query.gte('txn_date', AppDateUtils.toDateString(from));
        }
        if (toExclusive != null) {
          query =
              query.lt('txn_date', AppDateUtils.toDateString(toExclusive));
        }
        return query.order('txn_date', ascending: false).order('id');
      }));

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
      final List<Map<String, dynamic>> rows =
          await fetchAllPages(postgrestPages(() {
        PostgrestFilterBuilder<List<Map<String, dynamic>>> query = _client
            .from(_table)
            .select('id, direction, amount')
            .eq('user_id', userId)
            .eq('account_id', accountId);
        if (before != null) {
          query = query.lt('txn_date', AppDateUtils.toDateString(before));
        }
        return query.order('id');
      }));
      return netOfRows(rows);
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

  // ---- Credit-card bill payments (migration 004) ---------------------------
  //
  // A bill paid from an account is ONE debit on that account carrying the
  // card's id: the same row lowers the bank balance and the card's
  // outstanding, so the two sides can never disagree, and it is not an
  // expense.

  /// Pays a card bill from a bank account. [details]: what an imported
  /// statement printed about the payment.
  Future<void> recordCardPayment({
    required String userId,
    required String accountId,
    required String cardId,
    required double amount,
    required DateTime date,
    required String description,
    MovementDetails? details,
  }) async {
    try {
      await _client.from(_table).insert(<String, dynamic>{
        'user_id': userId,
        'account_id': accountId,
        'direction': LedgerDirection.debit.wire,
        'amount': amount,
        'txn_date': AppDateUtils.toDateString(date),
        'description': description,
        'category_id': null,
        'expense_id': null,
        'income_id': null,
        'transfer_group_id': null,
        'credit_card_id': cardId,
        ..._detailsColumns(details),
      });
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  // ---- Imported movements ----------------------------------------------------
  //
  // The statement import's write paths, the counterparts of the web app's
  // services/ledger.ts: the same rows, the same columns.

  /// A standalone credit or debit — a refund, a cash withdrawal, a transfer
  /// with no tracked other side — with what its statement printed.
  Future<LedgerEntry> recordMovement({
    required String userId,
    required String accountId,
    required LedgerDirection direction,
    required double amount,
    required DateTime date,
    String? description,
    MovementDetails? details,
  }) async {
    try {
      final Map<String, dynamic> row = await _client
          .from(_table)
          .insert(<String, dynamic>{
            ...LedgerEntry(
              id: '',
              userId: userId,
              accountId: accountId,
              direction: direction,
              amount: amount,
              txnDate: date,
              description: description,
            ).toInsertMap(),
            ..._detailsColumns(details),
          })
          .select(_select)
          .single();
      return LedgerEntry.fromMap(row);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Both legs of a transfer to another of the user's accounts, as one
  /// insert (migration 003) — used when migration 005 is absent. The
  /// statement's details belong to this account's leg only.
  Future<void> recordTransferPair({
    required String userId,
    required String accountId,
    required String counterpartyAccountId,
    required LedgerDirection direction,
    required double amount,
    required DateTime date,
    required String description,
    required String counterpartDescription,
    MovementDetails? details,
  }) async {
    try {
      final String groupId = Uuid.v4();
      final String txnDate = AppDateUtils.toDateString(date);
      final Map<String, dynamic> detailColumns = _detailsColumns(details);
      Map<String, dynamic> leg(String account, String other,
              LedgerDirection legDirection, String text) =>
          <String, dynamic>{
            'user_id': userId,
            'account_id': account,
            'direction': legDirection.wire,
            'amount': amount,
            'txn_date': txnDate,
            'description': text,
            'transfer_group_id': groupId,
            'counterparty_account_id': other,
          };
      await _client.from(_table).insert(<Map<String, dynamic>>[
        <String, dynamic>{
          ...leg(accountId, counterpartyAccountId, direction, description),
          ...detailColumns,
        },
        <String, dynamic>{
          ...leg(
            counterpartyAccountId,
            accountId,
            direction == LedgerDirection.debit
                ? LedgerDirection.credit
                : LedgerDirection.debit,
            counterpartDescription,
          ),
          // One insert: every row carries the same columns.
          for (final String key in detailColumns.keys) key: null,
        },
      ]);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Saves a movement together with its treatment in one database
  /// transaction (`record_bank_movement`, migration 005) — for an imported
  /// transfer to one of the user's accounts, which adds the other leg or
  /// links the row already there. [treatment] is the engine's payload, the
  /// same JSON the web app sends. Returns the new movement's id.
  Future<String> recordBankMovement({
    required String accountId,
    required LedgerDirection direction,
    required double amount,
    required DateTime date,
    required String description,
    required Map<String, Object?> treatment,
  }) async {
    try {
      final Object? id = await _client.rpc<Object?>(
        'record_bank_movement',
        params: <String, dynamic>{
          'p_account_id': accountId,
          'p_direction': direction.wire,
          'p_amount': amount,
          'p_date': AppDateUtils.toDateString(date),
          'p_description': description,
          'p_treatment': treatment,
        },
      );
      if (id is! String || id.isEmpty) {
        throw const AppException('The movement could not be saved.');
      }
      return id;
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Records what the statement printed on a movement a database function
  /// saved (it knows nothing of it). Nothing to do before migration 007.
  Future<void> setMovementDetails({
    required String userId,
    required String entryId,
    required MovementDetails details,
  }) async {
    final Map<String, dynamic> columns = _detailsColumns(details);
    if (columns.isEmpty) return;
    try {
      await _client
          .from(_table)
          .update(columns)
          .eq('id', entryId)
          .eq('user_id', userId);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Ids of debits that are money lent (migration 005): never a plain
  /// movement, so never taken as the other leg of an imported transfer.
  Future<Set<String>> fetchLentEntryIds({required String userId}) async {
    if (!SchemaCapabilities.treatments) return <String>{};
    try {
      final List<Map<String, dynamic>> rows =
          await fetchAllPages(postgrestPages(() => _client
              .from('receivables')
              .select('id, ledger_entry_id')
              .eq('user_id', userId)
              .not('ledger_entry_id', 'is', null)
              .order('id')));
      return rows
          .map((Map<String, dynamic> r) => r['ledger_entry_id'] as String?)
          .whereType<String>()
          .toSet();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Marks an existing debit — typed in or imported from a bank statement —
  /// as the payment of [cardId], or clears that with null. No row is added,
  /// so the account is never debited twice.
  ///
  /// Linking only claims an unlinked plain debit: it never moves another
  /// card's payment, even from a screen that went stale. Unlinking only
  /// touches a linked one. Anything else changes nothing and is reported.
  Future<void> linkToCard({
    required String userId,
    required String entryId,
    required String? cardId,
  }) async {
    List<Map<String, dynamic>> rows;
    try {
      final PostgrestFilterBuilder<dynamic> query = _client
          .from(_table)
          .update(<String, dynamic>{'credit_card_id': cardId})
          .eq('id', entryId)
          .eq('user_id', userId)
          .eq('direction', LedgerDirection.debit.wire)
          .isFilter('expense_id', null)
          .isFilter('income_id', null)
          .isFilter('transfer_group_id', null);
      rows = await (cardId != null
              ? query.isFilter('credit_card_id', null)
              : query.not('credit_card_id', 'is', null))
          .select('id');
    } catch (error) {
      throw ErrorMapper.map(error);
    }
    if (rows.isEmpty) {
      throw AppException(cardId != null
          ? 'That debit is no longer available to link — it may already be '
              'linked to a card, or changed. Refresh and try again.'
          : 'That payment is no longer linked to a card. Refresh and try '
              'again.');
    }
  }

  /// Every bill payment drawn from an account — for one card, or for all of
  /// the user's cards when [cardId] is null.
  Future<List<LedgerEntry>> fetchCardPayments({
    required String userId,
    String? cardId,
  }) async {
    if (!SchemaCapabilities.creditCards) return <LedgerEntry>[];
    try {
      final List<Map<String, dynamic>> rows =
          await fetchAllPages(postgrestPages(() {
        final PostgrestFilterBuilder<List<Map<String, dynamic>>> query =
            _client.from(_table).select(_select).eq('user_id', userId);
        return (cardId != null
                ? query.eq('credit_card_id', cardId)
                : query.not('credit_card_id', 'is', null))
            .order('id');
      }));
      return rows.map(LedgerEntry.fromMap).toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// How many bill payments an account holds, so deleting it can say so.
  Future<int> cardPaymentCount({
    required String userId,
    required String accountId,
  }) async {
    if (!SchemaCapabilities.creditCards) return 0;
    try {
      final PostgrestResponse<List<Map<String, dynamic>>> response =
          await _client
              .from(_table)
              .select('id')
              .eq('user_id', userId)
              .eq('account_id', accountId)
              .not('credit_card_id', 'is', null)
              .count(CountOption.exact);
      return response.count;
    } catch (_) {
      return 0;
    }
  }

  /// Makes the ledger agree with an expense.
  ///
  /// Cash expenses ([accountId] null) must leave no movement at all, which is
  /// why the "no account" branch deletes any row a previous edit created.
  /// A unique index on `expense_id` guarantees at most one row per expense,
  /// so a retried insert cannot double-debit.
  ///
  /// [details] — what an imported statement printed about the payment — are
  /// written with the movement; an edit that passes none leaves them as they
  /// are.
  Future<void> syncForExpense({
    required String userId,
    required String expenseId,
    required String? accountId,
    required double amount,
    required DateTime date,
    String? description,
    String? categoryId,
    MovementDetails? details,
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
        ..._detailsColumns(details),
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
    MovementDetails? details,
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
        ..._detailsColumns(details),
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
