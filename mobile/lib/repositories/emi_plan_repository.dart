import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors/app_exception.dart';
import '../core/utils/date_utils.dart';
import '../models/emi_plan.dart';
import '../models/emi_reimbursement.dart';
import '../models/ledger_entry.dart';
import '../services/schema_capabilities.dart';
import 'income_repository.dart';
import 'ledger_repository.dart';
import 'paging.dart';

/// `public.emi_plans` (migration 016, shared with the web app): purchases
/// converted to EMI on a card.
///
/// A plan someone else pays back is also a claim — a `receivables` row of
/// kind 'emi' naming the plan — so its repayments are recorded, matched and
/// summarised exactly like any other claim. The plan and its claim are kept
/// in step here: setting a person creates the claim, clearing it removes the
/// claim (repayments already received stay as plain money in).
class EmiPlanRepository {
  const EmiPlanRepository(this._client);

  final SupabaseClient _client;

  static const String _table = 'emi_plans';
  static const String _select =
      'id, user_id, card_id, title, reference, person, include_charges, '
      'purchase_amount, monthly_amount, tenure_months, start_date, '
      'category_id, notes, is_closed, created_at';

  /// Every plan — on one card, or on all cards when [cardId] is null. Empty
  /// until migration 016 exists.
  Future<List<EmiPlan>> fetchPlans({required String userId, String? cardId}) async {
    await SchemaCapabilities.resolve(_client);
    if (!SchemaCapabilities.emi) return const <EmiPlan>[];
    try {
      final List<Map<String, dynamic>> rows =
          await fetchAllPages(postgrestPages(() {
        final PostgrestFilterBuilder<List<Map<String, dynamic>>> query =
            _client.from(_table).select(_select).eq('user_id', userId);
        return (cardId != null ? query.eq('card_id', cardId) : query)
            .order('created_at', ascending: true)
            .order('id');
      }));
      return rows.map(EmiPlan.fromMap).toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// The claim a plan with a person has: created, renamed or removed to
  /// match the plan.
  Future<void> _syncClaim(String userId, String planId, String? person) async {
    if (person == null) {
      await _client
          .from('receivables')
          .delete()
          .eq('user_id', userId)
          .eq('emi_plan_id', planId);
      return;
    }
    await _client.from('receivables').upsert(
      <String, dynamic>{
        'user_id': userId,
        'kind': 'emi',
        'person': person,
        'emi_plan_id': planId,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      onConflict: 'emi_plan_id',
    );
  }

  /// Creates a plan (and its claim when someone else pays it). Returns its id.
  Future<String> create({required String userId, required EmiPlan plan}) async {
    try {
      final Map<String, dynamic> row = await _client
          .from(_table)
          .insert(<String, dynamic>{'user_id': userId, ...plan.toWriteMap()})
          .select('id')
          .single();
      final String id = row['id'] as String;
      final String? person = plan.toWriteMap()['person'] as String?;
      if (person != null) {
        try {
          await _syncClaim(userId, id, person);
        } catch (_) {
          // A plan whose claim could not be saved would hide what is owed:
          // take it back. Best effort; the original failure is reported.
          try {
            await _client.from(_table).delete().eq('id', id).eq('user_id', userId);
          } catch (_) {}
          rethrow;
        }
      }
      return id;
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<void> update({required String userId, required EmiPlan plan}) async {
    try {
      await _client
          .from(_table)
          .update(<String, dynamic>{
            ...plan.toWriteMap(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', plan.id)
          .eq('user_id', userId);
      await _syncClaim(userId, plan.id, plan.toWriteMap()['person'] as String?);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Removes the plan. Its components stay as they are — plain purchases and
  /// card charges, no longer grouped — and its claim goes with it;
  /// repayments received stay as plain money in.
  Future<void> delete({required String userId, required String id}) async {
    try {
      await _client.from(_table).delete().eq('id', id).eq('user_id', userId);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// How many rows a plan groups, so its delete confirmation can say so.
  Future<({int components, int repayments})> activity({
    required String userId,
    required String id,
  }) async {
    try {
      Future<int> count(String table, String column) async {
        final PostgrestResponse<dynamic> response = await _client
            .from(table)
            .select('id')
            .eq('user_id', userId)
            .eq(column, id)
            .count(CountOption.exact);
        return response.count;
      }

      final List<int> counts = await Future.wait(<Future<int>>[
        count('expenses', 'emi_plan_id'),
        count('credit_card_transactions', 'emi_plan_id'),
      ]);
      final List<Map<String, dynamic>> claim = await _client
          .from('receivables')
          .select('id')
          .eq('user_id', userId)
          .eq('emi_plan_id', id)
          .limit(1);
      int repayments = 0;
      if (claim.isNotEmpty) {
        final PostgrestResponse<dynamic> response = await _client
            .from('account_transactions')
            .select('id')
            .eq('user_id', userId)
            .eq('receivable_id', claim.first['id'] as String)
            .count(CountOption.exact);
        repayments = response.count;
      }
      return (components: counts[0] + counts[1], repayments: repayments);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// The claim (`receivables` kind 'emi') of a plan someone else pays back;
  /// null for the user's own EMI.
  Future<String?> emiClaimIdOf({required String userId, required String planId}) async {
    try {
      final List<Map<String, dynamic>> rows = await _client
          .from('receivables')
          .select('id')
          .eq('user_id', userId)
          .eq('emi_plan_id', planId)
          .limit(1);
      return rows.isEmpty ? null : rows.first['id'] as String?;
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Money in that pays back an EMI someone else owes — a repayment of the
  /// plan's claim, never income (the web app's `recordEmiReimbursement`).
  /// When it replaces an income on the same account, that income's own
  /// ledger row is turned into the repayment in one transaction (the income
  /// row goes with it); otherwise a new credit is saved and the income, if
  /// any, is deleted afterwards. Returns a warning when that last delete
  /// fails, so the caller can say so. [left]: what was still owed when the
  /// form was filled, [allowance] the EMI's rounding allowance past it (₹1
  /// per instalment billed); the database refuses more than that too (017).
  Future<String?> recordEmiReimbursement({
    required String userId,
    required LedgerRepository ledger,
    required IncomeRepository income,
    required EmiPlan plan,
    required String person,
    required String accountId,
    required double amount,
    required DateTime date,
    required double left,
    double allowance = 0,
    String? note,
    ({String id, String? bankAccountId})? fromIncome,
  }) async {
    await SchemaCapabilities.resolve(_client);
    if (!SchemaCapabilities.emi) {
      throw const AppException(
        'EMI reimbursements need the 016 migration. Run '
        'ui/supabase/016_card_statement_emi.sql, then try again.',
      );
    }
    // Rounding up to whole rupees is accepted, up to the EMI's allowance.
    if ((amount * 100).round() > (left * 100).round() + (allowance * 100).round()) {
      throw const AppException(
        'That is more than is still owed on this EMI. The reimbursement may '
        'already be recorded.',
      );
    }
    final String payer = (plan.person ?? person).trim();
    if (plan.person == null) {
      // The user's own EMI becomes someone else's: the plan names them and
      // gets its claim.
      await update(userId: userId, plan: plan.copyWith(person: payer));
    }
    final String? receivableId = await emiClaimIdOf(userId: userId, planId: plan.id);
    if (receivableId == null) {
      throw const AppException(
        'This EMI has no one to pay it back yet. Open the EMI plan and add '
        'who pays it, then try again.',
      );
    }
    final String description = emiRepaymentDescription(plan, payer, note);
    // What the web domain's treatmentPayload builds for a reimbursement.
    final Map<String, Object?> treatment = <String, Object?>{
      'amount': (amount * 100).round() / 100,
      'date': AppDateUtils.toDateString(date),
      'description': description,
      'type': 'settlement',
      'receivable_id': receivableId,
    };

    if (fromIncome != null && fromIncome.bankAccountId == accountId) {
      List<Map<String, dynamic>> rows;
      try {
        rows = await _client
            .from('account_transactions')
            .select('id')
            .eq('user_id', userId)
            .eq('income_id', fromIncome.id)
            .limit(1);
      } catch (error) {
        throw ErrorMapper.map(error);
      }
      if (rows.isNotEmpty) {
        await ledger.applyBankTreatment(
          entryId: rows.first['id'] as String,
          treatment: treatment,
        );
        return null;
      }
    }
    await ledger.recordBankMovement(
      accountId: accountId,
      direction: LedgerDirection.credit,
      amount: amount,
      date: date,
      description: description,
      treatment: treatment,
    );
    if (fromIncome != null) {
      try {
        await income.delete(userId: userId, id: fromIncome.id);
      } catch (_) {
        return 'The reimbursement was recorded, but the income it replaces '
            'could not be deleted. Delete that income by hand so it is not '
            'counted twice.';
      }
    }
    return null;
  }
}
