import 'dart:convert';

import 'package:flutter/services.dart';

import '../../core/errors/app_exception.dart';
import '../../core/utils/date_utils.dart';
import '../../models/bank_account.dart';
import '../../models/credit_card.dart';
import '../../models/expense_category.dart';
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
/// implementation, shared with the web app.
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
      };

  /// A recorded ledger row in the web model's full shape, for finding a
  /// transfer's other leg. [lent]: the row is money lent (a claim's source),
  /// which is never a plain movement.
  static Map<String, Object?> ledgerEntry(LedgerEntry e, {bool lent = false}) =>
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
        'claim': lent
            ? const <String, Object?>{
                'receivableId': '',
                'kind': 'loan',
                'person': '',
                'role': 'source',
              }
            : null,
        'createdAt': _iso(e.createdAt),
        'category': null,
      };
}
