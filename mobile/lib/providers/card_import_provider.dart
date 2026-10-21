import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

import '../core/errors/app_exception.dart';
import '../core/utils/date_utils.dart';
import '../models/bank_account.dart';
import '../models/card_statement.dart';
import '../models/credit_card.dart';
import '../models/emi_plan.dart';
import '../models/expense.dart';
import '../models/expense_category.dart';
import '../models/ledger_entry.dart';
import '../repositories/credit_card_repository.dart';
import '../repositories/emi_plan_repository.dart';
import '../repositories/expense_repository.dart';
import '../repositories/ledger_repository.dart';
import '../services/schema_capabilities.dart';
import '../services/sms/sms_expense_draft.dart';
import '../services/statement_import/screenshot_prep.dart';
import '../services/statement_import/statement_engine.dart';
import 'async_state.dart';

/// One screenshot read into the session.
class ImportedShot {
  const ImportedShot({
    required this.id,
    required this.name,
    required this.rows,
    required this.warnings,
    this.last4,
    this.month,
  });

  final String id;
  final String name;
  final int rows;
  final List<String> warnings;

  /// What the screenshot's header showed, when it did.
  final String? last4;
  final int? month;
}

/// A statement the card can have screenshots of.
class CardCycleOption {
  const CardCycleOption({required this.cycle, required this.label, required this.open});

  /// The cycle as the engine shapes it ({start, end, dueDate}).
  final Map<String, Object?> cycle;
  final String label;
  final bool open;

  String get end => cycle['end']! as String;
}

/// What an import wrote, and what it could not.
class CardImportOutcome {
  const CardImportOutcome({
    required this.counts,
    required this.skipped,
    required this.failed,
    required this.notAttempted,
  });

  final Map<String, Object?> counts;
  final int skipped;
  final List<String> failed;
  final int notAttempted;
}

/// A card statement imported from screenshots — the web app's own parser,
/// review rules, duplicate checks, EMI grouping and import plan, running in
/// the offline engine (assets/statement_engine). The screenshots are read
/// here with ML Kit, on the phone, and deleted the moment their text is out.
///
/// The engine is stateless: this provider holds the session JSON and passes
/// it back with every call, so the engine decides everything and the screen
/// only renders what `cardView` says.
class CardImportProvider extends AsyncProvider {
  CardImportProvider({
    required StatementEngine engine,
    required ExpenseRepository expenses,
    required LedgerRepository ledger,
    required CreditCardRepository cards,
    required EmiPlanRepository plans,
    ImagePicker? picker,
    TextRecognizer? recognizer,
  })  : _engine = engine,
        _expenses = expenses,
        _ledger = ledger,
        _cards = cards,
        _plans = plans,
        _picker = picker ?? ImagePicker(),
        _recognizer = recognizer;

  final StatementEngine _engine;
  final ExpenseRepository _expenses;
  final LedgerRepository _ledger;
  final CreditCardRepository _cards;
  final EmiPlanRepository _plans;
  final ImagePicker _picker;
  TextRecognizer? _recognizer;

  /// Bank debits are read this far around the statement period, for
  /// matching its bill payments.
  static const int _paymentWindowDays = 10;

  String? _userId;
  CreditCard? _card;
  List<CardCycleOption> _cycles = const <CardCycleOption>[];
  CardCycleOption? _cycle;
  List<ImportedShot> _shots = <ImportedShot>[];
  Map<String, Object?>? _session;
  Map<String, Object?>? _view;
  Map<String, Object?>? _ctx;
  List<EmiPlan> _plansOnCard = <EmiPlan>[];
  List<BankAccount> _accounts = const <BankAccount>[];
  List<ExpenseCategory> _categories = const <ExpenseCategory>[];
  String _currency = 'INR';

  /// The screenshot being read, with its place in the batch.
  ({String name, int index, int total, bool checking})? _reading;
  String? _problem;
  bool _checkFailed = false;
  ({int done, int total})? _importing;
  CardImportOutcome? _result;

