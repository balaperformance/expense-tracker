import '../core/utils/date_utils.dart';
import '../models/bank_account.dart';
import '../models/card_statement.dart';
import '../models/credit_card.dart';
import '../models/expense.dart';
import '../models/income.dart';
import '../models/ledger_entry.dart';
import '../models/receivable.dart';
import '../repositories/credit_card_repository.dart';
import '../repositories/expense_repository.dart';
import '../repositories/income_repository.dart';
import '../repositories/ledger_repository.dart';
import '../repositories/reconciliation_repository.dart';
import '../services/schema_capabilities.dart';
import '../services/statement_import/statement_engine.dart';
import 'async_state.dart';

/// One verdict of a reconciliation — a typed view over the engine's JSON,
/// with the words the engine wrote for it (the web app shows the same).
class ReconItem {
  const ReconItem(this.json, this.text);

  final Map<String, Object?> json;
  final Map<String, Object?> text;

  String get id => json['id']! as String;

  /// What a decision about it names: the statement line's key, or entry:<id>.
  String get key => json['key']! as String;

  /// "account:<id>", "card:<id>", or '' for a row whose account is not known.
  String get scope => (json['scope'] as String?) ?? '';

  /// matched, missing, duplicate, mismatch or review.
  String get status => json['status']! as String;
  String get issue => json['issue']! as String;
  String get kind => (json['kind'] as String?) ?? 'other';
  String get isoDate => json['date']! as String;
  DateTime get date => AppDateUtils.parseDate(isoDate);
  double get amount => (json['amount'] as num?)?.toDouble() ?? 0;
  bool get isDebit => json['direction'] == 'debit';
  double? get difference => (json['difference'] as num?)?.toDouble();
  double get balanceEffect => (json['balanceEffect'] as num?)?.toDouble() ?? 0;
  List<String> get reasons =>
      ((json['reasons'] as List<Object?>?) ?? const <Object?>[]).whereType<String>().toList();

  /// 'link' or 'dismiss' when the user decided it; null otherwise.
  String? get decision => json['decision'] as String?;

  /// Accepted as it is by the user: still shown, no longer open.
  bool get resolved => json['resolved'] == true;

  Map<String, Object?>? _map(String key) =>
      json[key] is Map ? (json[key]! as Map).cast<String, Object?>() : null;

  /// The statement's side: {key, itemId, date, amount, direction,
  /// rawDescription, counterparty, description, reference, upiId, time,
  /// statementIds, …}, or null for something only the app has.
  Map<String, Object?>? get line => _map('line');

  /// The app's side: {id, date, amount, direction, description, kind,
  /// person, category, reference, open: {type, id, accountId?, cardId?}}.
  Map<String, Object?>? get movement => _map('movement');

  /// An entry recorded elsewhere it looks like (no account, another account
  /// or a card): {entryId, kind, label, date, amount, accountId, cardId}.
  Map<String, Object?>? get elsewhere => _map('elsewhere');

  /// The movement this one repeats, for a duplicate in the app.
  Map<String, Object?>? get duplicateOf => _map('duplicateOf');

  List<Map<String, Object?>> _list(String key) =>
      ((json[key] as List<Object?>?) ?? const <Object?>[])
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> m) => m.cast<String, Object?>())
          .toList();

  /// Recorded movements a statement row could be linked to, closest first.
  List<Map<String, Object?>> get candidates => _list('candidates');

  /// Statement rows a recorded movement could be linked to, closest first.
  List<Map<String, Object?>> get lineCandidates => _list('lineCandidates');

  String get title => (text['title'] as String?) ?? issue;
  String get explanation => (text['explanation'] as String?) ?? '';

  /// What the row is called in a list: the payee, else the description.
  String get name {
    final Map<String, Object?>? l = line;
    if (l != null) {
      final String? who = (l['counterparty'] as String?)?.trim();
      return who != null && who.isNotEmpty ? who : (l['description'] as String?) ?? '';
    }
    return (movement?['description'] as String?) ?? '';
  }
}

