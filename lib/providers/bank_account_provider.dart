import '../core/constants/app_constants.dart';
import '../core/errors/app_exception.dart';
import '../core/utils/formatters.dart';
import '../models/bank_account.dart';
import '../models/money_transfer.dart';
import '../repositories/bank_account_repository.dart';
import '../repositories/ledger_repository.dart';
import '../services/schema_capabilities.dart';
import 'async_state.dart';

/// Bank accounts and their ledger-derived balances.
///
/// Balances are recomputed from the ledger on every load rather than cached
/// as a number anywhere, so they cannot drift from the movements that produced
/// them.
class BankAccountProvider extends AsyncProvider {
  BankAccountProvider({
    required BankAccountRepository accounts,
    required LedgerRepository ledger,
  })  : _accounts = accounts,
        _ledger = ledger;

  final BankAccountRepository _accounts;
  final LedgerRepository _ledger;

  List<BankAccountBalance> _balances = <BankAccountBalance>[];
  String? _userId;
  bool _stale = true;

  /// Bumped whenever a movement is written, so dependent screens can tell
  /// their figures are out of date.
  int _revision = 0;

  List<BankAccountBalance> get balances =>
      List<BankAccountBalance>.unmodifiable(_balances);

  List<BankAccount> get accounts =>
      _balances.map((BankAccountBalance b) => b.account).toList();

  int get revision => _revision;

  /// False until the Phase 2 migration has been applied.
  bool get available => SchemaCapabilities.bankAccounts;

  /// Transfers additionally need migration 003.
  bool get transfersAvailable => available && SchemaCapabilities.transfers;

  /// A transfer needs somewhere to send the money to.
  bool get canTransfer => transfersAvailable && _balances.length >= 2;

  bool get hasAccounts => _balances.isNotEmpty;

  @override
  bool get isEmptyData => _balances.isEmpty;

  double get totalBalance => _balances.fold<double>(
        0,
        (double sum, BankAccountBalance b) => sum + b.currentBalance,
      );

  BankAccount? byId(String? id) {
    if (id == null) return null;
    for (final BankAccountBalance b in _balances) {
      if (b.account.id == id) return b.account;
    }
    return null;
  }

  BankAccountBalance? balanceFor(String id) {
    for (final BankAccountBalance b in _balances) {
      if (b.account.id == id) return b;
    }
    return null;
  }

  void invalidate() => _stale = true;

  Future<void> load({required String userId, bool force = false}) async {
    if (_userId != userId) {
      _userId = userId;
      _stale = true;
    }
    // If the feature looks unavailable, re-probe before giving up: the
    // migration may have been applied since this process started. The extra
    // requests only happen while the tables are genuinely missing.
    if (!available) {
      try {
        await _accounts.refreshCapabilities();
      } catch (error) {
        setError(error);
        return;
      }
    }
    if (!available) {
      setReady();
      return;
    }
    if (!_stale && !force && isReady) return;

    if (_balances.isEmpty) setLoading();

    try {
      _balances = await _accounts.fetchWithBalances(userId);
      _stale = false;
      setReady();
    } catch (error) {
      setError(error);
    }
  }

  Future<bool> create({
    required String bankName,
    required String nickname,
    String? last4,
    required double openingBalance,
  }) async {
    final String? userId = _userId;
    if (userId == null) return false;

    final bool ok = await guard(() async {
      await _accounts.create(BankAccount(
        id: '',
        userId: userId,
        bankName: bankName,
        nickname: nickname,
        last4: last4,
        openingBalance: openingBalance,
      ));
    });

    if (ok) await _reload();
    return ok;
  }

  Future<bool> update(BankAccount account) async {
    final String? userId = _userId;
    if (userId == null) return false;

    final bool ok = await guard(() async {
      await _accounts.update(account);
    });

    if (ok) await _reload();
    return ok;
  }

  Future<bool> delete(String accountId) async {
    final String? userId = _userId;
    if (userId == null) return false;

    final bool ok = await guard(() async {
      await _accounts.delete(userId: userId, id: accountId);
    });

    if (ok) await _reload();
    return ok;
  }

  Future<int> movementCount(String accountId) async {
    final String? userId = _userId;
    if (userId == null) return 0;
    return _accounts.movementCount(userId: userId, accountId: accountId);
  }