  CreditCard? get card => _card;
  List<CardCycleOption> get cycles => _cycles;
  CardCycleOption? get cycle => _cycle;
  List<ImportedShot> get shots => List<ImportedShot>.unmodifiable(_shots);
  Map<String, Object?>? get session => _session;
  Map<String, Object?>? get view => _view;
  List<EmiPlan> get plans => List<EmiPlan>.unmodifiable(_plansOnCard);
  List<BankAccount> get accounts => _accounts;
  ({String name, int index, int total, bool checking})? get reading => _reading;
  String? get problem => _problem;
  bool get checkFailed => _checkFailed;
  ({int done, int total})? get importing => _importing;
  CardImportOutcome? get result => _result;
  bool get hasContext => _ctx != null;

  /// The session's rows, as the engine holds them.
  List<Map<String, Object?>> get items =>
      ((_session?['items'] as List<Object?>?) ?? const <Object?>[])
          .cast<Map<String, Object?>>();

  List<Map<String, Object?>> get groups =>
      ((_session?['groups'] as List<Object?>?) ?? const <Object?>[])
          .cast<Map<String, Object?>>();

  Map<String, Object?>? itemView(String id) =>
      (_view?['items'] as Map<String, Object?>?)?[id] as Map<String, Object?>?;

  Map<String, Object?>? groupView(String id) =>
      (_view?['groups'] as Map<String, Object?>?)?[id] as Map<String, Object?>?;

  Map<String, Object?> get summary =>
      (_view?['summary'] as Map<String, Object?>?) ?? const <String, Object?>{};

  Map<String, Object?>? item(String id) {
    for (final Map<String, Object?> row in items) {
      if (row['id'] == id) return row;
    }
    return null;
  }

  Map<String, Object?>? group(String id) {
    for (final Map<String, Object?> g in groups) {
      if (g['id'] == id) return g;
    }
    return null;
  }

  List<Map<String, Object?>> membersOf(String groupId) =>
      items.where((Map<String, Object?> i) => i['groupId'] == groupId).toList();

  /// Starts a session for [card]: the statements it can have screenshots of,
  /// the first closed one chosen.
  Future<void> start({
    required String userId,
    required CreditCard card,
    required List<BankAccount> accounts,
    required List<ExpenseCategory> categories,
    required String currency,
  }) async {
    _userId = userId;
    _card = card;
    _accounts = accounts;
    _categories = categories;
    _currency = currency;
    _shots = <ImportedShot>[];
    _session = null;
    _view = null;
    _ctx = null;
    _problem = null;
    _checkFailed = false;
    _result = null;
    _importing = null;
    setLoading();
    try {
      final List<Object?> raw = (await _engine.call('cardCycles', <String, Object?>{
        'card': EngineJson.card(card),
        'today': AppDateUtils.toDateString(AppDateUtils.today()),
      }))! as List<Object?>;
      _cycles = raw
          .cast<Map<String, Object?>>()
          .map((Map<String, Object?> c) => CardCycleOption(
                cycle: c['cycle']! as Map<String, Object?>,
                label: c['label']! as String,
                open: c['open'] == true,
              ))
          .toList();
      _cycle = _cycles.length > 1 ? _cycles[1] : _cycles.firstOrNull;
      _plansOnCard = SchemaCapabilities.emi
          ? await _plans.fetchPlans(userId: userId, cardId: card.id)
          : <EmiPlan>[];
      setReady();
    } catch (error) {
      setError(error);
    }
  }

  void chooseCycle(CardCycleOption option) {
    if (_shots.isNotEmpty) return;
    _cycle = option;
    safeNotify();
  }

  /// Forgets the session's screenshots and rows; the card and statement stay.
  void reset() {
    _shots = <ImportedShot>[];
    _session = null;
    _view = null;
    _ctx = null;
    _problem = null;
    _checkFailed = false;
    _result = null;
    _importing = null;
    safeNotify();
  }