/// One account's or card's figures for the reconciled period.
class ReconScope {
  const ReconScope(this.json, this.text);

  final Map<String, Object?> json;
  final Map<String, Object?> text;

  String get key => json['key']! as String;
  bool get isCard => json['type'] == 'card';
  bool get partial => json['coverage'] == 'partial';
  DateTime get from => AppDateUtils.parseDate(json['from']! as String);
  DateTime get to => AppDateUtils.parseDate(json['to']! as String);
  List<String> get statementIds =>
      ((json['statementIds'] as List<Object?>?) ?? const <Object?>[]).whereType<String>().toList();

  Map<String, Object?> _side(String key) =>
      (json[key] as Map<Object?, Object?>?)?.cast<String, Object?>() ?? const <String, Object?>{};
  double? _num(Map<String, Object?> side, String key) => (side[key] as num?)?.toDouble();

  double? get statementOpening => _num(_side('statement'), 'opening');
  double? get statementClosing => _num(_side('statement'), 'closing');
  double get statementCredits => _num(_side('statement'), 'credits') ?? 0;
  double get statementDebits => _num(_side('statement'), 'debits') ?? 0;
  double? get appOpening => _num(_side('app'), 'opening');
  double? get appClosing => _num(_side('app'), 'closing');
  double get appCredits => _num(_side('app'), 'credits') ?? 0;
  double get appDebits => _num(_side('app'), 'debits') ?? 0;

  /// The period's movements by kind: [{kind, statement, app}].
  List<Map<String, Object?>> get byKind =>
      ((json['byKind'] as List<Object?>?) ?? const <Object?>[])
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> m) => m.cast<String, Object?>())
          .toList();

  String get label => (text['label'] as String?) ?? '';
  String get headline => (text['headline'] as String?) ?? '';
  List<String> get lines =>
      ((text['lines'] as List<Object?>?) ?? const <Object?>[]).whereType<String>().toList();

  /// True when the balances agree, false when they differ, null when the
  /// statement does not print them (or only a payment app's covers it).
  bool? get agrees => text['agrees'] as bool?;
}

/// What the dashboard narrows the items to. Null fields do not filter.
class ReconFilter {
  const ReconFilter({this.status = 'open', this.scope, this.statementId, this.kind, this.from, this.to});

  /// A status, 'open' (everything to resolve) or 'resolved'; null: everything.
  final String? status;
  final String? scope;
  final String? statementId;
  final String? kind;
  final DateTime? from;
  final DateTime? to;

  bool get narrowed => scope != null || statementId != null || kind != null || from != null || to != null;

  ReconFilter copyWith({
    Object? status = _keep,
    Object? scope = _keep,
    Object? statementId = _keep,
    Object? kind = _keep,
    Object? from = _keep,
    Object? to = _keep,
  }) =>
      ReconFilter(
        status: identical(status, _keep) ? this.status : status as String?,
        scope: identical(scope, _keep) ? this.scope : scope as String?,
        statementId: identical(statementId, _keep) ? this.statementId : statementId as String?,
        kind: identical(kind, _keep) ? this.kind : kind as String?,
        from: identical(from, _keep) ? this.from : from as DateTime?,
        to: identical(to, _keep) ? this.to : to as DateTime?,
      );

  static const Object _keep = Object();
}

/// The phone's statement reconciliation: the session's statements (from the
/// import screen) compared with what the app recorded — by the web app's
/// own code, run in the statement engine — and the user's decisions.
///
/// Reads only: the ledger around each statement's period, each card's
/// entries, and the expenses and income recorded around it. The one write is
/// a decision (migration 015); a transaction is only ever changed by the
/// user, in its own screen.
class ReconciliationProvider extends AsyncProvider {
  ReconciliationProvider({
    required StatementEngine engine,
    required LedgerRepository ledger,
    required CreditCardRepository cards,
    required ExpenseRepository expenses,
    required IncomeRepository income,
    required ReconciliationRepository decisions,
  })  : _engine = engine,
        _ledger = ledger,
        _cards = cards,
        _expenses = expenses,
        _income = income,
        _decisionRepo = decisions;

