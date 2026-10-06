import '../core/errors/app_exception.dart';
import '../core/utils/date_utils.dart';
import '../models/bank_account.dart';
import '../models/credit_card.dart';
import '../models/expense.dart';
import '../models/expense_category.dart';
import '../models/income.dart';
import '../models/ledger_entry.dart';
import '../models/payment_method.dart';
import '../repositories/expense_repository.dart';
import '../repositories/income_repository.dart';
import '../repositories/ledger_repository.dart';
import '../repositories/tag_repository.dart';
import '../services/schema_capabilities.dart';
import '../services/statement_import/statement_engine.dart';
import 'async_state.dart';

/// The ledger rows and the hand-added entries a session is checked against.
typedef _Recorded = ({
  List<Map<String, Object?>> existing,
  List<Map<String, Object?>> recorded,
});

/// One reviewable statement row. A thin typed view over the engine's JSON —
/// the engine owns the shape, so edits round-trip through it unchanged.
class ImportRow {
  const ImportRow(this.json, this.flags);

  final Map<String, Object?> json;

  /// Per-row view flags and wording from the engine (`view`).
  final Map<String, Object?> flags;

  String get id => json['id']! as String;

  /// The statement in this session the row was read from.
  String? get sourceStatementId => json['sourceStatementId'] as String?;
  DateTime get date => AppDateUtils.parseDate(json['transactionDate']! as String);
  String get isoDate => json['transactionDate']! as String;
  String get description => (json['description'] as String?) ?? '';
  String get rawDescription => (json['rawDescription'] as String?) ?? '';
  double get amount => (json['amount'] as num?)?.toDouble() ?? 0;
  bool get isDebit => json['transactionType'] == 'debit';
  String get kind => (json['kind'] as String?) ?? 'expense';
  String? get categoryId => json['categoryId'] as String?;
  String? get category => json['category'] as String?;
  String? get counterparty => json['counterparty'] as String?;
  String? get reference => json['reference'] as String?;
  String? get creditCardId => json['creditCardId'] as String?;
  String? get categoryReason => json['categoryReason'] as String?;
  bool get selected => json['selected'] == true;
  bool get edited => json['edited'] == true;
  double get confidence => (json['confidence'] as num?)?.toDouble() ?? 1;
  List<String> get issues =>
      ((json['issues'] as List<Object?>?) ?? const <Object?>[])
          .whereType<String>()
          .toList();

  /// The account the row goes into: the statement's own, or — on a statement
  /// covering several accounts — the one it names. Empty until chosen when
  /// that account could not be matched to one of the user's.
  String get bankAccountId => (json['bankAccountId'] as String?) ?? '';

  /// 'matched', 'unmatched' or 'chosen' on a multi-account statement.
  String? get accountStatus => json['accountStatus'] as String?;

  /// The account the statement names for this row, as printed ("HDFC Bank - 59").
  String? get sourceAccount => json['sourceAccount'] as String?;

  /// A row of a statement covering several accounts can move to another one.
  bool get movable => sourceAccount != null;

  /// The statement printed a time of day (Paytm); null when it left it blank.
  bool get hasTime => json.containsKey('transactionTime');
  String? get transactionTime => json['transactionTime'] as String?;

  /// The statement has a Notes column (Paytm): its note goes to the expense's
  /// notes. Absent for bank statements, which keep their import marker.
  bool get hasNotes => json.containsKey('notes');
  String? get notes => json['notes'] as String?;

  /// The statement's own tags on the row, without the "#".
  List<String> get tags =>
      ((json['tags'] as List<Object?>?) ?? const <Object?>[])
          .whereType<String>()
          .toList();

  /// The other side's UPI ID, when printed.
  String? get upiId => json['upiId'] as String?;

  Map<String, Object?>? get _target => json['transferTarget'] is Map
      ? (json['transferTarget']! as Map).cast<String, Object?>()
      : null;

  /// For a transfer: the other side — 'account', 'card' or 'cash' — or null
  /// when unknown (it is then imported as balance only).
  String? get transferTargetType => _target?['type'] as String?;
  String? get transferAccountId =>
      transferTargetType == 'account' ? _target!['accountId'] as String? : null;
  String? get transferCardId =>
      transferTargetType == 'card' ? _target!['cardId'] as String? : null;

  /// An expense paid on someone else's behalf (only ever set on the web).
  bool get reimbursable => json['reimbursable'] == true;

