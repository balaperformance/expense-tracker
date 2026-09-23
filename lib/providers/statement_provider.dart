import '../core/utils/date_utils.dart';
import '../core/utils/formatters.dart';
import '../models/bank_account.dart';
import '../models/ledger_entry.dart';
import '../repositories/ledger_repository.dart';
import 'async_state.dart';

/// Builds the statement for one account and one period.
///
/// The brought-forward opening balance is fetched separately from the period
/// movements, so a filtered month still shows a correct running balance
/// rather than restarting from zero.
class StatementProvider extends AsyncProvider {
  StatementProvider(this._ledger);

  final LedgerRepository _ledger;

  BankAccount? _account;
  AccountStatement? _statement;

  DateTime _month = AppDateUtils.firstDayOf(DateTime.now());
  bool _wholeHistory = false;
  StatementTypeFilter _typeFilter = StatementTypeFilter.all;

  String? _userId;

  AccountStatement? get statement => _statement;
  BankAccount? get account => _account;
  DateTime get month => _month;
  bool get wholeHistory => _wholeHistory;
  StatementTypeFilter get typeFilter => _typeFilter;

  @override
  bool get isEmptyData => _statement == null;

  /// Forward navigation stops at the current month; later months hold nothing.
  bool get canGoForward {
    if (_wholeHistory) return false;
    return _month.isBefore(AppDateUtils.firstDayOf(DateTime.now()));
  }

  String get periodLabel =>
      _wholeHistory ? 'All transactions' : Formatters.monthYear(_month);

  Future<void> open({
    required String userId,
    required BankAccount account,
  }) async {
    _userId = userId;
    _account = account;
    _month = AppDateUtils.firstDayOf(DateTime.now());
    _wholeHistory = false;
    _typeFilter = StatementTypeFilter.all;
    await load();
  }

  Future<void> setMonth(DateTime month) async {
    _month = AppDateUtils.firstDayOf(month);
    _wholeHistory = false;
    await load();
  }

  Future<void> stepMonth(int delta) =>
      setMonth(AppDateUtils.addMonths(_month, delta));

  Future<void> setWholeHistory(bool value) async {
    if (_wholeHistory == value) return;
    _wholeHistory = value;
    await load();
  }

  /// Type filtering is applied to the already-computed rows, so it never
  /// needs another request.
  Future<void> setTypeFilter(StatementTypeFilter filter) async {
    if (_typeFilter == filter) return;
    _typeFilter = filter;
    await load();
  }

  Future<void> load({bool force = false}) async {
    final String? userId = _userId;
    final BankAccount? account = _account;
    if (userId == null || account == null) return;

    setLoading();

    try {
      final MonthRange range = AppDateUtils.monthRange(_month);

      final List<Object> results = await Future.wait(<Future<Object>>[
        _ledger.fetchForAccount(
          userId: userId,
          accountId: account.id,
          from: _wholeHistory ? null : range.start,
          toExclusive: _wholeHistory ? null : range.endExclusive,
        ),
        // Everything before the window, so the statement opens on the real
        // brought-forward figure instead of the account opening balance.
        _wholeHistory
            ? Future<double>.value(0)
            : _ledger.netBefore(
                userId: userId,
                accountId: account.id,
                before: range.start,
              ),
      ]);

      final List<LedgerEntry> entries = results[0] as List<LedgerEntry>;
      final double priorNet = results[1] as double;

      _statement = buildStatement(
        openingBalance: account.openingBalance + priorNet,
        entries: entries,
        typeFilter: _typeFilter,
      );

      setReady();
    } catch (error) {
      setError(error);
    }
  }

  void reset() {
    _account = null;
    _statement = null;
    _userId = null;
    _wholeHistory = false;
    _typeFilter = StatementTypeFilter.all;
    safeNotify();
  }
}