  final StatementEngine _engine;
  final LedgerRepository _ledger;
  final CreditCardRepository _cards;
  final ExpenseRepository _expenses;
  final IncomeRepository _income;
  final ReconciliationRepository _decisionRepo;

  /// How far around the statements expenses and income recorded by hand are
  /// read — the engine's `checkDays`.
  static const int checkDays = 7;

  // What was compared, and what with.
  String? _userId;
  String _currency = 'INR';
  List<Map<String, Object?>> _statements = const <Map<String, Object?>>[];
  List<Map<String, Object?>>? _items;
  List<String> _cardIds = const <String>[];
  Map<String, Object?> _labels = const <String, Object?>{};
  String? _signature;
  List<Map<String, Object?>> _accountData = const <Map<String, Object?>>[];
  List<Map<String, Object?>> _cardData = const <Map<String, Object?>>[];
  List<Map<String, Object?>> _recorded = const <Map<String, Object?>>[];
  List<Map<String, Object?>> _decisions = const <Map<String, Object?>>[];

  // The outcome.
  List<ReconItem> _all = const <ReconItem>[];
  List<ReconScope> _scopes = const <ReconScope>[];
  Map<String, Object?> _counts = const <String, Object?>{};
  Map<String, Object?> _constants = const <String, Object?>{};
  Map<String, String> _statementLabels = const <String, String>{};
  bool _computed = false;

  bool get computed => _computed;
  List<ReconItem> get items => _all;
  List<ReconScope> get scopes => _scopes;
  int count(String key) => (_counts[key] as num?)?.toInt() ?? 0;

  /// Statement id → "HDFC Bank", for the source filter and the sheet.
  Map<String, String> get statementLabels => _statementLabels;

  /// Decisions last only as long as this session until migration 015 runs.
  bool get persistent => SchemaCapabilities.reconciliation;

  List<String> _strings(String key) =>
      ((_constants[key] as List<Object?>?) ?? const <Object?>[]).whereType<String>().toList();
  String _label(String table, String key) =>
      ((_constants[table] as Map<Object?, Object?>?)?[key] as String?) ?? key;

  /// Discrepancies first, matches last.
  List<String> get statusOrder => _strings('statuses');

  /// What agrees, then each kind of discrepancy: the summary tiles.
  List<String> get tileOrder => _strings('tiles');
  List<String> get kinds => _strings('kinds');
  Set<String> get countedKinds => _strings('countedKinds').toSet();
  String statusLabel(String status) => _label('statusLabels', status);
  String statusMark(String status) => _label('statusMarks', status);
  String kindLabel(String kind) => _label('kindLabels', kind);

  @override
  bool get isEmptyData => !_computed;

  /// The items [filter] keeps — the web's filterRecon.
  List<ReconItem> filtered(ReconFilter filter) {
    final Map<String, List<String>> scopeStatements = <String, List<String>>{
      for (final ReconScope s in _scopes) s.key: s.statementIds,
    };
    return _all.where((ReconItem item) {
      final String? status = filter.status;
      if (status == 'open' && (item.resolved || item.status == 'matched')) return false;
      if (status == 'resolved' && !item.resolved) return false;
      if (status != null && status != 'open' && status != 'resolved' && item.status != status) return false;
      if (filter.scope != null && item.scope != filter.scope) return false;
      if (filter.statementId != null) {
        final List<String> on = item.line != null
            ? ((item.line!['statementIds'] as List<Object?>?) ?? const <Object?>[]).whereType<String>().toList()
            : scopeStatements[item.scope] ?? const <String>[];
        if (!on.contains(filter.statementId)) return false;
      }
      if (filter.kind != null && item.kind != filter.kind) return false;
      if (filter.from != null && item.date.isBefore(filter.from!)) return false;
      if (filter.to != null && item.date.isAfter(filter.to!)) return false;
      return true;
    }).toList();
  }