  /// Adds money to an account as a ledger credit.
  Future<bool> deposit({
    required String accountId,
    required double amount,
    required DateTime date,
    String? description,
  }) async {
    final String? userId = _userId;
    if (userId == null) return false;

    final bool ok = await guard(() async {
      await _ledger.deposit(
        userId: userId,
        accountId: accountId,
        amount: amount,
        date: date,
        description: description,
      );
    });

    if (ok) await _reload();
    return ok;
  }

  /// Records money leaving an account that is not an expense (bank charge,
  /// ATM withdrawal moved to cash, and so on).
  Future<bool> withdraw({
    required String accountId,
    required double amount,
    required DateTime date,
    String? description,
  }) async {
    final String? userId = _userId;
    if (userId == null) return false;

    final bool ok = await guard(() async {
      await _ledger.withdraw(
        userId: userId,
        accountId: accountId,
        amount: amount,
        date: date,
        description: description,
      );
    });

    if (ok) await _reload();
    return ok;
  }

  /// Moves money between two of the user's own accounts.
  ///
  /// The sufficient-funds check is deliberately made here, against a balance
  /// re-derived from the ledger a moment before the write, rather than
  /// against [balances] — which may have been on screen for a while and may
  /// predate an expense recorded since. The comparison is in whole cents so
  /// transferring exactly the full balance is not rejected by float noise.
  ///
  /// Returns false and sets [errorMessage] on any validation failure.
  Future<bool> transfer({
    required String? fromAccountId,
    required String? toAccountId,
    required double? amount,
    required DateTime date,
    String? note,
    String currencyCode = AppConstants.defaultCurrencyCode,
  }) async {
    final String? userId = _userId;
    if (userId == null) return false;

    final TransferDraft draft = TransferDraft(
      fromAccountId: fromAccountId,
      toAccountId: toAccountId,
      amount: amount,
      date: date,
      note: note,
    );

    final bool ok = await guard(() async {
      if (!transfersAvailable) {
        throw const AppException(
          'Transfers need the 003 migration. Run '
          'supabase/003_phase2_transfers.sql, then try again.',
        );
      }

      final BankAccount? from = byId(draft.fromAccountId);
      final BankAccount? to = byId(draft.toAccountId);

      // Shape rules first: they need no database round trip, and checking
      // them before reading a balance keeps a same-account mistake from
      // costing a request.
      final TransferProblem? shape = TransferValidation.check(
        draft: draft,
        availableBalance: null,
      );
      if (shape != null) throw AppException(shape.message());

      if (from == null) {
        throw AppException(TransferProblem.noSource.message());
      }
      if (to == null) {
        throw AppException(TransferProblem.noDestination.message());
      }

      final double net =
          await _ledger.netFor(userId: userId, accountId: from.id);
      final double available = from.openingBalance + net;

      final TransferProblem? problem = TransferValidation.check(
        draft: draft,
        availableBalance: available,
      );
      if (problem != null) {
        throw AppException(problem.message(
          sourceLabel: from.nickname,
          availableText: Formatters.currency(available, currencyCode: currencyCode),
        ));
      }

      await _ledger.transfer(
        userId: userId,
        fromAccountId: from.id,
        toAccountId: to.id,
        fromLabel: from.nickname,
        toLabel: to.nickname,
        amount: draft.amount!,
        date: draft.date,
        note: draft.trimmedNote,
      );
    });

    if (ok) await _reload();
    return ok;
  }

  /// Removes both legs of a transfer together.
  Future<bool> deleteTransfer(String transferGroupId) async {
    final String? userId = _userId;
    if (userId == null) return false;

    final bool ok = await guard(() async {
      await _ledger.deleteTransfer(
        userId: userId,
        transferGroupId: transferGroupId,
      );
    });

    if (ok) await _reload();
    return ok;
  }

  Future<bool> deleteEntry(String entryId) async {
    final String? userId = _userId;
    if (userId == null) return false;

    final bool ok = await guard(() async {
      await _ledger.deleteEntry(userId: userId, id: entryId);
    });

    if (ok) await _reload();
    return ok;
  }

  Future<void> _reload() async {
    final String? userId = _userId;
    if (userId == null) return;
    _stale = true;
    _revision++;
    await load(userId: userId, force: true);
  }

  void reset() {
    _balances = <BankAccountBalance>[];
    _userId = null;
    _stale = true;
    safeNotify();
  }
}