  // ---- Reading screenshots -------------------------------------------------

  /// A stable id from the bytes, so the same screenshot added twice is one.
  static String _hashOf(Uint8List bytes) {
    int h = 0x811c9dc5;
    for (final int b in bytes) {
      h = ((h ^ b) * 0x01000193) & 0xffffffff;
    }
    return '${h.toRadixString(16).padLeft(8, '0')}${bytes.length.toRadixString(16)}';
  }

  /// ML Kit's lines with their boxes, in the engine's OcrLine shape.
  static List<Map<String, Object?>> _ocrLines(RecognizedText recognised) =>
      <Map<String, Object?>>[
        for (final TextBlock block in recognised.blocks)
          for (final TextLine line in block.lines)
            if (line.text.trim().isNotEmpty)
              <String, Object?>{
                'text': line.text.trim(),
                'x': line.boundingBox.left,
                'y': line.boundingBox.top,
                'width': line.boundingBox.width,
                'height': line.boundingBox.height,
              },
      ];

  /// Removes the picker's cached copy of the image. Best effort on purpose.
  static Future<void> _discard(XFile file) async {
    try {
      final File cached = File(file.path);
      if (await cached.exists()) await cached.delete();
    } on Exception {
      // Nothing useful to do, and nothing sensitive to log.
    }
  }

  /// Opens the gallery for several screenshots and reads each on the phone.
  Future<void> pickAndRead() async {
    final CreditCard? card = _card;
    final CardCycleOption? cycle = _cycle;
    final String? userId = _userId;
    if (card == null || cycle == null || userId == null || _reading != null) return;
    List<XFile> picked;
    try {
      picked = await _picker.pickMultiImage(maxWidth: 2000, imageQuality: 92);
    } on Exception catch (error) {
      _problem = _permission(error)
          ? 'Photo access was refused. Allow it in Settings to read screenshots.'
          : 'The screenshots could not be opened.';
      safeNotify();
      return;
    }
    if (picked.isEmpty) return;
    _problem = null;
    final TextRecognizer recognizer =
        _recognizer ??= TextRecognizer(script: TextRecognitionScript.latin);
    List<Map<String, Object?>> current = List<Map<String, Object?>>.of(items);
    for (int index = 0; index < picked.length; index++) {
      final XFile file = picked[index];
      _reading = (name: file.name, index: index + 1, total: picked.length, checking: false);
      safeNotify();
      try {
        final Uint8List bytes = await file.readAsBytes();
        final String shotId = _hashOf(bytes);
        if (_shots.any((ImportedShot s) => s.id == shotId)) {
          _problem = '${file.name} was already added.';
          continue;
        }
        final RecognizedText recognised = await ScreenshotPrep.read(
          bytes,
          file.path,
          (String path) => recognizer.processImage(InputImage.fromFilePath(path)),
        );
        final Map<String, Object?> read = (await _engine.call('cardItems', <String, Object?>{
          'shot': <String, Object?>{'id': shotId, 'name': file.name, 'lines': _ocrLines(recognised)},
          'cycle': cycle.cycle,
          'categories': _categories.map(EngineJson.category).toList(),
          'fallbackCategoryId': SmsDraftBuilder.fallbackCategory(_categories)?.id,
        }))! as Map<String, Object?>;
        final Map<String, Object?> parsed = read['parsed']! as Map<String, Object?>;
        final List<Map<String, Object?>> added =
            (read['items']! as List<Object?>).cast<Map<String, Object?>>();
        if (added.isEmpty) {
          _problem = 'No transactions were found in ${file.name}. Screenshots of '
              "the statement's transaction list work best — one row per "
              'transaction, with the amount on the right.';
          continue;
        }
        _shots = <ImportedShot>[
          ..._shots,
          ImportedShot(
            id: shotId,
            name: file.name,
            rows: added.length,
            warnings: ((parsed['warnings'] as List<Object?>?) ?? const <Object?>[]).cast<String>(),
            last4: parsed['last4'] as String?,
            month: (parsed['month'] as num?)?.toInt(),
          ),
        ];
        current = <Map<String, Object?>>[...current, ...added];
        if (_ctx == null) {
          _reading = (name: file.name, index: index + 1, total: picked.length, checking: true);
          safeNotify();
          try {
            _ctx = await _readContext(userId, card, cycle);
            _checkFailed = false;
          } catch (_) {
            // Still reviewable — overlaps between screenshots are caught — but
            // importing waits until what the card holds could be read.
            _checkFailed = true;
          }
        }
        await _settle(current);
      } on StatementEngineException catch (error) {
        _problem = '${file.name}: ${error.message}';
      } catch (error) {
        _problem = '${file.name}: ${ErrorMapper.map(error).message}';
      } finally {
        await _discard(file);
      }
    }
    _reading = null;
    safeNotify();
  }