  bool get blocking => flags['blocking'] == true;
  bool get uncategorized => flags['uncategorized'] == true;
  bool get attention => flags['attention'] == true;
  String get kindLabel => (flags['kindLabel'] as String?) ?? kind;
  String? get duplicateBadge => flags['duplicateBadge'] as String?;
  String? get duplicateText => flags['duplicateText'] as String?;
  bool get isDuplicate => json['duplicate'] != null;

  /// Possibly the same as something already recorded — an expense added by
  /// hand, or a same-amount entry a day or two away. The user is asked.
  bool get possibleDuplicate => flags['possible'] == true;

  /// A possible duplicate the user has not answered yet.
  bool get uncheckedDuplicate => flags['unchecked'] == true;

  /// The answer: 'duplicate' (left out) or 'notDuplicate' (imported).
  String? get duplicateDecision => flags['decision'] as String?;

  /// Left out as a duplicate — flagged as one, or confirmed by the user.
  bool get leftOut => flags['leftOut'] == true;

  /// What the row still lacks before it can be imported as chosen — 'account'
  /// on a multi-account statement whose account could not be matched,
  /// 'transferTarget' for a transfer with no other side — and how to say so.
  String? get problem => flags['problem'] as String?;
  String? get problemText => flags['problemText'] as String?;
}

/// One statement read in this session.
class ImportedStatement {
  const ImportedStatement({
    required this.json,
    required this.periodLabel,
    required this.accountMismatch,
  });

  final Map<String, Object?> json;
  final String periodLabel;
  final bool accountMismatch;

  String get id => json['id']! as String;
  String get fileName => (json['fileName'] as String?) ?? 'Statement';
  String? get bankName => json['bankName'] as String?;
  String get parserLabel => (json['parserLabel'] as String?) ?? '';
  int get transactionCount =>
      ((json['transactions'] as List<Object?>?) ?? const <Object?>[]).length;
  List<String> get warnings =>
      ((json['warnings'] as List<Object?>?) ?? const <Object?>[])
          .map((Object? w) => (w as Map<String, Object?>)['message'] as String?)
          .whereType<String>()
          .toList();

  /// The statement covers several of the user's accounts (a payment app's UPI
  /// statement): each row went to the account it names, not to the one chosen
  /// for the upload.
  bool get accountPerRow => json['accountPerRow'] == true;
}

/// A statement waiting for its password.
class PendingPassword {
  const PendingPassword({required this.file, required this.incorrect});

  final PickedStatementFile file;
  final bool incorrect;
}

/// What a plan writes, by kind — the engine's `PlanCounts`.
class ImportCounts {
  const ImportCounts(this.json);

  final Map<String, Object?> json;

  int _n(String key) => (json[key] as num?)?.toInt() ?? 0;

  int get expenses => _n('expenses');

  /// Expenses paid on someone else's behalf — not personal spending.
  int get paidFor => _n('paidFor');
  int get income => _n('income');

  /// Balance only: refunds, card bills, cash and transfers with no tracked side.
  int get movements => _n('movements');

  /// Transfers between two of the user's own accounts.
  int get transfers => _n('transfers');
  int get lent => _n('lent');
  int get repaid => _n('repaid');

  int get total =>
      expenses + paidFor + income + movements + transfers + lent + repaid;
}

/// Counts of what one import wrote.
class ImportOutcome {
  ImportOutcome();

  int expenses = 0;
  int income = 0;
  int movements = 0;

  /// Transfers between the user's own accounts (both legs, or linked).
  int transfers = 0;

  /// Loans, repayments and purchases paid for someone (web treatments).
  int other = 0;
  int skipped = 0;

  /// Rows saved, but without all their tags or statement details.
  int partial = 0;
  final List<String> failures = <String>[];

  /// Operations not attempted because writes kept failing.
  int notAttempted = 0;

  int get written => expenses + income + movements + transfers + other;
}

/// The plan the user confirms before anything is written.
class ImportPreview {
  const ImportPreview(this.json);

  final Map<String, Object?> json;

  List<Map<String, Object?>> get operations =>
      ((json['operations'] as List<Object?>?) ?? const <Object?>[])
          .cast<Map<String, Object?>>();

  List<Map<String, Object?>> get skipped =>
      ((json['skipped'] as List<Object?>?) ?? const <Object?>[])
          .cast<Map<String, Object?>>();

  /// How many of each kind, from the engine.
  ImportCounts get counts => ImportCounts(
      (json['counts'] as Map<String, Object?>?) ?? const <String, Object?>{});

  Iterable<Map<String, Object?>> ofType(String type) =>
      operations.where((Map<String, Object?> op) => op['type'] == type);

