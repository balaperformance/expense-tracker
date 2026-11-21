import '../models/balance_adjustment.dart';
import '../repositories/balance_adjustment_repository.dart';
import '../services/schema_capabilities.dart';
import 'async_state.dart';

/// Each account's balance adjustments (migration 021): the history shown on
/// the account's statement, and the actions that add and remove them.
///
/// Balances themselves are not kept here — the database writes one ledger row
/// per adjustment, so the balances BankAccountProvider and StatementProvider
/// derive from the ledger already include it. After a change the caller
/// reloads those.
class BalanceAdjustmentProvider extends AsyncProvider {
  BalanceAdjustmentProvider(this._repository);

  final BalanceAdjustmentRepository _repository;

  final Map<String, List<BalanceAdjustment>> _byAccount = <String, List<BalanceAdjustment>>{};
  String? _userId;

  bool get available => SchemaCapabilities.balanceAdjustments;

  @override
  bool get isEmptyData => _byAccount.isEmpty;

  /// Newest first; empty until loaded or before the migration.
  List<BalanceAdjustment> forAccount(String accountId) =>
      List<BalanceAdjustment>.unmodifiable(_byAccount[accountId] ?? const <BalanceAdjustment>[]);

  /// The latest adjustment on the account, if any.
  BalanceAdjustment? latestFor(String accountId) {
    final List<BalanceAdjustment> list = _byAccount[accountId] ?? const <BalanceAdjustment>[];
    return list.isEmpty ? null : list.first;
  }

  BalanceAdjustment? byId(String? id) {
    if (id == null) return null;
    for (final List<BalanceAdjustment> list in _byAccount.values) {
      for (final BalanceAdjustment a in list) {
        if (a.id == id) return a;
      }
    }
    return null;
  }

  Future<void> load({required String userId, required String accountId, bool force = false}) async {
    if (_userId != userId) {
      _userId = userId;
      _byAccount.clear();
    }
    if (!available) {
      setReady();
      return;
    }
    if (!force && _byAccount.containsKey(accountId)) return;
    if (!_byAccount.containsKey(accountId)) setLoading();
    try {
      _byAccount[accountId] = newestFirst(
        await _repository.fetchForAccount(userId: userId, accountId: accountId),
      );
      setReady();
    } catch (error) {
      setError(error);
    }
  }

  /// Sets the account's balance on [date] to [balance], then re-reads its
  /// history. False with [errorMessage] when the database refused it.
  Future<bool> adjust({
    required String accountId,
    required double balance,
    required DateTime date,
    String? remarks,
  }) async {
    final String? userId = _userId;
    final bool ok = await guard(() async {
      await _repository.adjust(accountId: accountId, balance: balance, date: date, remarks: remarks);
    });
    if (ok && userId != null) await load(userId: userId, accountId: accountId, force: true);
    return ok;
  }

  Future<bool> remove(BalanceAdjustment adjustment) async {
    final String? userId = _userId;
    if (userId == null) return false;
    final bool ok = await guard(() => _repository.remove(userId: userId, id: adjustment.id));
    if (ok) await load(userId: userId, accountId: adjustment.accountId, force: true);
    return ok;
  }

  void reset() {
    _byAccount.clear();
    _userId = null;
    safeNotify();
  }
}