  /// Compares the session's [statements] and [items] with what the app
  /// recorded. The recorded transactions are read again only when the
  /// accounts or periods change, or with [reload] (after the user fixed a
  /// transaction); otherwise only the comparison runs again.
  Future<void> run({
    required String userId,
    required List<Map<String, Object?>> statements,
    required List<Map<String, Object?>> items,
    required List<BankAccount> accounts,
    required List<CreditCard> cards,
    required List<ClaimSummary> claims,
    required String currency,
    String? cardId,
    bool reload = false,
  }) async {
    if (userId != _userId) {
      _userId = userId;
      _signature = null;
      _decisions = const <Map<String, Object?>>[];
    }
    _statements = statements;
    _items = items;
    _currency = currency;
    _cardIds = cardId == null ? const <String>[] : <String>[cardId];
    _labels = <String, Object?>{
      'accounts': <String, String>{for (final BankAccount a in accounts) a.id: a.displayLabel},
      'cards': <String, String>{for (final CreditCard c in cards) c.id: c.displayLabel},
      'statements': <String, String>{
        for (final Map<String, Object?> s in statements)
          s['id']! as String: (s['bankName'] as String?) ?? (s['parserLabel'] as String?) ?? 'Statement',
      },
    };
    if (statements.isEmpty) return;
    try {
      final List<Map<String, Object?>> plans = ((await _engine.call('reconScopes', <String, Object?>{
                'statements': statements,
                'items': items,
                'cardIds': _cardIds,
              })) as List<Object?>?)
              ?.whereType<Map<Object?, Object?>>()
              .map((Map<Object?, Object?> m) => m.cast<String, Object?>())
              .toList() ??
          const <Map<String, Object?>>[];
      final String signature = plans
          .map((Map<String, Object?> p) => '${p['key']}|${p['from']}|${p['to']}|${p['fetchFrom']}|${p['fetchToExclusive']}')
          .join(',');
      if (reload || signature != _signature) {
        if (!_computed) setLoading();
        await _read(userId, plans, accounts: accounts, cards: cards, claims: claims);
        _signature = signature;
      }
      await _compute();
      setReady();
    } catch (error) {
      setError(error);
    }
  }