  /// Operations per account, in the order the accounts first appear.
  Map<String, int> get perAccount {
    final Map<String, int> counts = <String, int>{};
    for (final Map<String, Object?> op in operations) {
      final String id = (op['bankAccountId'] as String?) ?? '';
      counts[id] = (counts[id] ?? 0) + 1;
    }
    return counts;
  }

  static double total(Iterable<Map<String, Object?>> ops) {
    int cents = 0;
    for (final Map<String, Object?> op in ops) {
      cents += (((op['amount'] as num?)?.toDouble() ?? 0) * 100).round();
    }
    return cents / 100;
  }
}

/// Statement import, the phone's counterpart of the web Import statement
/// screen: the same engine reads, classifies, de-duplicates and plans; this
/// provider holds the session and performs the confirmed writes through the
/// app's own repositories, exactly what the web import writes.
///
/// A payment app's statement (Paytm) covers several accounts: each row goes to
/// the account it names, duplicates are checked on every account the session
/// touches, and a row whose account could not be matched waits for the user.
///
/// Nothing is written until [execute] runs after the user confirms.
class StatementImportProvider extends AsyncProvider {
  StatementImportProvider({
    required StatementEngine engine,
    required ExpenseRepository expenses,
    required IncomeRepository income,
    required LedgerRepository ledger,
    required TagRepository tags,
  })  : _engine = engine,
        _expenses = expenses,
        _income = income,
        _ledger = ledger,
        _tags = tags;

  final StatementEngine _engine;
  final ExpenseRepository _expenses;
  final IncomeRepository _income;
  final LedgerRepository _ledger;
  final TagRepository _tags;

  /// How far around a statement's dates recorded rows are read — the
  /// engine's `checkDays`: an expense added by hand may be dated up to a
  /// week off.
  static const int checkDays = 7;

  /// After this many failures in a row the problem is not the data; stop
  /// rather than fail every row.
  static const int maxConsecutiveFailures = 3;

  String? _userId;
  BankAccount? _account;
  List<BankAccount> _accounts = <BankAccount>[];
  List<ExpenseCategory> _categories = <ExpenseCategory>[];
  List<CreditCard> _cards = <CreditCard>[];

  final List<ImportedStatement> _statements = <ImportedStatement>[];
  final List<PickedStatementFile> _files = <PickedStatementFile>[];
  List<Map<String, Object?>> _items = <Map<String, Object?>>[];
  Map<String, Map<String, Object?>> _flags = <String, Map<String, Object?>>{};
  Map<String, Object?> _summary = <String, Object?>{};

  String? _reading;
  PendingPassword? _pending;
  String? _problem;
  bool _checkFailed = false;
  bool _rechecking = false;
  (int, int)? _importing;
  ImportOutcome? _outcome;

  BankAccount? get account => _account;
  List<BankAccount> get accounts => List<BankAccount>.unmodifiable(_accounts);
  List<ImportedStatement> get statements =>
      List<ImportedStatement>.unmodifiable(_statements);
  List<ImportRow> get rows => _items
      .map((Map<String, Object?> j) => ImportRow(
          j, _flags[j['id']] ?? const <String, Object?>{}))
      .toList();
  Map<String, Object?> get summary => _summary;
  String? get reading => _reading;
  PendingPassword? get pending => _pending;
  String? get problem => _problem;

  /// The check against recorded transactions failed: rows are reviewable but
  /// importing waits until a retry succeeds.
  bool get checkFailed => _checkFailed;
  bool get rechecking => _rechecking;
  (int, int)? get importing => _importing;
  ImportOutcome? get outcome => _outcome;
  bool get hasRows => _items.isNotEmpty;

  /// A statement in this session covers several accounts: rows go to the
  /// accounts it names rather than to [account].
  bool get multiAccount => _statements.any((ImportedStatement s) => s.accountPerRow);

  @override
  bool get isEmptyData => _items.isEmpty;

  int _count(String key) => (_summary[key] as num?)?.toInt() ?? 0;
  int get selectedCount => _count('selected');

  /// Selected rows that may be duplicates the user has not answered.
  int get uncheckedSelected => rows
      .where((ImportRow r) => r.selected && r.uncheckedDuplicate)
      .length;

  /// Starts a session for [account]. Picking another account starts over.
  void begin({
    required String userId,
    required BankAccount account,
    required List<BankAccount> accounts,
    required List<ExpenseCategory> categories,
    required List<CreditCard> cards,
  }) {
    if (_account?.id != account.id || _userId != userId) {
      _clearSession();
      _account = account;
      _userId = userId;
    }
    _accounts = accounts;
    _categories = categories;
    _cards = cards;
    safeNotify();
  }

