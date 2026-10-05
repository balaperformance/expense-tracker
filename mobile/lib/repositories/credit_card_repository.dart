import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors/app_exception.dart';
import '../core/utils/date_utils.dart';
import '../models/card_statement.dart';
import '../models/credit_card.dart';
import '../models/expense.dart';
import '../models/ledger_entry.dart';
import '../services/schema_capabilities.dart';
import 'expense_repository.dart';
import 'ledger_repository.dart';
import 'paging.dart';

/// `public.credit_cards` and `public.credit_card_transactions` (migration
/// 004, shared with the web app).
///
/// A card's outstanding is never read from a stored column: it is derived
/// from the opening outstanding and the card's movements, which live in three
/// tables — purchases in `expenses`, bill payments from an account in
/// `account_transactions`, everything else in `credit_card_transactions`.
/// [fetchEntries] reads all three and merges them; nothing is copied.
class CreditCardRepository {
  CreditCardRepository(
    this._client, {
    required ExpenseRepository expenses,
    required LedgerRepository ledger,
  })  : _expenses = expenses,
        _ledger = ledger;

  final SupabaseClient _client;
  final ExpenseRepository _expenses;
  final LedgerRepository _ledger;

  static const String _cards = 'credit_cards';
  static const String _transactions = 'credit_card_transactions';
  static const String _cardSelect =
      'id, user_id, card_name, issuer, network, last4, credit_limit, '
      'opening_outstanding, statement_day, payment_due_day, '
      'payment_account_id, is_active, notes, created_at';
  static const String _transactionSelect =
      'id, user_id, card_id, kind, direction, amount, txn_date, description, '
      'reference, original_expense_id, created_at';

  /// Fees, interest, refunds and cashback since [from], signed the way the
  /// reports read them: a fee or interest is a positive charge (a credit of
  /// either kind reverses one), a refund or cashback a positive amount back.
  Future<List<CardTransaction>> fetchCharges({
    required String userId,
    required DateTime from,
  }) async {
    await SchemaCapabilities.resolve(_client);
    if (!SchemaCapabilities.creditCards) return const <CardTransaction>[];
    try {
      final List<Map<String, dynamic>> rows =
          await fetchAllPages(postgrestPages(() => _client
              .from(_transactions)
              .select(_transactionSelect)
              .eq('user_id', userId)
              .inFilter('kind', <String>['fee', 'interest', 'refund', 'cashback'])
              .gte('txn_date', AppDateUtils.toDateString(from))
              .order('id')));
      return rows.map(CardTransaction.fromMap).toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Re-probes the schema, so the feature appears as soon as 004 is applied.
  Future<void> refreshCapabilities() =>
      SchemaCapabilities.resolve(_client, force: true);

  Future<List<CreditCard>> fetchCards(String userId) async {
    try {
      final List<Map<String, dynamic>> rows = await _client
          .from(_cards)
          .select(_cardSelect)
          .eq('user_id', userId)
          .order('created_at', ascending: true);
      return rows.map(CreditCard.fromMap).toList();
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// Every movement on one card — or on all of the user's cards when
  /// [cardId] is null — over the whole history, from the three tables.
  Future<List<CardEntry>> fetchEntries({
    required String userId,
    String? cardId,
  }) async {
    await SchemaCapabilities.resolve(_client);
    if (!SchemaCapabilities.creditCards) return <CardEntry>[];
    try {
      final List<Object> results = await Future.wait(<Future<Object>>[
        _expenses.fetchForCreditCard(userId: userId, cardId: cardId),
        _ledger.fetchCardPayments(userId: userId, cardId: cardId),
        fetchAllPages(postgrestPages(() {
          final PostgrestFilterBuilder<List<Map<String, dynamic>>> query =
              _client
                  .from(_transactions)
                  .select(_transactionSelect)
                  .eq('user_id', userId);
          return (cardId != null ? query.eq('card_id', cardId) : query)
              .order('id');
        })),
      ]);
      return <CardEntry>[
        ...(results[0] as List<Expense>)
            .map(CardEntry.fromExpense)
            .whereType<CardEntry>(),
        ...(results[1] as List<LedgerEntry>)
            .map(CardEntry.fromPayment)
            .whereType<CardEntry>(),
        ...(results[2] as List<Map<String, dynamic>>)
            .map((Map<String, dynamic> row) =>
                CardEntry.fromCardTransaction(CardTransaction.fromMap(row))),
      ];
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<void> create(CreditCard card) async {
    try {
      await _client.from(_cards).insert(<String, dynamic>{
        'user_id': card.userId,
        ...card.toWriteMap(),
      });
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<void> update(CreditCard card) async {
    try {
      await _client
          .from(_cards)
          .update(<String, dynamic>{
            ...card.toWriteMap(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', card.id)
          .eq('user_id', card.userId);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// The database removes the card's own transactions, reverts its purchases
  /// to Cash expenses and keeps its bill payments as plain bank debits (the
  /// money did leave those accounts).
  Future<void> delete({required String userId, required String id}) async {
    try {
      await _client.from(_cards).delete().eq('id', id).eq('user_id', userId);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<void> recordTransaction({
    required String userId,
    required String cardId,
    required CardTransactionKind kind,
    required LedgerDirection direction,
    required double amount,
    required DateTime date,
    String? description,
    String? reference,
    String? originalExpenseId,
  }) async {
    String? blank(String? value) {
      final String? trimmed = value?.trim();
      return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    }

    try {
      await _client.from(_transactions).insert(<String, dynamic>{
        'user_id': userId,
        'card_id': cardId,
        'kind': kind.wire,
        'direction': direction.wire,
        'amount': amount,
        'txn_date': AppDateUtils.toDateString(date),
        'description': blank(description),
        'reference': blank(reference),
        'original_expense_id':
            kind == CardTransactionKind.refund ? originalExpenseId : null,
      });
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  Future<void> deleteTransaction({
    required String userId,
    required String id,
  }) async {
    try {
      await _client
          .from(_transactions)
          .delete()
          .eq('id', id)
          .eq('user_id', userId);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }

  /// How much a card holds, so its delete confirmation can say what happens
  /// to each part. Throws rather than returning a silent 0 that would make
  /// the warning lie.
  Future<({int purchases, int payments, int others})> activity({
    required String userId,
    required String cardId,
  }) async {
    Future<int> count(String table, String column) async {
      final PostgrestResponse<List<Map<String, dynamic>>> response =
          await _client
              .from(table)
              .select('id')
              .eq('user_id', userId)
              .eq(column, cardId)
              .count(CountOption.exact);
      return response.count;
    }

    try {
      final List<int> counts = await Future.wait(<Future<int>>[
        count('expenses', 'credit_card_id'),
        count('account_transactions', 'credit_card_id'),
        count(_transactions, 'card_id'),
      ]);
      return (purchases: counts[0], payments: counts[1], others: counts[2]);
    } catch (error) {
      throw ErrorMapper.map(error);
    }
  }
}
