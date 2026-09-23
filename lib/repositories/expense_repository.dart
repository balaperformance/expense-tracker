import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/constants/app_constants.dart';
import '../core/errors/app_exception.dart';
import '../core/utils/date_utils.dart';
import '../models/expense.dart';
import '../models/expense_filter.dart';
import '../services/schema_capabilities.dart';
import '../services/sms/sms_expense_draft.dart';
import 'ledger_repository.dart';

/// Reads and writes `public.expenses`.
///
/// Every query is scoped with an explicit `user_id` filter. RLS already
/// enforces this server-side; the client-side filter keeps result sets small
/// and makes the intent obvious at the call site.
class ExpenseRepository {
  ExpenseRepository(this._client) : _ledger = LedgerRepository(_client);

  final SupabaseClient _client;

  /// Writes the debit that mirrors a bank-funded expense.
  final LedgerRepository _ledger;

  static const String _table = 'expenses';

  /// Optional columns are selected only when the migration that adds them has
  /// run, so the Phase 1 schema keeps working untouched.
  String get _select {
    final String merchant = SchemaCapabilities.merchant ? ', merchant' : '';
    final String bank =
        SchemaCapabilities.expenseBankLink ? ', bank_account_id' : '';
    return 'id, user_id, amount, category_id, payment_method_id, '
        'expense_date, description, notes, created_at, updated_at'
        '$merchant$bank, categories(*), payment_methods(*)';
  }

  Future<void> _resolveCapabilities() =>
      SchemaCapabilities.resolve(_client);