  static bool _permission(Exception error) {
    final String text = error.toString().toLowerCase();
    return text.contains('permission') ||
        text.contains('denied') ||
        text.contains('photo_access');
  }

  /// What the review compares the session with, read once per statement.
  Future<Map<String, Object?>> _readContext(
    String userId,
    CreditCard card,
    CardCycleOption cycle,
  ) async {
    final DateTime start = AppDateUtils.parseDate(cycle.cycle['start']! as String);
    final DateTime end = AppDateUtils.parseDate(cycle.cycle['end']! as String);
    DateTime days(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);
    final List<BankAccount> banks = _accounts
        .where((BankAccount a) => a.isActive && a.kind != AccountKind.cash)
        .toList();
    final List<Object> results = await Future.wait(<Future<Object>>[
      _cards.fetchEntries(userId: userId, cardId: card.id),
      _expenses.fetchRange(
        userId: userId,
        from: days(start, -45 - 7),
        toExclusive: days(end, _paymentWindowDays + 8),
      ),
      _plans.fetchPlans(userId: userId, cardId: card.id),
      Future.wait(banks.map((BankAccount a) => _ledger.fetchForAccount(
            userId: userId,
            accountId: a.id,
            from: days(start, -_paymentWindowDays),
            toExclusive: days(end, _paymentWindowDays + 1),
          ))),
    ]);
    final List<EmiPlan> plans = results[2] as List<EmiPlan>;
    _plansOnCard = plans;
    return <String, Object?>{
      'card': EngineJson.card(card),
      'cycle': cycle.cycle,
      'entries': (results[0] as List<CardEntry>).map(EngineJson.cardEntry).toList(),
      'recorded': (results[1] as List<Expense>).map(EngineJson.recordedExpense).toList(),
      'plans': plans.map((EmiPlan p) => p.toEngineMap()).toList(),
      'debits': (results[3] as List<List<LedgerEntry>>)
          .expand((List<LedgerEntry> l) => l)
          .map((LedgerEntry e) => EngineJson.ledgerEntry(e))
          .toList(),
    };
  }

  Map<String, Object?> get _emptyContext => <String, Object?>{
        'card': EngineJson.card(_card!),
        'cycle': _cycle!.cycle,
        'entries': const <Object?>[],
        'recorded': const <Object?>[],
        'plans': _plansOnCard.map((EmiPlan p) => p.toEngineMap()).toList(),
        'debits': const <Object?>[],
      };

  /// Duplicate flags, EMI groups, plan and payment suggestions over the whole
  /// session, with the user's choices kept.
  Future<void> _settle(List<Map<String, Object?>> rows) async {
    _session = (await _engine.call('cardSettle', <String, Object?>{
      'session': _session,
      'items': rows,
      'ctx': _ctx ?? _emptyContext,
    }))! as Map<String, Object?>;
    await _refreshView();
  }

  Future<void> _refreshView() async {
    final Map<String, Object?>? session = _session;
    if (session == null) {
      _view = null;
      return;
    }
    _view = (await _engine.call('cardView', <String, Object?>{
      'session': session,
      'plans': _plansOnCard.map((EmiPlan p) => p.toEngineMap()).toList(),
      'currency': _currency,
    }))! as Map<String, Object?>;
    safeNotify();
  }