  BankAccount? accountById(String id) {
    for (final BankAccount a in _accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Picks one statement file and reads it.
  Future<void> addFile() async {
    if (_account == null) return;
    _problem = null;
    PickedStatementFile? file;
    try {
      file = await _engine.pickFile();
    } on StatementEngineException catch (error) {
      _problem = error.message;
      safeNotify();
      return;
    }
    if (file == null) return;
    await _read(file, null);
  }

  /// Retries the waiting statement with [password]. The password is passed
  /// to the reader and never stored.
  Future<void> unlock(String password) async {
    final PendingPassword? pending = _pending;
    if (pending == null || password.isEmpty) return;
    await _read(pending.file, password);
  }

  void cancelPassword() {
    final PendingPassword? pending = _pending;
    _pending = null;
    if (pending != null) _engine.release(pending.file.token);
    safeNotify();
  }

  Future<void> _read(PickedStatementFile file, String? password) async {
    final BankAccount? account = _account;
    final String? userId = _userId;
    if (account == null || userId == null) return;
    _reading = file.name;
    _problem = null;
    safeNotify();
    try {
      final Map<String, Object?> read = (await _engine.call('read', <String, Object?>{
        'token': file.token,
        'fileName': file.name,
        'password': password,
        'account': EngineJson.account(account),
        'accounts': _accounts.map(EngineJson.account).toList(),
        'categories': _categories.map(EngineJson.category).toList(),
        'cards': _cards.map(EngineJson.card).toList(),
      }))! as Map<String, Object?>;
      _pending = null;
      final Map<String, Object?> statementJson =
          read['statement']! as Map<String, Object?>;
      final ImportedStatement statement = ImportedStatement(
        json: statementJson,
        periodLabel: (read['periodLabel'] as String?) ?? '',
        accountMismatch: read['accountMismatch'] == true,
      );
      if (_statements.any((ImportedStatement s) => s.id == statement.id)) {
        _problem = '${file.name} was already added.';
        _engine.release(file.token);
        return;
      }
      final List<Object?> transactions =
          (statementJson['transactions'] as List<Object?>?) ?? const <Object?>[];
      if (transactions.isEmpty) {
        _problem = 'No transactions were found in ${file.name}. If it is a '
            'statement, its layout is not supported yet.';
        _engine.release(file.token);
        return;
      }

      List<Map<String, Object?>> existing = <Map<String, Object?>>[];
      List<Map<String, Object?>> recorded = <Map<String, Object?>>[];
      try {
        // Every account the session's rows are on: a Paytm statement spans several.
        final _Recorded found = await _recordedFor(
          <ImportedStatement>[..._statements, statement],
          <String>[
            ..._accountsOf(_items),
            ..._accountsOf(transactions.whereType<Map<String, Object?>>()),
          ],
        );
        existing = found.existing;
        recorded = found.recorded;
      } catch (_) {
        // Still reviewable — overlaps between these files are caught — but
        // importing waits until the check against recorded rows succeeds.
        _checkFailed = true;
      }
      final List<Object?> added = (await _engine.call('review', <String, Object?>{
        'current': _items,
        'transactions': transactions,
        'existing': existing,
        'recorded': recorded,
        'categories': _categories.map(EngineJson.category).toList(),
      }))! as List<Object?>;
      _statements.add(statement);
      _files.add(file);
      _items = <Map<String, Object?>>[
        ..._items,
        ...added.cast<Map<String, Object?>>(),
      ];
      await _refreshView();
    } on StatementEngineException catch (error) {
      if (error.needsPassword) {
        _pending = PendingPassword(
          file: file,
          incorrect: error.code == 'passwordIncorrect',
        );
      } else {
        _problem = '${file.name}: ${error.message}';
        _engine.release(file.token);
      }
    } catch (error) {
      _problem = '${file.name}: ${ErrorMapper.map(error).message}';
      _engine.release(file.token);
    } finally {
      _reading = null;
      safeNotify();
    }
  }

  static Iterable<String> _accountsOf(Iterable<Map<String, Object?>> rows) =>
      rows
          .map((Map<String, Object?> r) => r['bankAccountId'] as String?)
          .whereType<String>()
          .where((String id) => id.isNotEmpty);

  /// What the duplicate checks compare the session with: the ledger around
  /// every statement in it, on the upload's account and every account
  /// [accountIds] names; and the expenses and income recorded around it on
  /// any account or none.
  Future<_Recorded> _recordedFor(
    List<ImportedStatement> statements,
    Iterable<String> accountIds,
  ) async {
    final Object? range = await _engine.call('sessionRange', <String, Object?>{
      'statements': statements
          .map((ImportedStatement s) => <String, Object?>{'period': s.json['period']})
          .toList(),
    });
    if (range is! Map<String, Object?>) {
      return (existing: <Map<String, Object?>>[], recorded: <Map<String, Object?>>[]);
    }
    final DateTime from = AppDateUtils.parseDate(range['from']! as String);
    final DateTime to = AppDateUtils.parseDate(range['to']! as String);
    final List<List<Map<String, Object?>>> found =
        await Future.wait(<Future<List<Map<String, Object?>>>>[
      _existingBetween(from, to, <String>{_account!.id, ...accountIds}),
      _recordedBetween(from, to),
    ]);
    return (existing: found[0], recorded: found[1]);
  }

  /// Every expense and income dated around [from]–[to], on any account or
  /// none — what a statement row may already have been added by hand as.
  Future<List<Map<String, Object?>>> _recordedBetween(DateTime from, DateTime to) async {
    final DateTime start = DateTime(from.year, from.month, from.day - checkDays);
    final DateTime end = DateTime(to.year, to.month, to.day + checkDays + 1);
    final (List<Expense> expenses, List<Income> income) = await (
      _expenses.fetchRange(userId: _userId!, from: start, toExclusive: end),
      _income.fetchRange(userId: _userId!, from: start, toExclusive: end),
    ).wait;
    return <Map<String, Object?>>[
      ...expenses.map(EngineJson.recordedExpense),
      ...income.map(EngineJson.recordedIncome),
    ];
  }

  Future<List<Map<String, Object?>>> _existingBetween(
    DateTime from,
    DateTime to,
    Set<String> accountIds,
  ) async {
    final List<List<LedgerEntry>> lists = await Future.wait(
      accountIds.where((String id) => id.isNotEmpty).map(
            (String accountId) => _ledger.fetchForAccount(
              userId: _userId!,
              accountId: accountId,
              from: DateTime(from.year, from.month, from.day - checkDays),
              toExclusive: DateTime(to.year, to.month, to.day + checkDays + 1),
            ),
          ),
    );
    return <Map<String, Object?>>[
      for (final List<LedgerEntry> entries in lists)
        ...entries.map(EngineJson.existing),
    ];
  }

  Future<void> _refreshView() async {
    final Map<String, Object?> view = (await _engine.call(
      'view',
      <String, Object?>{'items': _items},
    ))! as Map<String, Object?>;
    _summary = (view['summary'] as Map<String, Object?>?) ?? <String, Object?>{};
    _flags = <String, Map<String, Object?>>{
      for (final Object? row in (view['rows'] as List<Object?>?) ?? const <Object?>[])
        ((row! as Map<String, Object?>)['id']! as String): row as Map<String, Object?>,
    };
  }

  /// Toggle, select, edit or remove — through the same reducer the web uses.
  Future<void> reduce(Map<String, Object?> action) async {
    try {
      final List<Object?> next = (await _engine.call('reduce', <String, Object?>{
        'items': _items,
        'action': action,
      }))! as List<Object?>;
      _items = next.cast<Map<String, Object?>>();
      await _refreshView();
    } catch (error) {
      _problem = ErrorMapper.map(error).message;
    }
    safeNotify();
  }

  Future<void> toggle(String id) =>
      reduce(<String, Object?>{'type': 'toggle', 'id': id});

  Future<void> setSelected(Iterable<String> ids, bool selected) => reduce(
        <String, Object?>{'type': 'setSelected', 'ids': ids.toList(), 'selected': selected},
      );

  /// Edits one row. A row moved to another account is checked again against
  /// that account's recorded movements; if that check fails, importing waits.
  Future<void> edit(String id, Map<String, Object?> patch) async {
    await reduce(<String, Object?>{'type': 'edit', 'id': id, 'patch': patch});
    if (patch.containsKey('bankAccountId')) await recheck(quiet: true);
  }

  Future<void> remove(String id) =>
      reduce(<String, Object?>{'type': 'remove', 'id': id});

  /// The answer for a possible duplicate: 'duplicate' leaves the row out,
  /// 'notDuplicate' imports it as its own transaction; null takes the answer
  /// back. Nothing is deleted or merged either way.
  Future<void> decideDuplicate(String id, String? decision) => reduce(
        <String, Object?>{'type': 'decideDuplicate', 'id': id, 'decision': decision},
      );

  /// Kinds valid for a direction, from the engine. Loans and reimbursements
  /// are recorded on the web app, so the phone does not offer them.
  Future<List<String>> kindsFor(bool debit) async {
    final Object? kinds = await _engine.call(
      'kindsFor',
      <String, Object?>{'type': debit ? 'debit' : 'credit', 'treatments': false},
    );
    return (kinds as List<Object?>? ?? const <Object?>[]).whereType<String>().toList();
  }

  /// Re-runs the check against recorded transactions on every account the
  /// session's rows are on. [quiet]: after a row moved to another account —
  /// a failure then only holds the import back.
  Future<void> recheck({bool quiet = false}) async {
    if (_statements.isEmpty) return;
    _rechecking = true;
    safeNotify();
    try {
      final _Recorded found = await _recordedFor(_statements, _accountsOf(_items));
      final List<Object?> next = (await _engine.call('recheck', <String, Object?>{
        'items': _items,
        'existing': found.existing,
        'recorded': found.recorded,
      }))! as List<Object?>;
      _items = next.cast<Map<String, Object?>>();
      await _refreshView();
      _checkFailed = false;
    } catch (error) {
      if (quiet) {
        _checkFailed = true;
      } else {
        _problem =
            'Still could not check for recorded transactions. ${ErrorMapper.map(error).message}';
      }
    } finally {
      _rechecking = false;
      safeNotify();
    }
  }

  /// What the database can store, so the plan writes each row exactly as the
  /// web import would on the same database.
  Map<String, Object?> get _planOptions => <String, Object?>{
        'linkAccounts': SchemaCapabilities.treatments,
        'pairAccounts': SchemaCapabilities.transfers,
        'storeDetails': SchemaCapabilities.statementDetails,
        'storeTags': SchemaCapabilities.tags,
        'accountNames': <String, String>{
          for (final BankAccount a in _accounts) a.id: a.nickname,
        },
      };

  /// The exact writes, for the user to confirm. Null with [problem] set when
  /// nothing can be imported yet.
  Future<ImportPreview?> preview({
    required List<PaymentMethod> paymentMethods,
  }) async {
    try {
      final ImportPreview plan = ImportPreview((await _engine.call('plan', <String, Object?>{
        'items': _items,
        'categories': _categories.map(EngineJson.category).toList(),
        'paymentMethods': paymentMethods.map(EngineJson.paymentMethod).toList(),
        'options': _planOptions,
      }))! as Map<String, Object?>);
      if (plan.operations.isEmpty) {
        final String? reason = plan.skipped.isEmpty
            ? null
            : plan.skipped.first['reason'] as String?;
        _problem = reason != null
            ? 'Nothing can be imported yet: ${reason.toLowerCase()}.'
            : 'Select at least one transaction.';
        safeNotify();
        return null;
      }
      return plan;
    } catch (error) {
      _problem = ErrorMapper.map(error).message;
      safeNotify();
      return null;
    }
  }

  /// Writes a confirmed plan. Rows recorded since review began are checked
  /// again and left out, so a retried or parallel import cannot double up.
  Future<ImportOutcome?> execute(ImportPreview preview) async {
    final String? userId = _userId;
    final BankAccount? account = _account;
    if (userId == null || account == null) return null;
    _problem = null;
    _importing = (0, preview.operations.length);
    safeNotify();
    final ImportOutcome outcome = ImportOutcome();
    try {
      // Re-check against the ledger as it is now, on every account written to.
      final Map<String, List<DateTime>> byAccount = <String, List<DateTime>>{};
      for (final Map<String, Object?> op in preview.operations) {
        (byAccount[op['bankAccountId']! as String] ??= <DateTime>[])
            .add(AppDateUtils.parseDate(op['date']! as String));
      }
      final List<Map<String, Object?>> fresh = <Map<String, Object?>>[];
      for (final MapEntry<String, List<DateTime>> entry in byAccount.entries) {
        final List<DateTime> dates = entry.value..sort();
        fresh.addAll(await _existingBetween(dates.first, dates.last, <String>{entry.key}));
      }
      final ImportPreview finalPlan = ImportPreview((await _engine.call('finalPlan', <String, Object?>{
        'plan': preview.json,
        'items': _items,
        'fresh': fresh,
      }))! as Map<String, Object?>);
      outcome.skipped = finalPlan.skipped.length;
      final Map<String, String> matches =
          await _autoMatches(userId, finalPlan.operations);

      final Map<String, String> saved = <String, String>{};
      final List<Map<String, Object?>> written = <Map<String, Object?>>[];
      int consecutive = 0;
      final List<Map<String, Object?>> ops = finalPlan.operations;
      for (int i = 0; i < ops.length; i++) {
        if (consecutive >= maxConsecutiveFailures) {
          outcome.notAttempted = ops.length - i;
          break;
        }
        final Map<String, Object?> op = ops[i];
        try {
          final (String? entryId, bool complete) =
              await _write(userId, op, saved, matches);
          if (entryId != null) saved[op['itemId']! as String] = entryId;
          if (!complete) outcome.partial++;
          consecutive = 0;
          written.add(op);
        } catch (error) {
          // A row that pays back another row of this import fails on its own,
          // not the connection.
          final String? settles = op['settlesItemId'] as String?;
          if (!(settles != null && !saved.containsKey(settles))) consecutive++;
          outcome.failures.add(ErrorMapper.map(error).message);
        }
        _importing = (i + 1, ops.length);
        safeNotify();
      }
      await _tally(outcome, written);
      _outcome = outcome;
      return outcome;
    } catch (error) {
      _problem = 'The import could not start. ${ErrorMapper.map(error).message}';
      return null;
    } finally {
      _importing = null;
      safeNotify();
    }
  }

  /// What was written, by kind — the engine's counting, the web's wording.
  Future<void> _tally(ImportOutcome outcome, List<Map<String, Object?>> written) async {
    if (written.isEmpty) return;
    ImportCounts counts;
    try {
      counts = ImportCounts((await _engine.call(
        'counts',
        <String, Object?>{'operations': written},
      ))! as Map<String, Object?>);
    } catch (_) {
      // The rows are saved either way; count them by type instead.
      counts = ImportCounts(<String, Object?>{
        'expenses': written.where((Map<String, Object?> o) => o['type'] == 'expense').length,
        'income': written.where((Map<String, Object?> o) => o['type'] == 'income').length,
        'movements': written.where((Map<String, Object?> o) => o['type'] == 'movement').length,
        'transfers': written
            .where((Map<String, Object?> o) => o['type'] == 'transfer' || o['type'] == 'treatment')
            .length,
      });
    }
    outcome
      ..expenses = counts.expenses
      ..income = counts.income
      ..movements = counts.movements
      ..transfers = counts.transfers
      ..other = counts.paidFor + counts.lent + counts.repaid;
  }

  /// Transfers whose other leg is already on that account (both statements
  /// imported): linked instead of adding a second leg. Only a single plain
  /// match is used — the engine's rule; this reads the ledger it needs.
  Future<Map<String, String>> _autoMatches(
    String userId,
    List<Map<String, Object?>> operations,
  ) async {
    final List<Object?> windows = ((await _engine.call(
          'autoMatchWindows',
          <String, Object?>{'operations': operations},
        )) as List<Object?>?) ??
        const <Object?>[];
    if (windows.isEmpty) return <String, String>{};
    final Set<String> lent = await _ledger.fetchLentEntryIds(userId: userId);
    final List<Map<String, Object?>> entries = <Map<String, Object?>>[];
    for (final Object? window in windows) {
      final Map<String, Object?> w = window! as Map<String, Object?>;
      final List<LedgerEntry> rows = await _ledger.fetchForAccount(
        userId: userId,
        accountId: w['accountId']! as String,
        from: AppDateUtils.parseDate(w['from']! as String),
        toExclusive: AppDateUtils.parseDate(w['toExclusive']! as String),
      );
      entries.addAll(rows.map(
          (LedgerEntry e) => EngineJson.ledgerEntry(e, lent: lent.contains(e.id))));
    }
    final Object? found = await _engine.call('autoMatches', <String, Object?>{
      'operations': operations,
      'entries': entries,
    });
    if (found is! Map) return <String, String>{};
    return <String, String>{
      for (final MapEntry<Object?, Object?> e in found.entries)
        e.key! as String: e.value! as String,
    };
  }

  /// One planned write, through the app's normal write paths. Returns the
  /// saved movement's id when a later row may refer back to it, and whether
  /// its tags and statement details were saved too.
  Future<(String?, bool)> _write(
    String userId,
    Map<String, Object?> op,
    Map<String, String> saved,
    Map<String, String> matches,
  ) async {
    final String accountId = op['bankAccountId']! as String;
    final double amount = (op['amount']! as num).toDouble();
    final DateTime date = AppDateUtils.parseDate(op['date']! as String);
    final String? description = op['description'] as String?;
    final MovementDetails? details = MovementDetails.fromJson(op['details']);
    final List<String> tags = ((op['tags'] as List<Object?>?) ?? const <Object?>[])
        .whereType<String>()
        .toList();
    final LedgerDirection direction =
        LedgerDirectionWire.parse(op['direction'] as String?);
    switch (op['type']) {
      case 'expense':
        final Expense expense = await _expenses.create(
          Expense(
            id: '',
            userId: userId,
            amount: amount,
            expenseDate: date,
            categoryId: op['categoryId'] as String?,
            paymentMethodId: op['paymentMethodId'] as String?,
            bankAccountId: accountId,
            merchant: op['merchant'] as String?,
            description: description,
            notes: op['notes'] as String?,
          ),
          details: details,
        );
        return (null, await _withTags(TagKind.expense, expense.id, tags));
      case 'income':
        final Income income = await _income.create(
          Income(
            id: '',
            userId: userId,
            amount: amount,
            incomeDate: date,
            source: op['source'] as String?,
            description: description,
            bankAccountId: accountId,
          ),
          details: details,
        );
        return (null, await _withTags(TagKind.income, income.id, tags));
      case 'movement':
        final String? cardId = op['creditCardId'] as String?;
        if (cardId != null) {
          // One bank debit that is also the card's payment — the same row
          // both sides read. Never an expense.
          await _ledger.recordCardPayment(
            userId: userId,
            accountId: accountId,
            cardId: cardId,
            amount: amount,
            date: date,
            description: description ?? 'Card bill payment',
            details: details,
          );
        } else {
          await _ledger.recordMovement(
            userId: userId,
            accountId: accountId,
            direction: direction,
            amount: amount,
            date: date,
            description: description,
            details: details,
          );
        }
        return (null, true);
      case 'transfer':
        await _ledger.recordTransferPair(
          userId: userId,
          accountId: accountId,
          counterpartyAccountId: op['counterpartyAccountId']! as String,
          direction: direction,
          amount: amount,
          date: date,
          description: description ?? '',
          counterpartDescription:
              (op['counterpartDescription'] as String?) ?? description ?? '',
          details: details,
        );
        return (null, true);
      case 'treatment':
        final String? settlesItemId = op['settlesItemId'] as String?;
        String? settleEntryId;
        if (settlesItemId != null) {
          settleEntryId = saved[settlesItemId];
          if (settleEntryId == null) {
            throw const AppException(
                'What this pays back could not be saved, so it was left out.');
          }
        }
        final Map<String, Object?> payload = ((await _engine.call(
          'treatmentPayload',
          <String, Object?>{
            'request': op['request'],
            'settleEntryId': settleEntryId,
            'matchEntryId': matches[op['itemId']],
          },
        ))! as Map<String, Object?>);
        final String entryId = await _ledger.recordBankMovement(
          accountId: accountId,
          direction: direction,
          amount: amount,
          date: date,
          description: description ?? '',
          treatment: payload,
        );
        // The database function saves the movement and its treatment; the
        // statement's details follow it.
        bool complete = true;
        if (details != null) {
          try {
            await _ledger.setMovementDetails(
                userId: userId, entryId: entryId, details: details);
          } catch (_) {
            complete = false;
          }
        }
        // Tags only ever ride on a purchase paid for someone, which the phone
        // does not record; were there any, they could not be attached here.
        if (tags.isNotEmpty) complete = false;
        return (entryId, complete);
      default:
        throw const AppException('Unknown import row.');
    }
  }

  /// Tags are their own write, after the row they belong to: a failure leaves
  /// the row saved (it is reported, not retried, so nothing is written twice).
  Future<bool> _withTags(TagKind kind, String id, List<String> tags) async {
    if (tags.isEmpty) return true;
    if (!SchemaCapabilities.tags || id.isEmpty) return false;
    try {
      await _tags.setTags(kind: kind, id: id, names: tags);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Starts a fresh session for the same account.
  void startOver() {
    final BankAccount? account = _account;
    final String? userId = _userId;
    _clearSession();
    _account = account;
    _userId = userId;
    safeNotify();
  }

  void _clearSession() {
    for (final PickedStatementFile f in _files) {
      _engine.release(f.token);
    }
    final PendingPassword? pending = _pending;
    if (pending != null) _engine.release(pending.file.token);
    _files.clear();
    _statements.clear();
    _items = <Map<String, Object?>>[];
    _flags = <String, Map<String, Object?>>{};
    _summary = <String, Object?>{};
    _pending = null;
    _problem = null;
    _checkFailed = false;
    _outcome = null;
    _importing = null;
    _reading = null;
  }

  void reset() {
    _clearSession();
    _account = null;
    _userId = null;
    safeNotify();
  }
}
