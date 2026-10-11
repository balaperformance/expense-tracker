import 'dart:convert';

import 'package:flutter/services.dart';

import '../../core/errors/app_exception.dart';
import '../../core/utils/date_utils.dart';
import '../../models/bank_account.dart';
import '../../models/card_statement.dart';
import '../../models/credit_card.dart';
import '../../models/expense.dart';
import '../../models/expense_category.dart';
import '../../models/income.dart';
import '../../models/ledger_entry.dart';
import '../../models/payment_method.dart';

/// A statement file the user picked, held natively until released.
class PickedStatementFile {
  const PickedStatementFile({
    required this.token,
    required this.name,
    required this.size,
  });

  final String token;
  final String name;
  final int size;
}

/// A failure from the engine, with the web reader's code: passwordRequired,
/// passwordIncorrect, notPdf, unsupportedFormat, scanned, tooLarge, failed —
/// plus engineUnavailable and timeout from the Android host.
class StatementEngineException extends AppException {
  const StatementEngineException(this.code, super.message);

  final String code;

  bool get needsPassword =>
      code == 'passwordRequired' || code == 'passwordIncorrect';
}

/// The statement-import engine: the web app's own statement parsers,
/// classification, duplicate rules, review edits and import plan, running
/// offline on the phone (see `assets/statement_engine/engine.js` and
/// MainActivity.kt). Nothing here parses statements itself — there is one
/// implementation, shared with the web app. The same engine computes the
/// Reports insights (InsightsProvider).
abstract class StatementEngine {
  /// The system document picker; null when the user cancels.
  Future<PickedStatementFile?> pickFile();

  /// One engine function: JSON-shaped arguments in, JSON-shaped value out.
  Future<Object?> call(String name, Map<String, Object?> args);

  /// Forgets a picked file's bytes.
  Future<void> release(String token);
}

class MethodChannelStatementEngine implements StatementEngine {
  MethodChannelStatementEngine([
    this._channel = const MethodChannel('expense_tracker/statement_engine'),
  ]);

  final MethodChannel _channel;

  @override
  Future<PickedStatementFile?> pickFile() async {
    final Map<Object?, Object?>? reply;
    try {
      reply = await _channel.invokeMapMethod<Object?, Object?>('pickFile');
    } on PlatformException catch (error) {
      throw StatementEngineException(
        error.code,
        error.message ?? 'No file could be opened.',
      );
    } on MissingPluginException {
      throw const StatementEngineException(
        'engineUnavailable',
        'Statement import is available in the Android app.',
      );
    }
    if (reply == null) return null;
    final Object? error = reply['error'];
    if (error != null) {
      throw StatementEngineException(
        error as String,
        error == 'tooLarge'
            ? 'That file is larger than 20 MB — too big for one statement.'
            : 'That file could not be opened. Download it again and retry.',
      );
    }
    return PickedStatementFile(
      token: reply['token']! as String,
      name: (reply['name'] as String?) ?? 'statement',
      size: (reply['size'] as int?) ?? 0,
    );
  }

  @override
  Future<Object?> call(String name, Map<String, Object?> args) async {
    final String? raw;
    try {
      raw = await _channel.invokeMethod<String>(
        'call',
        <String, Object?>{'name': name, 'args': jsonEncode(args)},
      );
    } on PlatformException catch (error) {
      throw StatementEngineException(
        error.code,
        error.message ?? 'The statement reader stopped unexpectedly.',
      );
    } on MissingPluginException {
      throw const StatementEngineException(
        'engineUnavailable',
        'Statement import is available in the Android app.',
      );
    }
    final Map<String, Object?> reply =
        (jsonDecode(raw ?? '{}') as Map<String, Object?>);
    if (reply['ok'] == true) return reply['value'];
    final Map<String, Object?> failure =
        (reply['error'] as Map<String, Object?>?) ?? const <String, Object?>{};
    throw StatementEngineException(
      (failure['code'] as String?) ?? 'failed',
      (failure['message'] as String?) ?? 'The statement could not be read.',
    );
  }

  @override
  Future<void> release(String token) async {
    try {
      await _channel.invokeMethod<void>('release', <String, Object?>{'token': token});
    } catch (_) {
      // Forgetting bytes is best-effort; the app process frees them anyway.
    }
  }
}

/// The app's rows in the shapes the engine (the web domain) expects.
class EngineJson {
  const EngineJson._();

  static String? _iso(DateTime? value) => value?.toUtc().toIso8601String();

  static Map<String, Object?> account(BankAccount a) => <String, Object?>{
        'id': a.id,
        'userId': a.userId,
        'bankName': a.bankName,
        'nickname': a.nickname,
        'last4': a.last4,
        'openingBalance': a.openingBalance,
        'isActive': a.isActive,
        'createdAt': _iso(a.createdAt),
        // A withdrawal is a transfer into the cash account when there is one.
        'kind': a.kind.wire,
      };

  static Map<String, Object?> category(ExpenseCategory c) => <String, Object?>{
        'id': c.id,
        'userId': c.userId,
        'name': c.name,
        'icon': c.icon,
        'color': c.color,
        'isDefault': c.isDefault,
        'createdAt': _iso(c.createdAt),
      };