  /// Reads what the card holds again and re-settles the session.
  Future<void> recheck() async {
    final CreditCard? card = _card;
    final CardCycleOption? cycle = _cycle;
    final String? userId = _userId;
    if (card == null || cycle == null || userId == null) return;
    try {
      _ctx = await _readContext(userId, card, cycle);
      _checkFailed = false;
      await _settle(items);
    } catch (error) {
      _problem = ErrorMapper.map(error).message;
      safeNotify();
    }
  }

  // ---- Review edits --------------------------------------------------------

  /// One review action, in the shapes of the web's CardReviewAction.
  Future<void> dispatch(Map<String, Object?> action) async {
    final Map<String, Object?>? session = _session;
    if (session == null) return;
    try {
      _session = (await _engine.call('cardReduce', <String, Object?>{
        'session': session,
        'action': action,
      }))! as Map<String, Object?>;
      await _refreshView();
    } on StatementEngineException catch (error) {
      _problem = error.message;
      safeNotify();
    }
  }

  Future<void> toggle(String itemId) => dispatch(<String, Object?>{'type': 'toggle', 'itemId': itemId});

  Future<void> selectAll(bool selected) =>
      dispatch(<String, Object?>{'type': 'selectAll', 'selected': selected});

  Future<void> decideDuplicate(String itemId, String? decision) =>
      dispatch(<String, Object?>{'type': 'decideDuplicate', 'itemId': itemId, 'decision': decision});

  Future<void> overrideDuplicate(String itemId, bool overridden) =>
      dispatch(<String, Object?>{'type': 'overrideDuplicate', 'itemId': itemId, 'overridden': overridden});

  Future<void> edit(String itemId, Map<String, Object?> edit) =>
      dispatch(<String, Object?>{'type': 'edit', 'itemId': itemId, 'edit': edit});

  Future<void> setPaymentLink(String itemId, Map<String, Object?>? link) =>
      dispatch(<String, Object?>{'type': 'setPaymentLink', 'itemId': itemId, 'link': link});

  /// Moves a row into [groupId] (a fresh group when null), or out of any with [remove].
  Future<void> regroupItem(String itemId, {String? groupId, bool remove = false}) =>
      dispatch(<String, Object?>{'type': 'group', 'itemId': itemId, 'groupId': groupId, 'remove': remove});

  Future<void> regroup() => dispatch(const <String, Object?>{'type': 'regroup'});

  Future<void> setGroupPlan(String groupId, {String? planId, Map<String, Object?>? newPlan}) =>
      dispatch(<String, Object?>{
        'type': 'setGroupPlan',
        'groupId': groupId,
        'planId': planId,
        'newPlan': newPlan,
        'source': 'user',
      });

  /// A row's direction changed (a misread "+"): its identity is rebuilt from the top.
  Future<void> changeDirection(String itemId, String direction, Map<String, Object?> edit) async {
    final List<Map<String, Object?>> rows = items.map((Map<String, Object?> row) {
      if (row['id'] != itemId) return row;
      return <String, Object?>{
        ...row,
        ...edit,
        'direction': direction,
        'kindSource': 'user',
        'edited': true,
      };
    }).toList();
    await _settle(rows);
  }

  /// Bank debits that could be this payment, closest first.
  Future<List<LedgerEntry>> paymentCandidates(Map<String, Object?> row) async {
    final List<Object?> debits =
        ((_ctx?['debits'] as List<Object?>?) ?? const <Object?>[]);
    if (debits.isEmpty) return const <LedgerEntry>[];
    final List<Object?> found = (await _engine.call('cardPaymentCandidates', <String, Object?>{
      'debits': debits,
      'amount': row['amount'],
      'date': row['date'],
    }))! as List<Object?>;
    return found
        .cast<Map<String, Object?>>()
        .map((Map<String, Object?> e) => LedgerEntry.fromMap(<String, dynamic>{
              'id': e['id'],
              'user_id': e['userId'],
              'account_id': e['accountId'],
              'direction': e['direction'],
              'amount': e['amount'],
              'txn_date': e['txnDate'],
              'description': e['description'],
            }))
        .toList();
  }

