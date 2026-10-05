import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors/app_exception.dart';
import '../core/utils/date_utils.dart';
import '../models/receivable.dart';
import '../services/schema_capabilities.dart';
import 'paging.dart';

/// `public.receivables` (migration 005, shared with the web app): money lent
/// and purchases paid for someone else.
///
/// What is owed is never read from a stored column: each claim's source (the
/// lent debit or the purchase) and its repayments (ledger credits naming it)
/// are read from their own rows and summarised by [summariseClaims] — the
/// same reads the web app's `services/receivables.ts` makes.
class ReceivableRepository {
  const ReceivableRepository(this._client);

  final SupabaseClient _client;

  static const String _table = 'receivables';
  static const String _select = 'id, user_id, kind, person, ledger_entry_id, '
      'expense_id, due_date, note, created_at';

  /// `in (…)` lists are sent in chunks so a long one never overflows the URL.
  static const int _chunk = 100;

  /// Every claim the user has, without figures. Small: one row per loan or
  /// paid-for purchase.
  Future<List<Receivable>> fetchClaimLinks(String userId) async {
    await SchemaCapabilities.resolve(_client);
    if (!SchemaCapabilities.treatments) return const <Receivable>[];
    try {
      final List<Map<String, dynamic>> rows =
          await fetchAllPages(postgrestPages(() => _client
              .from(_table)
              .select(_select)
              .eq('user_id', userId)
              .order('id')));
      return rows.map(Receivable.fromMap).toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<List<Map<String, dynamic>>> _rowsWhereIn(
    String table,
    String columns,
    String userId,
    String column,
    List<String> ids,
  ) async {
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    for (int i = 0; i < ids.length; i += _chunk) {
      final List<String> chunk =
          ids.sublist(i, i + _chunk > ids.length ? ids.length : i + _chunk);
      rows.addAll(await _client
          .from(table)
          .select(columns)
          .eq('user_id', userId)
          .inFilter(column, chunk));
    }
    return rows;
  }

  static String? _clean(Object? value) {
    final String? text = (value as String?)?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  static double _amount(Object? value) => (value as num?)?.toDouble() ?? 0;

  /// Every claim with what went out, what came back and what is left.
  Future<List<ClaimSummary>> fetchClaims(String userId) async {
    final List<Receivable> receivables = await fetchClaimLinks(userId);
    if (receivables.isEmpty) return const <ClaimSummary>[];
    try {
      final List<String> ledgerIds =
          receivables.map((Receivable r) => r.ledgerEntryId).whereType<String>().toList();
      final List<String> expenseIds =
          receivables.map((Receivable r) => r.expenseId).whereType<String>().toList();
      final String purchaseColumns = 'id, amount, expense_date, description'
          '${SchemaCapabilities.merchant ? ', merchant' : ''}'
          '${SchemaCapabilities.expenseBankLink ? ', bank_account_id' : ''}'
          '${SchemaCapabilities.creditCards ? ', credit_card_id' : ''}'
          ', categories(name)';

      final List<List<Map<String, dynamic>>> read =
          await Future.wait(<Future<List<Map<String, dynamic>>>>[
        _rowsWhereIn('account_transactions',
            'id, account_id, amount, txn_date, description', userId, 'id', ledgerIds),
        _rowsWhereIn('expenses', purchaseColumns, userId, 'id', expenseIds),
        // A bank-funded purchase's own debit, so the claim can link to its
        // statement.
        _rowsWhereIn('account_transactions', 'id, expense_id', userId,
            'expense_id', expenseIds),
        fetchAllPages(postgrestPages(() => _client
            .from('account_transactions')
            .select('id, account_id, amount, txn_date, description, receivable_id')
            .eq('user_id', userId)
            .not('receivable_id', 'is', null)
            .order('id'))),
      ]);

      final Map<String, Map<String, dynamic>> lentById =
          <String, Map<String, dynamic>>{
        for (final Map<String, dynamic> r in read[0]) r['id'] as String: r,
      };
      final Map<String, Map<String, dynamic>> purchaseById =
          <String, Map<String, dynamic>>{
        for (final Map<String, dynamic> r in read[1]) r['id'] as String: r,
      };
      final Map<String, String> debitByExpense = <String, String>{
        for (final Map<String, dynamic> r in read[2])
          if (r['expense_id'] != null) r['expense_id'] as String: r['id'] as String,
      };

      final Map<String, ClaimSource> sources = <String, ClaimSource>{};
      for (final Receivable receivable in receivables) {
        final String? ledgerId = receivable.ledgerEntryId;
        final String? expenseId = receivable.expenseId;
        if (ledgerId != null) {
          final Map<String, dynamic>? row = lentById[ledgerId];
          if (row == null) continue;
          sources[receivable.id] = ClaimSource(
            date: AppDateUtils.parseDate(row['txn_date'] as String),
            amount: _amount(row['amount']),
            title: _clean(row['description']) ?? 'Money lent',
            accountId: row['account_id'] as String?,
            ledgerEntryId: ledgerId,
          );
        } else if (expenseId != null) {
          final Map<String, dynamic>? row = purchaseById[expenseId];
          if (row == null) continue;
          final Object? category = row['categories'];
          sources[receivable.id] = ClaimSource(
            date: AppDateUtils.parseDate(row['expense_date'] as String),
            amount: _amount(row['amount']),
            title: _clean(row['merchant']) ??
                _clean(row['description']) ??
                (category is Map ? _clean(category['name']) : null) ??
                'Purchase',
            accountId: row['bank_account_id'] as String?,
            cardId: row['credit_card_id'] as String?,
            ledgerEntryId: debitByExpense[expenseId],
            expenseId: expenseId,
          );
        }
      }

      final List<ClaimRepayment> repayments = read[3]
          .map((Map<String, dynamic> r) => ClaimRepayment(
                entryId: r['id'] as String,
                receivableId: r['receivable_id'] as String,
                accountId: r['account_id'] as String,
                amount: _amount(r['amount']),
                date: AppDateUtils.parseDate(r['txn_date'] as String),
                description: r['description'] as String?,
              ))
          .toList();

      return summariseClaims(
        receivables: receivables,
        sources: sources,
        repayments: repayments,
        today: AppDateUtils.today(),
      );
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// The row [setExpensePaidFor] writes to mark a purchase — what the web app
  /// writes, so both apps read the claim the same way.
  static Map<String, dynamic> paidForRow({
    required String userId,
    required String expenseId,
    required PaidForDraft draft,
    required DateTime now,
  }) {
    final String? note = draft.note?.trim();
    final DateTime? due = draft.dueDate;
    return <String, dynamic>{
      'user_id': userId,
      'kind': 'reimbursable',
      'person': draft.person.trim(),
      'expense_id': expenseId,
      'due_date': due == null ? null : AppDateUtils.toDateString(due),
      'note': note == null || note.isEmpty ? null : note,
      'updated_at': now.toUtc().toIso8601String(),
    };
  }

  /// Marks an expense as paid on someone's behalf, or (with null) clears
  /// that. One statement either way. Clearing keeps any money already
  /// received, as plain money in on its account.
  Future<void> setExpensePaidFor({
    required String userId,
    required String expenseId,
    required PaidForDraft? paidFor,
  }) async {
    try {
      if (paidFor == null) {
        await _client
            .from(_table)
            .delete()
            .eq('user_id', userId)
            .eq('expense_id', expenseId);
        return;
      }
      await _client.from(_table).upsert(
            paidForRow(
              userId: userId,
              expenseId: expenseId,
              draft: paidFor,
              now: DateTime.now(),
            ),
            onConflict: 'expense_id',
          );
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }
}
