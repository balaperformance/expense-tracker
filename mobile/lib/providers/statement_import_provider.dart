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
import '../services/statement_import/statement_engine.dart';
import 'async_state.dart';

/// One reviewable statement row. A thin typed view over the engine's JSON —
/// the engine owns the shape, so edits round-trip through it unchanged.
class ImportRow {
  const ImportRow(this.json, this.flags);

  final Map<String, Object?> json;

  /// Per-row view flags and wording from the engine (`view`).
  final Map<String, Object?> flags;

  String get id => json['id']! as String;
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

  bool get blocking => flags['blocking'] == true;
  bool get uncategorized => flags['uncategorized'] == true;
  bool get attention => flags['attention'] == true;
  String get kindLabel => (flags['kindLabel'] as String?) ?? kind;
  String? get duplicateBadge => flags['duplicateBadge'] as String?;
  String? get duplicateText => flags['duplicateText'] as String?;
  bool get isDuplicate => json['duplicate'] != null;
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
}

/// A statement waiting for its password.
class PendingPassword {
  const PendingPassword({required this.file, required this.incorrect});

  final PickedStatementFile file;
  final bool incorrect;
}

/// Counts of what one import wrote.
class ImportOutcome {
  ImportOutcome();

  int expenses = 0;
  int income = 0;
  int movements = 0;
  int skipped = 0;
  final List<String> failures = <String>[];

  /// Operations not attempted because writes kept failing.
  int notAttempted = 0;

  int get written => expenses + income + movements;
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

  Iterable<Map<String, Object?>> ofType(String type) =>
      operations.where((Map<String, Object?> op) => op['type'] == type);

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
/// app's own repositories, exactly what adding each row by hand would do.
///
/// Nothing is written until [execute] runs after the user confirms.
class StatementImportProvider extends AsyncProvider {
  StatementImportProvider({
    required StatementEngine engine,
    required ExpenseRepository expenses,
    required IncomeRepository income,
    required LedgerRepository ledger,
  })  : _engine = engine,
        _expenses = expenses,
        _income = income,
        _ledger = ledger;

  final StatementEngine _engine;
  final ExpenseRepository _expenses;
  final IncomeRepository _income;
  final LedgerRepository _ledger;

  /// How far around a statement's dates recorded rows are checked.
  static const int nearbyDays = 2;

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

  @override
  bool get isEmptyData => _items.isEmpty;

  int _count(String key) => (_summary[key] as num?)?.toInt() ?? 0;
  int get selectedCount => _count('selected');

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

  void clearProblem() {
    _problem = null;
    safeNotify();
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
      try {
        existing = await _existingFor(<ImportedStatement>[..._statements, statement]);
      } catch (_) {
        // Still reviewable — overlaps between these files are caught — but
        // importing waits until the check against recorded rows succeeds.
        _checkFailed = true;
      }
      final List<Object?> added = (await _engine.call('review', <String, Object?>{
        'current': _items,
        'transactions': transactions,
        'existing': existing,
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

  /// Recorded movements on the account around every statement in the session.
  Future<List<Map<String, Object?>>> _existingFor(
    List<ImportedStatement> statements,
  ) async {
    final Object? range = await _engine.call('sessionRange', <String, Object?>{
      'statements': statements
          .map((ImportedStatement s) => <String, Object?>{'period': s.json['period']})
          .toList(),
    });
    if (range is! Map<String, Object?>) return <Map<String, Object?>>[];
    return _existingBetween(
      AppDateUtils.parseDate(range['from']! as String),
      AppDateUtils.parseDate(range['to']! as String),
    );
  }

  Future<List<Map<String, Object?>>> _existingBetween(
    DateTime from,
    DateTime to,
  ) async {
    final List<LedgerEntry> entries = await _ledger.fetchForAccount(
      userId: _userId!,
      accountId: _account!.id,
      from: DateTime(from.year, from.month, from.day - nearbyDays),
      toExclusive: DateTime(to.year, to.month, to.day + nearbyDays + 1),
    );
    return entries.map(EngineJson.existing).toList();
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

  Future<void> edit(String id, Map<String, Object?> patch) => reduce(
        <String, Object?>{'type': 'edit', 'id': id, 'patch': patch},
      );

  Future<void> remove(String id) =>
      reduce(<String, Object?>{'type': 'remove', 'id': id});

  /// Kinds valid for a direction, from the engine.
  Future<List<String>> kindsFor(bool debit) async {
    final Object? kinds = await _engine.call(
      'kindsFor',
      <String, Object?>{'type': debit ? 'debit' : 'credit'},
    );
    return (kinds as List<Object?>? ?? const <Object?>[]).whereType<String>().toList();
  }

  /// Re-runs the check against recorded transactions after it failed.
  Future<void> recheck() async {
    if (_statements.isEmpty) return;
    _rechecking = true;
    safeNotify();
    try {
      final List<Map<String, Object?>> existing = await _existingFor(_statements);
      final List<Object?> next = (await _engine.call('recheck', <String, Object?>{
        'items': _items,
        'existing': existing,
      }))! as List<Object?>;
      _items = next.cast<Map<String, Object?>>();
      await _refreshView();
      _checkFailed = false;
    } catch (error) {
      _problem =
          'Still could not check for recorded transactions. ${ErrorMapper.map(error).message}';
    } finally {
      _rechecking = false;
      safeNotify();
    }
  }

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
      final List<DateTime> dates = preview.operations
          .map((Map<String, Object?> op) => AppDateUtils.parseDate(op['date']! as String))
          .toList()
        ..sort();
      final List<Map<String, Object?>> fresh =
          await _existingBetween(dates.first, dates.last);
      final ImportPreview finalPlan = ImportPreview((await _engine.call('finalPlan', <String, Object?>{
        'plan': preview.json,
        'items': _items,
        'fresh': fresh,
      }))! as Map<String, Object?>);
      outcome.skipped = finalPlan.skipped.length;

      int consecutive = 0;
      final List<Map<String, Object?>> ops = finalPlan.operations;
      for (int i = 0; i < ops.length; i++) {
        if (consecutive >= maxConsecutiveFailures) {
          outcome.notAttempted = ops.length - i;
          break;
        }
        try {
          await _write(userId, ops[i]);
          consecutive = 0;
          switch (ops[i]['type']) {
            case 'expense':
              outcome.expenses++;
            case 'income':
              outcome.income++;
            default:
              outcome.movements++;
          }
        } catch (error) {
          consecutive++;
          outcome.failures.add(ErrorMapper.map(error).message);
        }
        _importing = (i + 1, ops.length);
        safeNotify();
      }
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

  /// One planned write, through the app's normal write paths.
  Future<void> _write(String userId, Map<String, Object?> op) async {
    final String accountId = op['bankAccountId']! as String;
    final double amount = (op['amount']! as num).toDouble();
    final DateTime date = AppDateUtils.parseDate(op['date']! as String);
    final String? description = op['description'] as String?;
    switch (op['type']) {
      case 'expense':
        await _expenses.create(Expense(
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
        ));
      case 'income':
        await _income.create(Income(
          id: '',
          userId: userId,
          amount: amount,
          incomeDate: date,
          source: op['source'] as String?,
          description: description,
          bankAccountId: accountId,
        ));
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
          );
        } else if (op['direction'] == 'credit') {
          await _ledger.deposit(
            userId: userId,
            accountId: accountId,
            amount: amount,
            date: date,
            description: description,
          );
        } else {
          await _ledger.withdraw(
            userId: userId,
            accountId: accountId,
            amount: amount,
            date: date,
            description: description,
          );
        }
      default:
        throw const AppException('Unknown import row.');
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