  Future<List<Expense>> fetchPage({
    required String userId,
    required ExpenseFilter filter,
    required int page,
    int pageSize = AppConstants.pageSize,
  }) async {
    try {
      await _resolveCapabilities();

      PostgrestFilterBuilder<List<Map<String, dynamic>>> query =
          _client.from(_table).select(_select).eq('user_id', userId);

      query = _applyFilters(query, filter);

      final int from = page * pageSize;
      final List<Map<String, dynamic>> rows = await query
          .order(filter.sort.column, ascending: filter.sort.ascending)
          .order('created_at', ascending: false)
          .range(from, from + pageSize - 1);

      return rows.map(Expense.fromMap).toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// All expenses in a month, used for dashboard and report aggregation.
  ///
  /// Bounded by [AppConstants.monthlyAggregateLimit]; a single month of
  /// personal spending sits far below that, and aggregating client-side
  /// avoids adding database views or RPCs to an existing schema.
  Future<List<Expense>> fetchForMonth({
    required String userId,
    required DateTime month,
  }) async {
    try {
      await _resolveCapabilities();
      final MonthRange range = AppDateUtils.monthRange(month);

      final List<Map<String, dynamic>> rows = await _client
          .from(_table)
          .select(_select)
          .eq('user_id', userId)
          .gte('expense_date', AppDateUtils.toDateString(range.start))
          .lt('expense_date', AppDateUtils.toDateString(range.endExclusive))
          .order('expense_date', ascending: false)
          .limit(AppConstants.monthlyAggregateLimit);

      return rows.map(Expense.fromMap).toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Every expense in an arbitrary day range, oldest first.
  ///
  /// Exists for export, which is the only caller that needs a window not
  /// aligned to a calendar month. [fetchForMonth] stays as it is so the
  /// dashboard and reports keep their existing, narrower query.
  ///
  /// `toExclusive` is exclusive, matching every other range query here; the
  /// export layer converts the user's inclusive end date once, in
  /// `ExportDateRange`.
  Future<List<Expense>> fetchRange({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
    Set<String> categoryIds = const <String>{},
    int limit = AppConstants.exportRowLimit,
  }) async {
    try {
      await _resolveCapabilities();

      PostgrestFilterBuilder<List<Map<String, dynamic>>> query = _client
          .from(_table)
          .select(_select)
          .eq('user_id', userId)
          .gte('expense_date', AppDateUtils.toDateString(from))
          .lt('expense_date', AppDateUtils.toDateString(toExclusive));

      if (categoryIds.isNotEmpty) {
        query = query.inFilter('category_id', categoryIds.toList());
      }

      final List<Map<String, dynamic>> rows = await query
          .order('expense_date', ascending: true)
          .order('created_at', ascending: true)
          .limit(limit);

      return rows.map(Expense.fromMap).toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Month totals for a contiguous range, returned as `yyyy-MM` -> total.
  ///
  /// One request covers the whole trend chart instead of one per month.
  Future<Map<String, double>> fetchMonthlyTotals({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
  }) async {
    try {
      final List<Map<String, dynamic>> rows = await _client
          .from(_table)
          .select('amount, expense_date')
          .eq('user_id', userId)
          .gte('expense_date', AppDateUtils.toDateString(from))
          .lt('expense_date', AppDateUtils.toDateString(toExclusive))
          .limit(AppConstants.monthlyAggregateLimit * 12);

      return _bucketByMonth(rows, 'expense_date');
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<Expense> create(Expense expense) async {
    try {
      await _resolveCapabilities();
      final Map<String, dynamic> row = await _client
          .from(_table)
          .insert(expense.toInsertMap(
            includeMerchant: SchemaCapabilities.merchant,
            includeBankLink: SchemaCapabilities.expenseBankLink,
          ))
          .select(_select)
          .single();

      final Expense created = Expense.fromMap(row);
      await _syncLedger(created);
      return created;
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<Expense> update(Expense expense) async {
    try {
      await _resolveCapabilities();
      final Map<String, dynamic> patch = expense.toUpdateMap(
        includeMerchant: SchemaCapabilities.merchant,
        includeBankLink: SchemaCapabilities.expenseBankLink,
      )..['updated_at'] = DateTime.now().toUtc().toIso8601String();

      final Map<String, dynamic> row = await _client
          .from(_table)
          .update(patch)
          .eq('id', expense.id)
          .eq('user_id', expense.userId)
          .select(_select)
          .single();

      final Expense updated = Expense.fromMap(row);
      // Re-sync rather than patch: this covers switching between accounts,
      // switching to Cash, and changing amount or date, in one path.
      await _syncLedger(updated);
      return updated;
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// The matching ledger row is removed by `ON DELETE CASCADE`, so there is
  /// nothing to clean up here and no window where a movement can be orphaned.
  Future<void> delete({required String userId, required String id}) async {
    try {
      await _client.from(_table).delete().eq('id', id).eq('user_id', userId);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Mirrors an expense into the ledger.
  ///
  /// A cash expense (no account) produces no movement, which is what keeps
  /// cash spending from touching any bank balance.
  Future<void> _syncLedger(Expense expense) async {
    if (!SchemaCapabilities.phase2Ready) return;
    await _ledger.syncForExpense(
      userId: expense.userId,
      expenseId: expense.id,
      accountId: expense.bankAccountId,
      amount: expense.amount,
      date: expense.expenseDate,
      description: expense.title,
      categoryId: expense.categoryId,
    );
  }

  /// Looks for an expense that already records this bank message.
  ///
  /// Two checks, strongest first:
  ///
  ///  * By reference. A transaction id is unique to the transaction, so the
  ///    same SMS pasted twice — or forwarded and pasted weeks later — is
  ///    caught exactly. The id lives in `notes`, in the fixed format
  ///    [SmsReferenceNote] writes, which is why both sides read it from
  ///    there rather than each formatting their own.
  ///  * By shape. Most messages carry no reference at all, so an expense on
  ///    the same day, for the same amount, from the same account is reported
  ///    as a likely repeat.
  ///
  /// The second check can be wrong — buying the same coffee twice in a day is
  /// perfectly ordinary. It is therefore a warning the review screen shows,
  /// never a refusal: the user is told and decides.
  ///
  /// Returns null when nothing looks like a repeat, and also when the lookup
  /// itself fails. A duplicate *warning* is a convenience, and failing to
  /// fetch one must not stop someone recording a real expense.
  Future<Expense?> findPossibleDuplicate({
    required String userId,
    required double amount,
    required DateTime date,
    String? reference,
    String? bankAccountId,
  }) async {
    try {
      await _resolveCapabilities();

      if (reference != null && reference.trim().isNotEmpty) {
        final String term =
            _sanitiseSearch(SmsReferenceNote.searchTerm(reference));
        if (term.isNotEmpty) {
          final List<Map<String, dynamic>> byReference = await _client
              .from(_table)
              .select(_select)
              .eq('user_id', userId)
              .ilike('notes', '%$term%')
              .limit(1);

          if (byReference.isNotEmpty) {
            return Expense.fromMap(byReference.first);
          }
        }
      }

      PostgrestFilterBuilder<List<Map<String, dynamic>>> query = _client
          .from(_table)
          .select(_select)
          .eq('user_id', userId)
          .eq('amount', amount)
          .eq('expense_date', AppDateUtils.toDateString(date));

      if (SchemaCapabilities.expenseBankLink) {
        query = bankAccountId == null
            ? query.isFilter('bank_account_id', null)
            : query.eq('bank_account_id', bankAccountId);
      }

      final List<Map<String, dynamic>> byShape = await query.limit(1);
      return byShape.isEmpty ? null : Expense.fromMap(byShape.first);
    } catch (_) {
      return null;
    }
  }

  /// Total spend for one category in one month, for budget progress.
  Future<double> totalForCategoryMonth({
    required String userId,
    required String? categoryId,
    required DateTime month,
  }) async {
    try {
      final MonthRange range = AppDateUtils.monthRange(month);
      PostgrestFilterBuilder<List<Map<String, dynamic>>> query = _client
          .from(_table)
          .select('amount')
          .eq('user_id', userId)
          .gte('expense_date', AppDateUtils.toDateString(range.start))
          .lt('expense_date', AppDateUtils.toDateString(range.endExclusive));

      if (categoryId != null) {
        query = query.eq('category_id', categoryId);
      }

      final List<Map<String, dynamic>> rows = await query;
      return rows.fold<double>(
        0,
        (double sum, Map<String, dynamic> row) =>
            sum + ((row['amount'] as num?)?.toDouble() ?? 0),
      );
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  PostgrestFilterBuilder<List<Map<String, dynamic>>> _applyFilters(
    PostgrestFilterBuilder<List<Map<String, dynamic>>> query,
    ExpenseFilter filter,
  ) {
    PostgrestFilterBuilder<List<Map<String, dynamic>>> result = query;

    if (filter.categoryIds.isNotEmpty) {
      result = result.inFilter('category_id', filter.categoryIds.toList());
    }
    if (filter.paymentMethodIds.isNotEmpty) {
      result = result.inFilter(
        'payment_method_id',
        filter.paymentMethodIds.toList(),
      );
    }
    if (filter.from != null) {
      result = result.gte(
        'expense_date',
        AppDateUtils.toDateString(filter.from!),
      );
    }
    if (filter.to != null) {
      result = result.lte('expense_date', AppDateUtils.toDateString(filter.to!));
    }

    final String term = _sanitiseSearch(filter.search);
    if (term.isNotEmpty) {
      final List<String> clauses = <String>[
        'description.ilike.%$term%',
        'notes.ilike.%$term%',
        if (SchemaCapabilities.merchant) 'merchant.ilike.%$term%',
      ];
      result = result.or(clauses.join(','));
    }

    return result;
  }

  /// Strips characters that would break PostgREST `or=` clause parsing.
  static String _sanitiseSearch(String raw) =>
      raw.trim().replaceAll(RegExp(r'[,()*%\\]'), '');

  static Map<String, double> _bucketByMonth(
    List<Map<String, dynamic>> rows,
    String dateKey,
  ) {
    final Map<String, double> totals = <String, double>{};
    for (final Map<String, dynamic> row in rows) {
      final String raw = row[dateKey] as String;
      final String bucket = raw.substring(0, 7); // yyyy-MM
      totals[bucket] =
          (totals[bucket] ?? 0) + ((row['amount'] as num?)?.toDouble() ?? 0);
    }
    return totals;
  }
}