  // ---- Import --------------------------------------------------------------

  /// The writes the session adds up to, in the engine's words.
  Future<Map<String, Object?>> preview() async {
    final Map<String, Object?>? session = _session;
    if (session == null) return const <String, Object?>{};
    final Map<String, Object?> planned = (await _engine.call('cardPlan', <String, Object?>{
      'session': session,
      'categories': _categories.map(EngineJson.category).toList(),
      'plans': _plansOnCard.map((EmiPlan p) => p.toEngineMap()).toList(),
    }))! as Map<String, Object?>;
    return planned['counts']! as Map<String, Object?>;
  }

  /// After this many failures in a row the problem is not the data.
  static const int _maxConsecutiveFailures = 3;

  /// Writes the session, re-checking the card as it is now first. Plans are
  /// created before the components that name them.
  Future<bool> runImport() async {
    final Map<String, Object?>? session = _session;
    final String? userId = _userId;
    final CreditCard? card = _card;
    if (session == null || userId == null || card == null || _importing != null) return false;
    if (!SchemaCapabilities.emi) {
      _problem = 'Card statement import needs the 016 migration. Run '
          'ui/supabase/016_card_statement_emi.sql, then try again.';
      safeNotify();
      return false;
    }
    _importing = (done: 0, total: 0);
    _problem = null;
    safeNotify();
    try {
      final Map<String, Object?> planned = (await _engine.call('cardPlan', <String, Object?>{
        'session': session,
        'categories': _categories.map(EngineJson.category).toList(),
        'plans': _plansOnCard.map((EmiPlan p) => p.toEngineMap()).toList(),
      }))! as Map<String, Object?>;
      final List<CardEntry> fresh = await _cards.fetchEntries(userId: userId, cardId: card.id);
      final Map<String, Object?> plan = (await _engine.call('cardFinalPlan', <String, Object?>{
        'plan': planned['plan'],
        'items': items,
        'fresh': fresh.map(EngineJson.cardEntry).toList(),
      }))! as Map<String, Object?>;
      final List<Map<String, Object?>> operations =
          (plan['operations']! as List<Object?>).cast<Map<String, Object?>>();
      final int skipped = ((plan['skipped'] as List<Object?>?) ?? const <Object?>[]).length;

      final Map<String, String> planIds = <String, String>{};
      final Set<String> failedGroups = <String>{};
      final List<Map<String, Object?>> written = <Map<String, Object?>>[];
      final List<String> failed = <String>[];
      int consecutive = 0;
      int notAttempted = 0;
      for (int index = 0; index < operations.length; index++) {
        if (consecutive >= _maxConsecutiveFailures) {
          notAttempted = operations.length - index;
          break;
        }
        final Map<String, Object?> op = operations[index];
        final String type = op['type']! as String;
        final Map<String, Object?>? emi = op['emi'] as Map<String, Object?>?;
        final Map<String, Object?>? planRef = emi?['plan'] as Map<String, Object?>?;
        final String? groupRef = planRef?['groupId'] as String?;
        if (groupRef != null && failedGroups.contains(groupRef) && type != 'createPlan') {
          failed.add('Its EMI plan could not be created.');
          _importing = (done: index + 1, total: operations.length);
          safeNotify();
          continue;
        }
        try {
          final String? id = await _write(userId, card, op, planIds);
          if (type == 'createPlan' && id != null) planIds[op['groupId']! as String] = id;
          consecutive = 0;
          written.add(op);
        } catch (error) {
          consecutive++;
          if (type == 'createPlan') failedGroups.add(op['groupId']! as String);
          failed.add(ErrorMapper.map(error).message);
        }
        _importing = (done: index + 1, total: operations.length);
        safeNotify();
      }
      final Map<String, Object?> counts = (await _engine.call('cardCounts', <String, Object?>{
        'operations': written,
      }))! as Map<String, Object?>;
      _result = CardImportOutcome(
        counts: counts,
        skipped: skipped,
        failed: failed,
        notAttempted: notAttempted,
      );
      return true;
    } catch (error) {
      _problem = error is StatementEngineException
          ? error.message
          : ErrorMapper.map(error).message;
      return false;
    } finally {
      _importing = null;
      safeNotify();
    }
  }