  static Map<String, Object?> card(CreditCard c) => <String, Object?>{
        'id': c.id,
        'userId': c.userId,
        'cardName': c.cardName,
        'issuer': c.issuer,
        'network': c.network?.wire,
        'last4': c.last4,
        'creditLimit': c.creditLimit,
        'openingOutstanding': c.openingOutstanding,
        'statementDay': c.statementDay,
        'paymentDueDay': c.paymentDueDay,
        'paymentAccountId': c.paymentAccountId,
        'isActive': c.isActive,
        'notes': c.notes,
        'createdAt': _iso(c.createdAt),
      };

  static Map<String, Object?> paymentMethod(PaymentMethod m) =>
      <String, Object?>{
        'id': m.id,
        'userId': m.userId,
        'name': m.name,
        'createdAt': _iso(m.createdAt),
      };

  /// A recorded ledger row, as the duplicate check sees it. Its reference and
  /// UPI ID (migration 007) let a payment be recognised whatever its date.
  static Map<String, Object?> existing(LedgerEntry e) => <String, Object?>{
        'accountId': e.accountId,
        'date': AppDateUtils.toDateString(e.txnDate),
        'amount': e.amount,
        'direction': e.direction.wire,
        'description': e.description,
        'creditCardId': e.creditCardId,
        if (e.reference != null) 'reference': e.reference,
        if (e.upiId != null) 'upiId': e.upiId,
        // The expense or income it belongs to: an entry the ledger check has
        // matched is not offered again as a possible duplicate.
        if (e.expenseId != null) 'expenseId': e.expenseId,
        if (e.incomeId != null) 'incomeId': e.incomeId,
      };

  /// A recorded expense — on any account or none — as the possible-duplicate
  /// check sees it (the web's `recordedFromExpense`).
  static Map<String, Object?> recordedExpense(Expense e) => <String, Object?>{
        'id': e.id,
        'kind': 'expense',
        'date': AppDateUtils.toDateString(e.expenseDate),
        'amount': e.amount,
        'merchant': e.merchant,
        'description': e.description,
        'notes': e.notes,
        'category': e.category?.name,
        'paymentMethod': e.paymentMethod?.name,
        'bankAccountId': e.bankAccountId,
        'creditCardId': e.creditCardId,
      };

  /// Recorded income, likewise (the web's `recordedFromIncome`).
  static Map<String, Object?> recordedIncome(Income i) => <String, Object?>{
        'id': i.id,
        'kind': 'income',
        'date': AppDateUtils.toDateString(i.incomeDate),
        'amount': i.amount,
        'merchant': null,
        'description': i.description,
        'notes': null,
        'category': i.source,
        'paymentMethod': null,
        'bankAccountId': i.bankAccountId,
        'creditCardId': null,
      };

  /// A recorded ledger row in the web model's full shape, for finding a
  /// transfer's other leg and for reconciling a statement. [lent]: the row is
  /// what was paid for someone (a claim's source) with no expense of its own,
  /// which is never a plain movement. [claim]: the claim it belongs to, when
  /// known — {receivableId, person, role: 'source' | 'settles'}.
  static Map<String, Object?> ledgerEntry(
    LedgerEntry e, {
    bool lent = false,
    Map<String, Object?>? claim,
  }) =>
      <String, Object?>{
        'id': e.id,
        'userId': e.userId,
        'accountId': e.accountId,
        'direction': e.direction.wire,
        'amount': e.amount,
        'txnDate': AppDateUtils.toDateString(e.txnDate),
        'description': e.description,
        'categoryId': e.categoryId,
        'expenseId': e.expenseId,
        'incomeId': e.incomeId,
        'transferGroupId': e.transferGroupId,
        'counterpartyAccountId': e.counterpartyAccountId,
        'creditCardId': e.creditCardId,
        'receivableId': e.receivableId,
        'claim': claim ??
            (lent
                ? const <String, Object?>{
                    'receivableId': '',
                    'person': '',
                    'role': 'source',
                  }
                : null),
        'createdAt': _iso(e.createdAt),
        'category': e.category == null ? null : category(e.category!),
        if (e.reference != null) 'reference': e.reference,
        if (e.upiId != null) 'upiId': e.upiId,
      };

  /// One movement on a card (a purchase, a bill payment or the card's own
  /// entry) in the web model's shape — its key is the web's too.
  static Map<String, Object?> cardEntry(CardEntry e) => <String, Object?>{
        'key': e.key,
        'source': e.source.name,
        'id': e.id,
        'cardId': e.cardId,
        'kind': e.kind.name,
        'direction': e.direction.wire,
        'amount': e.amount,
        'date': AppDateUtils.toDateString(e.date),
        'description': e.description,
        'category': e.category == null ? null : category(e.category!),
        'accountId': e.accountId,
        'originalExpenseId': e.originalExpenseId,
        'reference': e.reference,
        'createdAt': _iso(e.createdAt),
      };
}
