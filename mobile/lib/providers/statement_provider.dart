import '../core/errors/app_exception.dart';
import '../core/utils/date_utils.dart';
import '../core/utils/formatters.dart';
import '../models/bank_account.dart';
import '../models/ledger_entry.dart';
import '../models/movement_treatment.dart';
import '../models/receivable.dart';
import '../repositories/ledger_repository.dart';
import '../repositories/tag_repository.dart';
import '../services/schema_capabilities.dart';
import '../services/statement_import/statement_engine.dart';
import 'async_state.dart';

/// What the edit sheet of a recorded movement opens with.
class MovementEditContext {
  const MovementEditContext({
    required this.claims,
    this.tags = const <String>[],
    this.incomeSource,
  });

  /// Every claim, with figures: what the movement belongs to, and what a
  /// repayment or reimbursement can pay back.
  final List<ClaimSummary> claims;

  /// The tags it has now — none for a movement that is neither an expense
  /// nor income; null when they could not be read, so they are neither shown
  /// nor changed.
  final List<String>? tags;

  /// An income movement's source.
  final String? incomeSource;
}

/// Builds the statement for one account and one period.
///
/// The brought-forward opening balance is fetched separately from the period
/// movements, so a filtered month still shows a correct running balance
/// rather than restarting from zero.
///
/// It also changes how a recorded movement is recorded (migration 005):
/// the web domain's rules run in the statement engine (the web app's own
/// code, see [StatementEngine]) and `apply_bank_treatment` makes every write
/// in one database transaction.
class StatementProvider extends AsyncProvider {
  StatementProvider(this._ledger, {StatementEngine? engine})
      : _engine = engine ?? MethodChannelStatementEngine();

  final LedgerRepository _ledger;
  final StatementEngine _engine;

  /// Banks can post the two sides of a transfer a day or two apart — the
  /// web's `TRANSFER_MATCH_DAYS`.
  static const int transferMatchDays = 3;

  /// How far back purchases are offered when choosing what a reimbursement
  /// pays back — the web's `PURCHASE_LOOKBACK_DAYS`.
  static const int purchaseLookbackDays = 120;

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

  // ---- Changing how a movement is recorded ----------------------------------

  String get _requireUser {
    final String? userId = _userId;
    if (userId == null) throw const AppException('Please sign in again.');
    return userId;
  }

  /// The claims, tags and income source [entry]'s edit sheet needs. Throws
  /// when the claims or the source cannot be read: opening without them
  /// could mistake money lent for a plain movement, and saving would then
  /// undo the loan.
  Future<MovementEditContext> loadEdit(LedgerEntry entry) async {
    final String userId = _requireUser;
    final List<Object?> read = await Future.wait(<Future<Object?>>[
      SchemaCapabilities.treatments
          ? _ledger.fetchClaims(userId: userId)
          : Future<List<ClaimSummary>>.value(const <ClaimSummary>[]),
      _tagsOf(userId, entry),
      entry.incomeId != null
          ? _ledger.fetchIncomeSource(userId: userId, incomeId: entry.incomeId!)
          : Future<String?>.value(),
    ]);
    return MovementEditContext(
      claims: read[0]! as List<ClaimSummary>,
      tags: read[1] as List<String>?,
      incomeSource: read[2] as String?,
    );
  }

  Future<List<String>?> _tagsOf(String userId, LedgerEntry entry) async {
    final String? expenseId = entry.expenseId;
    final String? incomeId = entry.incomeId;
    if (expenseId == null && incomeId == null) return const <String>[];
    if (!SchemaCapabilities.tags) return null;
    try {
      return await _ledger.fetchTagNames(
        userId: userId,
        kind: expenseId != null ? TagKind.expense : TagKind.income,
        id: expenseId ?? incomeId!,
      );
    } catch (_) {
      return null;
    }
  }

  /// The "Record as" choices for a direction — the engine's `kindsFor` (the
  /// web's `availableKinds`): loans and reimbursements only with 005.
  Future<List<String>> treatmentKinds({required bool debit}) async {
    final Object? kinds = await _engine.call('kindsFor', <String, Object?>{
      'type': debit ? 'debit' : 'credit',
      'treatments': SchemaCapabilities.treatments,
    });
    return (kinds as List<Object?>? ?? const <Object?>[]).whereType<String>().toList();
  }

  /// Purchases a reimbursement received on [date] can pay back: the last
  /// few months, and a few days after.
  Future<List<ClaimPurchase>> purchasesBefore(DateTime date) =>
      _ledger.fetchPurchases(
        userId: _requireUser,
        from: DateTime(date.year, date.month, date.day - purchaseLookbackDays),
        toExclusive: DateTime(date.year, date.month, date.day + 4),
      );