  String _planOf(Map<String, Object?> ref, Map<String, String> plans) {
    final String? planId = ref['planId'] as String?;
    if (planId != null) return planId;
    final String? created = plans[ref['groupId'] as String?];
    if (created == null) {
      throw const AppException(
        'The EMI plan for this instalment could not be created, so the row was left out.',
      );
    }
    return created;
  }

  /// One operation, with the app's own repositories — exactly what adding
  /// the row by hand produces.
  Future<String?> _write(
    String userId,
    CreditCard card,
    Map<String, Object?> op,
    Map<String, String> plans,
  ) async {
    final Map<String, Object?>? emi = op['emi'] as Map<String, Object?>?;
    final String? planId = emi == null ? null : _planOf(emi['plan']! as Map<String, Object?>, plans);
    final String? statement = op['statementDate'] as String?;
    switch (op['type']) {
      case 'createPlan':
        final Map<String, Object?> draft = op['draft']! as Map<String, Object?>;
        return _plans.create(
          userId: userId,
          plan: EmiPlan(
            id: '',
            userId: userId,
            cardId: card.id,
            title: draft['title']! as String,
            reference: draft['reference'] as String?,
            person: draft['person'] as String?,
            includeCharges: draft['includeCharges'] != false,
            purchaseAmount: (draft['purchaseAmount'] as num?)?.toDouble(),
            monthlyAmount: (draft['monthlyAmount'] as num?)?.toDouble(),
            tenureMonths: (draft['tenureMonths'] as num?)?.toInt(),
            startDate: draft['startDate'] == null
                ? null
                : AppDateUtils.parseDate(draft['startDate']! as String),
            categoryId: draft['categoryId'] as String?,
          ),
        );
      case 'expense':
        await _expenses.create(Expense(
          id: '',
          userId: userId,
          amount: (op['amount']! as num).toDouble(),
          expenseDate: AppDateUtils.parseDate(op['date']! as String),
          categoryId: op['categoryId'] as String?,
          creditCardId: card.id,
          merchant: op['merchant'] as String?,
          description: op['description'] as String?,
          notes: op['notes'] as String?,
          emiPlanId: planId,
          emiComponent: emi?['component'] as String?,
          statementDate: statement == null ? null : AppDateUtils.parseDate(statement),
        ));
        return null;
      case 'cardTransaction':
        await _cards.recordTransaction(
          userId: userId,
          cardId: card.id,
          kind: CardTransactionKindWire.parse(op['kind'] as String?),
          direction: op['direction'] == 'debit' ? LedgerDirection.debit : LedgerDirection.credit,
          amount: (op['amount']! as num).toDouble(),
          date: AppDateUtils.parseDate(op['date']! as String),
          description: op['description'] as String?,
          emiPlanId: planId,
          emiComponent: emi?['component'] as String?,
          statementDate: statement == null ? null : AppDateUtils.parseDate(statement),
        );
        return null;
      case 'linkPayment':
        await _ledger.linkToCard(
          userId: userId,
          entryId: op['entryId']! as String,
          cardId: card.id,
        );
        return null;
      default:
        throw AppException('Unknown import step: ${op['type']}');
    }
  }

  @override
  void dispose() {
    unawaited(_recognizer?.close());
    _recognizer = null;
    super.dispose();
  }
}