  /// Everything the comparison needs from the database, for [plans].
  Future<void> _read(
    String userId,
    List<Map<String, Object?>> plans, {
    required List<BankAccount> accounts,
    required List<CreditCard> cards,
    required List<ClaimSummary> claims,
  }) async {
    DateTime day(Object? iso) => AppDateUtils.parseDate(iso! as String);
    // Who each movement was paid for, or who paid it back.
    final Map<String, ClaimSummary> byEntry = <String, ClaimSummary>{};
    final Map<String, ClaimSummary> byExpense = <String, ClaimSummary>{};
    final Map<String, ClaimSummary> byId = <String, ClaimSummary>{};
    for (final ClaimSummary c in claims) {
      byId[c.receivable.id] = c;
      if (c.receivable.ledgerEntryId != null) byEntry[c.receivable.ledgerEntryId!] = c;
      if (c.receivable.expenseId != null) byExpense[c.receivable.expenseId!] = c;
    }
    Map<String, Object?>? claimOf(LedgerEntry e) {
      final ClaimSummary? settled = e.receivableId == null ? null : byId[e.receivableId];
      if (settled != null) {
        return <String, Object?>{'receivableId': settled.receivable.id, 'person': settled.receivable.person, 'role': 'settles'};
      }
      final ClaimSummary? source = byEntry[e.id] ?? (e.expenseId == null ? null : byExpense[e.expenseId]);
      return source == null
          ? null
          : <String, Object?>{'receivableId': source.receivable.id, 'person': source.receivable.person, 'role': 'source'};
    }

    final List<Future<Map<String, Object?>>> reads = <Future<Map<String, Object?>>>[];
    for (final Map<String, Object?> plan in plans) {
      final String id = plan['id']! as String;
      if (plan['type'] == 'card') {
        final CreditCard? card = cards.where((CreditCard c) => c.id == id).firstOrNull;
        reads.add(_cards.fetchEntries(userId: userId, cardId: id).then((List<CardEntry> entries) => <String, Object?>{
              'type': 'card',
              'id': id,
              'openingOutstanding': card?.openingOutstanding ?? 0,
              'entries': entries.map(EngineJson.cardEntry).toList(),
              'paidFor': <String, String>{
                for (final ClaimSummary c in claims)
                  if (c.receivable.expenseId != null) c.receivable.expenseId!: c.receivable.person,
              },
            }));
      } else {
        final BankAccount? account = accounts.where((BankAccount a) => a.id == id).firstOrNull;
        reads.add(Future.wait(<Future<Object>>[
          _ledger.fetchForAccount(
            userId: userId,
            accountId: id,
            from: day(plan['fetchFrom']),
            toExclusive: day(plan['fetchToExclusive']),
          ),
          _ledger.netBefore(userId: userId, accountId: id, before: day(plan['from'])),
        ]).then((List<Object> got) => <String, Object?>{
              'type': 'account',
              'id': id,
              'opening': (((account?.openingBalance ?? 0) + (got[1] as double)) * 100).round() / 100,
              'entries': (got[0] as List<LedgerEntry>)
                  .map((LedgerEntry e) => EngineJson.ledgerEntry(e, claim: claimOf(e)))
                  .toList(),
            }));
      }
    }
    final List<String> froms = plans.map((Map<String, Object?> p) => p['from']! as String).toList()..sort();
    final List<String> tos = plans.map((Map<String, Object?> p) => p['to']! as String).toList()..sort();
    Future<List<Map<String, Object?>>> recorded() async {
      if (froms.isEmpty) return const <Map<String, Object?>>[];
      final DateTime from = day(froms.first);
      final DateTime to = day(tos.last);
      final DateTime start = DateTime(from.year, from.month, from.day - checkDays);
      final DateTime end = DateTime(to.year, to.month, to.day + checkDays + 1);
      final (List<Expense> expenses, List<Income> income) = await (
        _expenses.fetchRange(userId: userId, from: start, toExclusive: end),
        _income.fetchRange(userId: userId, from: start, toExclusive: end),
      ).wait;
      return <Map<String, Object?>>[
        ...expenses.map(EngineJson.recordedExpense),
        ...income.map(EngineJson.recordedIncome),
      ];
    }

    final (List<Map<String, Object?>> scoped, List<Map<String, Object?>> found, List<Map<String, Object?>> decided) = await (
      Future.wait(reads),
      recorded(),
      persistent
          ? _decisionRepo.fetchDecisions(
              userId: userId,
              scopes: plans.map((Map<String, Object?> p) => p['key']! as String).toList(),
            )
          : Future<List<Map<String, Object?>>>.value(_decisions),
    ).wait;
    _accountData = scoped.where((Map<String, Object?> s) => s['type'] == 'account').toList();
    _cardData = scoped.where((Map<String, Object?> s) => s['type'] == 'card').toList();
    _recorded = found;
    _decisions = decided;
  }