  /// Rows on [accountId] that can be the other leg of a transfer: the
  /// opposite direction, the same amount, within a few days, not already a
  /// transfer leg, card payment or claim — closest first. The rule is the
  /// engine's (`findTransferMatches`); this reads the rows it needs.
  Future<List<LedgerEntry>> transferMatches({
    required String accountId,
    required LedgerDirection direction,
    required double amount,
    required DateTime date,
    required List<ClaimSummary> claims,
  }) async {
    final List<LedgerEntry> rows = await _ledger.fetchForAccount(
      userId: _requireUser,
      accountId: accountId,
      from: DateTime(date.year, date.month, date.day - transferMatchDays),
      toExclusive: DateTime(date.year, date.month, date.day + transferMatchDays + 1),
    );
    if (rows.isEmpty) return const <LedgerEntry>[];
    // A claim's own rows — money lent, a purchase paid for someone — are
    // never the other leg; the engine knows them by their claim.
    final Set<String> lent = <String>{
      for (final ClaimSummary c in claims)
        if (c.receivable.ledgerEntryId != null) c.receivable.ledgerEntryId!,
    };
    final Set<String> paidFor = <String>{
      for (final ClaimSummary c in claims)
        if (c.receivable.expenseId != null) c.receivable.expenseId!,
    };
    final List<Map<String, Object?>> entries = rows
        .map((LedgerEntry e) => EngineJson.ledgerEntry(
              e,
              lent: lent.contains(e.id) || paidFor.contains(e.expenseId),
            ))
        .toList();
    final String day = AppDateUtils.toDateString(date);
    List<String> ids;
    try {
      final Object? found = await _engine.call('transferMatches', <String, Object?>{
        'entries': entries,
        'direction': direction.wire,
        'amount': amount,
        'date': day,
      });
      ids = (found as List<Object?>? ?? const <Object?>[])
          .map((Object? m) => m is Map ? m['id'] as String? : null)
          .whereType<String>()
          .toList();
    } on StatementEngineException catch (error) {
      if (!error.message.startsWith('Unknown engine call')) rethrow;
      // An engine bundle from before `transferMatches`: the import's rule —
      // the single plain row that matches — is still the engine's own.
      final Object? found = await _engine.call('autoMatches', <String, Object?>{
        'operations': <Object?>[
          <String, Object?>{
            'type': 'treatment',
            'itemId': 'edit',
            'autoMatch': true,
            'direction': direction.wire,
            'amount': amount,
            'date': day,
            'request': <String, Object?>{
              'transferTarget': <String, Object?>{'type': 'account', 'accountId': accountId},
            },
          },
        ],
        'entries': entries,
      });
      final Object? id = found is Map ? found['edit'] : null;
      ids = id is String ? <String>[id] : const <String>[];
    }
    final Map<String, LedgerEntry> byId = <String, LedgerEntry>{
      for (final LedgerEntry e in rows) e.id: e,
    };
    return ids.map((String id) => byId[id]).whereType<LedgerEntry>().toList();
  }

  /// Re-treats [entry] as [request] (the web domain's `TreatmentRequest`, see
  /// [buildTreatmentRequest]): the engine turns it into the same JSON the web
  /// app sends, and `apply_bank_treatment` saves every part of it in one
  /// transaction. [tags], for an expense or income, are saved after — on the
  /// row the movement belongs to now. Returns null when everything was saved,
  /// or why the tags were not (the treatment itself was saved). Reloads the
  /// statement either way.
  Future<String?> applyTreatment({
    required LedgerEntry entry,
    required Map<String, Object?> request,
    ({TagKind kind, List<String> names})? tags,
  }) async {
    if (!SchemaCapabilities.treatments) {
      throw const AppException(
        'This needs the 005 migration. Run ui/supabase/005_transaction_treatments.sql, then try again.',
      );
    }
    final String userId = _requireUser;
    final Map<String, Object?> payload;
    try {
      final Object? body = await _engine.call(
        'treatmentPayload',
        <String, Object?>{'request': request},
      );
      if (body is! Map) throw const AppException('Could not update the transaction.');
      payload = Map<String, Object?>.from(body);
    } on StatementEngineException catch (error) {
      throw AppException(error.code == 'engineUnavailable'
          ? 'Changing how a transaction is recorded is available in the Android app.'
          : error.message);
    }
    await _ledger.applyBankTreatment(entryId: entry.id, treatment: payload);

    String? tagError;
    if (tags != null && SchemaCapabilities.tags) {
      try {
        // The treatment may have just created the expense or income row.
        final ({String? expenseId, String? incomeId}) linked =
            await _ledger.documentsOfEntry(userId: userId, entryId: entry.id);
        final String? id =
            tags.kind == TagKind.expense ? linked.expenseId : linked.incomeId;
        if (id == null) {
          tagError = 'Could not save the tags.';
        } else {
          await _ledger.setDocumentTags(kind: tags.kind, id: id, names: tags.names);
        }
      } catch (error) {
        tagError = ErrorMapper.map(error).message;
      }
    }
    await load(force: true);
    return tagError;
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