  Future<void> _compute() async {
    final List<Map<String, Object?>>? items = _items;
    if (items == null) return;
    final Map<String, Object?> out = (await _engine.call('reconcile', <String, Object?>{
      'statements': _statements,
      'items': items,
      'accounts': _accountData,
      'cards': _cardData,
      'recorded': _recorded,
      'decisions': _decisions,
      'cardIds': _cardIds,
      'currency': _currency,
      'labels': _labels,
    }))! as Map<String, Object?>;
    final Map<String, Object?> result = (out['result']! as Map<Object?, Object?>).cast<String, Object?>();
    final Map<String, Object?> texts = (out['texts']! as Map<Object?, Object?>).cast<String, Object?>();
    final Map<Object?, Object?> itemTexts = (texts['items'] as Map<Object?, Object?>?) ?? const <Object?, Object?>{};
    final Map<Object?, Object?> scopeTexts = (texts['scopes'] as Map<Object?, Object?>?) ?? const <Object?, Object?>{};
    _all = ((result['items'] as List<Object?>?) ?? const <Object?>[])
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> m) {
      final Map<String, Object?> json = m.cast<String, Object?>();
      return ReconItem(json, (itemTexts[json['id']] as Map<Object?, Object?>?)?.cast<String, Object?>() ?? const <String, Object?>{});
    }).toList();
    _scopes = ((result['scopes'] as List<Object?>?) ?? const <Object?>[])
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> m) {
      final Map<String, Object?> json = m.cast<String, Object?>();
      return ReconScope(json, (scopeTexts[json['key']] as Map<Object?, Object?>?)?.cast<String, Object?>() ?? const <String, Object?>{});
    }).toList();
    _counts = (result['counts'] as Map<Object?, Object?>?)?.cast<String, Object?>() ?? const <String, Object?>{};
    _constants = (out['constants'] as Map<Object?, Object?>?)?.cast<String, Object?>() ?? const <String, Object?>{};
    _statementLabels = ((texts['statements'] as Map<Object?, Object?>?) ?? const <Object?, Object?>{})
        .map((Object? k, Object? v) => MapEntry<String, String>(k! as String, (v as String?) ?? ''));
    _computed = true;
  }

  /// Stores a decision — {scope, itemKey, action, entryId} — and compares
  /// again. Shown at once; taken back if it could not be saved.
  Future<bool> decide(Map<String, Object?> decision) => _change('withDecision', decision, save: true);

  /// Takes a decision back.
  Future<bool> undo(Map<String, Object?> decision) => _change('withoutDecision', decision, save: false);

  Future<bool> _change(String call, Map<String, Object?> decision, {required bool save}) async {
    final String? userId = _userId;
    if (userId == null) return false;
    final List<Map<String, Object?>> before = _decisions;
    return guard(() async {
      _decisions = ((await _engine.call(call, <String, Object?>{'list': _decisions, 'decision': decision})) as List<Object?>)
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> m) => m.cast<String, Object?>())
          .toList();
      await _compute();
      safeNotify();
      if (!persistent) return;
      try {
        if (save) {
          await _decisionRepo.saveDecision(userId: userId, decision: decision);
        } else {
          await _decisionRepo.removeDecision(userId: userId, decision: decision);
        }
      } catch (_) {
        _decisions = before;
        await _compute();
        rethrow;
      }
    });
  }

  /// The expense a reconciliation item opens; null when deleted since.
  Future<Expense?> expenseById(String id) async {
    final String? userId = _userId;
    return userId == null ? null : _expenses.fetchById(userId: userId, id: id);
  }

  /// The income entry a reconciliation item opens; null when deleted since.
  Future<Income?> incomeById(String id) async {
    final String? userId = _userId;
    return userId == null ? null : _income.fetchById(userId: userId, id: id);
  }

  /// Forgets the session (the import screen started over or closed).
  void clear() {
    _statements = const <Map<String, Object?>>[];
    _items = null;
    _signature = null;
    _all = const <ReconItem>[];
    _scopes = const <ReconScope>[];
    _counts = const <String, Object?>{};
    _computed = false;
    if (!persistent) _decisions = const <Map<String, Object?>>[];
    // Called as the screen closes: nothing is listening any more.
  }
}
