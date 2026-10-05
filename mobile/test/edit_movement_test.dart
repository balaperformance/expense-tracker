// Changing how a recorded statement line is recorded (the web app's
// EditMovementSheet): the request built for each treatment, the opening
// choice of a saved movement, what is still missing, the save through the
// engine and `apply_bank_treatment` (with fakes — nothing reaches a
// database), and the sheet itself at real phone widths. Every figure and
// name is invented.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/models/credit_card.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/ledger_entry.dart';
import 'package:expense_tracker/models/movement_treatment.dart';
import 'package:expense_tracker/models/receivable.dart';
import 'package:expense_tracker/providers/category_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/providers/statement_provider.dart';
import 'package:expense_tracker/repositories/category_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/repositories/profile_repository.dart';
import 'package:expense_tracker/repositories/tag_repository.dart';
import 'package:expense_tracker/screens/accounts/edit_movement_sheet.dart';
import 'package:expense_tracker/services/preferences_service.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';
import 'package:expense_tracker/services/statement_import/statement_engine.dart';

const BankAccount _hdfc = BankAccount(
  id: 'a1',
  userId: 'u1',
  bankName: 'HDFC Bank',
  nickname: 'HDFC Salary Account',
  last4: '6459',
);
const BankAccount _savings = BankAccount(
  id: 'a2',
  userId: 'u1',
  bankName: 'Indian Bank',
  nickname: 'Indian Bank Savings',
  last4: '4462',
);
const BankAccount _cash = BankAccount(
  id: 'cash1',
  userId: 'u1',
  bankName: 'Cash',
  nickname: 'Cash',
  kind: AccountKind.cash,
);
const CreditCard _card = CreditCard(
  id: 'k1',
  userId: 'u1',
  cardName: 'Travel Platinum',
  issuer: 'HDFC Bank',
  last4: '0042',
  creditLimit: 100000,
  statementDay: 5,
  paymentDueDay: 25,
);
const ExpenseCategory _food = ExpenseCategory(id: 'c1', userId: 'u1', name: 'Food & Dining');

LedgerEntry _entry({
  LedgerDirection direction = LedgerDirection.debit,
  double amount = 1500,
  String? expenseId,
  String? incomeId,
  String? group,
  String? other,
  String? card,
  String? receivable,
  String? categoryId,
}) =>
    LedgerEntry(
      id: 'e1',
      userId: 'u1',
      accountId: 'a1',
      direction: direction,
      amount: amount,
      txnDate: DateTime(2026, 9, 12),
      description: 'UPI/600012345678/Arun',
      expenseId: expenseId,
      incomeId: incomeId,
      transferGroupId: group,
      counterpartyAccountId: other,
      creditCardId: card,
      receivableId: receivable,
      categoryId: categoryId,
    );

ClaimSummary _claim({
  String id = 'r1',
  ReceivableKind kind = ReceivableKind.loan,
  String person = 'Arun',
  String? ledgerEntryId,
  String? expenseId,
  double principal = 1500,
  List<ClaimRepayment> repayments = const <ClaimRepayment>[],
  String? note,
  DateTime? dueDate,
}) {
  final double received = repayments.fold<double>(0, (double s, ClaimRepayment r) => s + r.amount);
  return ClaimSummary(
    receivable: Receivable(
      id: id,
      userId: 'u1',
      kind: kind,
      person: person,
      ledgerEntryId: ledgerEntryId,
      expenseId: expenseId,
      note: note,
      dueDate: dueDate,
    ),
    source: ClaimSource(date: DateTime(2026, 9, 1), amount: principal, title: 'Money lent'),
    principal: principal,
    received: received,
    outstanding: principal - received,
    status: claimStatus(principal, received),
    repayments: repayments,
    overdue: false,
  );
}

ClaimRepayment _repayment(String entryId, double amount) => ClaimRepayment(
      entryId: entryId,
      receivableId: 'r1',
      accountId: 'a1',
      amount: amount,
      date: DateTime(2026, 9, 5),
    );

/// The engine, answering as the bundled web domain does for these calls.
class _Engine implements StatementEngine {
  final List<(String, Map<String, Object?>)> calls = <(String, Map<String, Object?>)>[];
  bool knowsTransferMatches = true;
  List<Object?> transferMatches = <Object?>[];

  @override
  Future<Object?> call(String name, Map<String, Object?> args) async {
    calls.add((name, args));
    switch (name) {
      case 'kindsFor':
        return args['type'] == 'debit'
            ? <Object?>['expense', 'transfer', 'loan']
            : <Object?>['income', 'refund', 'transfer', 'loan', 'reimbursement'];
      case 'treatmentPayload':
        return <String, Object?>{'type': 'from-engine', 'request': args['request']};
      case 'transferMatches':
        if (!knowsTransferMatches) {
          throw const StatementEngineException('failed', 'Unknown engine call: transferMatches');
        }
        return transferMatches;
      case 'autoMatches':
        return <String, Object?>{'edit': 'm1'};
    }
    throw StateError('unexpected call $name');
  }

  List<Map<String, Object?>> argsOf(String name) => <Map<String, Object?>>[
        for (final (String n, Map<String, Object?> a) in calls)
          if (n == name) a,
      ];

  @override
  Future<PickedStatementFile?> pickFile() async => null;

  @override
  Future<void> release(String token) async {}
}

class _Ledger extends LedgerRepository {
  _Ledger(super.client);

  List<ClaimSummary> claims = <ClaimSummary>[];
  List<LedgerEntry> otherAccountRows = <LedgerEntry>[];
  List<String> tagNames = <String>[];
  bool failTags = false;
  bool failClaims = false;
  final List<Map<String, Object?>> treatments = <Map<String, Object?>>[];
  final List<(TagKind, String, List<String>)> tagWrites = <(TagKind, String, List<String>)>[];
  int statementReads = 0;

  @override
  Future<List<LedgerEntry>> fetchForAccount({
    required String userId,
    required String accountId,
    DateTime? from,
    DateTime? toExclusive,
  }) async {
    if (accountId == 'a1') {
      statementReads++;
      return const <LedgerEntry>[];
    }
    return otherAccountRows.where((LedgerEntry e) => e.accountId == accountId).toList();
  }

  @override
  Future<double> netBefore({
    required String userId,
    required String accountId,
    required DateTime before,
  }) async =>
      0;

  @override
  Future<List<ClaimSummary>> fetchClaims({required String userId}) async {
    if (failClaims) throw StateError('offline');
    return claims;
  }

  @override
  Future<List<String>> fetchTagNames({
    required String userId,
    required TagKind kind,
    required String id,
  }) async =>
      tagNames;

  @override
  Future<String?> fetchIncomeSource({required String userId, required String incomeId}) async =>
      'Salary';

  @override
  Future<List<ClaimPurchase>> fetchPurchases({
    required String userId,
    required DateTime from,
    required DateTime toExclusive,
    int limit = 80,
  }) async =>
      <ClaimPurchase>[
        ClaimPurchase(id: 'x7', amount: 900, date: DateTime(2026, 9, 2), title: 'Corner Cafe'),
      ];

  @override
  Future<String> applyBankTreatment({
    required String entryId,
    required Map<String, Object?> treatment,
  }) async {
    treatments.add(<String, Object?>{'entryId': entryId, ...treatment});
    return entryId;
  }

  @override
  Future<({String? expenseId, String? incomeId})> documentsOfEntry({
    required String userId,
    required String entryId,
  }) async =>
      (expenseId: 'x-new', incomeId: null);

  @override
  Future<void> setDocumentTags({
    required TagKind kind,
    required String id,
    required List<String> names,
  }) async {
    if (failTags) throw StateError('offline');
    tagWrites.add((kind, id, names));
  }
}

class _Categories extends CategoryProvider {
  _Categories(SupabaseClient client) : super(CategoryRepository(client));

  @override
  List<ExpenseCategory> get categories => const <ExpenseCategory>[_food];
}

void main() {
  final DateTime day = DateTime(2026, 9, 12);

  group('the request built for each treatment', () {
    test('a plain debit becomes an expense paid for someone', () {
      final Map<String, Object?> request = buildTreatmentRequest(
        entry: _entry(),
        account: _hdfc,
        state: const TreatmentState(
          kind: TreatmentKind.expense,
          categoryId: 'c1',
          reimbursable: true,
          person: ' Arun ',
        ),
        amount: 1500,
        date: day,
        description: 'UPI/600012345678/Arun',
      );
      expect(request, <String, Object?>{
        'kind': 'expense',
        'direction': 'debit',
        'amount': 1500.0,
        'date': '2026-09-12',
        'description': 'UPI/600012345678/Arun',
        'keepPreviousCounterpart': false,
        'categoryId': 'c1',
        // It keeps its text as the new expense's description.
        'expenseDescription': 'UPI/600012345678/Arun',
        'reimbursablePerson': 'Arun',
      });
    });

    test('an expense that stays one keeps its own description and stops being paid for', () {
      final Map<String, Object?> request = buildTreatmentRequest(
        entry: _entry(expenseId: 'x1', categoryId: 'c1'),
        account: _hdfc,
        state: const TreatmentState(kind: TreatmentKind.expense, categoryId: 'c2'),
        amount: 1500,
        date: day,
        description: 'Lunch',
      );
      expect(request.containsKey('expenseDescription'), isFalse);
      expect(request['reimbursablePerson'], isNull);
      expect(request.containsKey('reimbursablePerson'), isTrue,
          reason: 'null clears a claim; leaving it out would keep it');
    });

    test('money lent that becomes a paid-for purchase keeps its due date and note', () {
      final Map<String, Object?> request = buildTreatmentRequest(
        entry: _entry(),
        account: _hdfc,
        state: const TreatmentState(
          kind: TreatmentKind.expense,
          categoryId: 'c1',
          reimbursable: true,
          person: 'Arun',
        ),
        amount: 1500,
        date: day,
        description: 'x',
        claim: EntryClaim(
          summary: _claim(ledgerEntryId: 'e1', note: 'rent', dueDate: DateTime(2026, 10, 1)),
          isSource: true,
        ),
      );
      expect(request['dueDate'], '2026-10-01');
      expect(request['note'], 'rent');
    });

    test('a plain credit becomes income with a source', () {
      final Map<String, Object?> request = buildTreatmentRequest(
        entry: _entry(direction: LedgerDirection.credit),
        account: _hdfc,
        state: const TreatmentState(kind: TreatmentKind.income),
        amount: 1500,
        date: day,
        description: 'NEFT ACME',
        source: 'Salary',
      );
      expect(request['kind'], 'income');
      expect(request['direction'], 'credit');
      expect(request['source'], 'Salary');
      expect(request['incomeDescription'], 'NEFT ACME');
    });

    test('a refund sends no settlement', () {
      final Map<String, Object?> request = buildTreatmentRequest(
        entry: _entry(direction: LedgerDirection.credit, incomeId: 'i1'),
        account: _hdfc,
        state: const TreatmentState(kind: TreatmentKind.refund),
        amount: 1500,
        date: day,
        description: 'x',
      );
      expect(request['kind'], 'refund');
      expect(request['settles'], isNull);
    });

    test('a transfer to the cash account is an account transfer, linked to its row', () {
      final Map<String, Object?> request = buildTreatmentRequest(
        entry: _entry(),
        account: _hdfc,
        state: const TreatmentState(
          kind: TreatmentKind.transfer,
          target: TransferTarget.account('cash1'),
        ),
        amount: 1500,
        date: day,
        description: 'ATM WDL',
        matchEntryId: 'm9',
      );
      expect(request['transferTarget'], <String, Object?>{'type': 'account', 'accountId': 'cash1'});
      expect(request['matchEntryId'], 'm9');
      // The other leg is money in on cash.
      expect(request['counterpartDescription'], 'Transfer from HDFC Salary Account');
    });

    test('a transfer in from a new account adds the other leg when nothing matches', () {
      final Map<String, Object?> request = buildTreatmentRequest(
        entry: _entry(direction: LedgerDirection.credit),
        account: _hdfc,
        state: const TreatmentState(
          kind: TreatmentKind.transfer,
          target: TransferTarget.account('a2'),
        ),
        amount: 1500,
        date: day,
        description: 'IMPS',
      );
      expect(request['matchEntryId'], isNull);
      expect(request.containsKey('matchEntryId'), isTrue);
      expect(request['counterpartDescription'], 'Transfer to HDFC Salary Account');
    });

    test('a transfer that stays with the same account changes only its figures', () {
      final Map<String, Object?> request = buildTreatmentRequest(
        entry: _entry(group: 'g1', other: 'a2'),
        account: _hdfc,
        state: const TreatmentState(
          kind: TreatmentKind.transfer,
          target: TransferTarget.account('a2'),
        ),
        amount: 1200,
        date: day,
        description: 'x',
        keepCounterpart: true,
        matchEntryId: 'ignored',
      );
      expect(request['keepPreviousCounterpart'], isFalse);
      expect(request.containsKey('matchEntryId'), isFalse);
      expect(request.containsKey('counterpartDescription'), isFalse);
    });

    test('a transfer moved to a card bill can keep its old other leg', () {
      final Map<String, Object?> request = buildTreatmentRequest(
        entry: _entry(group: 'g1', other: 'a2'),
        account: _hdfc,
        state: const TreatmentState(
          kind: TreatmentKind.transfer,
          target: TransferTarget.card('k1'),
        ),
        amount: 1500,
        date: day,
        description: 'x',
        keepCounterpart: true,
      );
      expect(request['transferTarget'], <String, Object?>{'type': 'card', 'cardId': 'k1'});
      expect(request['keepPreviousCounterpart'], isTrue);
    });

    test('an account not tracked here', () {
      final Map<String, Object?> request = buildTreatmentRequest(
        entry: _entry(card: 'k1'),
        account: _hdfc,
        state: const TreatmentState(kind: TreatmentKind.transfer, target: TransferTarget.cash()),
        amount: 1500,
        date: day,
        description: 'x',
      );
      expect(request['transferTarget'], <String, Object?>{'type': 'cash'});
    });

    test('money lent', () {
      final Map<String, Object?> request = buildTreatmentRequest(
        entry: _entry(),
        account: _hdfc,
        state: TreatmentState(
          kind: TreatmentKind.loan,
          person: 'Arun',
          dueDate: DateTime(2026, 10, 1),
          note: 'rent',
        ),
        amount: 1500,
        date: day,
        description: 'x',
      );
      expect(request['person'], 'Arun');
      expect(request['dueDate'], '2026-10-01');
      expect(request['note'], 'rent');
      expect(request.containsKey('settles'), isFalse);
    });

    test('a loan repaid, and purchases paid back', () {
      Map<String, Object?> credit(TreatmentState state) => buildTreatmentRequest(
            entry: _entry(direction: LedgerDirection.credit),
            account: _hdfc,
            state: state,
            amount: 500,
            date: day,
            description: 'x',
          );
      expect(
        credit(const TreatmentState(
          kind: TreatmentKind.loan,
          settles: SettlementTarget.claim('r1', ReceivableKind.loan),
        ))['settles'],
        <String, Object?>{'receivableId': 'r1'},
      );
      expect(
        credit(const TreatmentState(
          kind: TreatmentKind.reimbursement,
          settles: SettlementTarget.claim('r2', ReceivableKind.reimbursable),
        ))['settles'],
        <String, Object?>{'receivableId': 'r2'},
      );
      expect(
        credit(const TreatmentState(
          kind: TreatmentKind.reimbursement,
          settles: SettlementTarget.expense('x7'),
          person: ' Meena ',
        ))['settles'],
        <String, Object?>{'expenseId': 'x7', 'person': 'Meena'},
      );
    });
  });

  group('what a saved movement opens as', () {
    test('plain movements: money out to cash or untracked, money in a refund', () {
      expect(initialTreatment(_entry(), null).kind, TreatmentKind.transfer);
      expect(initialTreatment(_entry(), null).target, const TransferTarget.cash());
      expect(initialTreatment(_entry(direction: LedgerDirection.credit), null).kind,
          TreatmentKind.refund);
    });

    test('documents, transfers and card bills', () {
      final TreatmentState expense = initialTreatment(_entry(expenseId: 'x1', categoryId: 'c1'), null);
      expect(expense.kind, TreatmentKind.expense);
      expect(expense.categoryId, 'c1');
      expect(initialTreatment(_entry(direction: LedgerDirection.credit, incomeId: 'i1'), null).kind,
          TreatmentKind.income);
      expect(initialTreatment(_entry(group: 'g1', other: 'cash1'), null).target,
          const TransferTarget.account('cash1'));
      expect(initialTreatment(_entry(card: 'k1'), null).target, const TransferTarget.card('k1'));
    });

    test('claims: money lent, a repayment, a purchase paid for someone', () {
      final List<ClaimSummary> claims = <ClaimSummary>[
        _claim(ledgerEntryId: 'e1'),
        _claim(id: 'r2', kind: ReceivableKind.reimbursable, person: 'Meena', expenseId: 'x1'),
      ];
      final LedgerEntry lent = _entry();
      LedgerEntry withId(LedgerEntry e, String id) => LedgerEntry(
            id: id,
            userId: e.userId,
            accountId: e.accountId,
            direction: e.direction,
            amount: e.amount,
            txnDate: e.txnDate,
            expenseId: e.expenseId,
            receivableId: e.receivableId,
            categoryId: e.categoryId,
          );
      final TreatmentState loan = initialTreatment(lent, claimOfEntry(lent, claims));
      expect(loan.kind, TreatmentKind.loan);
      expect(loan.person, 'Arun');

      final LedgerEntry repaid =
          withId(_entry(direction: LedgerDirection.credit, receivable: 'r1'), 'e2');
      final TreatmentState repayment = initialTreatment(repaid, claimOfEntry(repaid, claims));
      expect(repayment.kind, TreatmentKind.loan);
      expect(repayment.settles, const SettlementTarget.claim('r1', ReceivableKind.loan));

      final LedgerEntry purchase = withId(_entry(expenseId: 'x1', categoryId: 'c1'), 'e3');
      final TreatmentState paidFor = initialTreatment(purchase, claimOfEntry(purchase, claims));
      expect(paidFor.reimbursable, isTrue);
      expect(paidFor.person, 'Meena');
    });
  });

  test('what is still missing, in the web wording', () {
    String? message(TreatmentState state, {bool debit = true}) {
      final TreatmentProblem? p = treatmentProblem(state, debit: debit);
      return p == null ? null : treatmentProblemMessage(p, debit: debit);
    }

    expect(message(const TreatmentState(kind: TreatmentKind.expense)),
        'Choose a category for this expense.');
    expect(message(const TreatmentState(kind: TreatmentKind.expense, categoryId: 'c1', reimbursable: true)),
        'Add who you paid for.');
    expect(message(const TreatmentState(kind: TreatmentKind.transfer)), 'Choose where the money went.');
    expect(message(const TreatmentState(kind: TreatmentKind.transfer), debit: false),
        'Choose where the money came from.');
    expect(message(const TreatmentState(kind: TreatmentKind.loan, person: '  ')),
        'Add who you lent the money to.');
    expect(message(const TreatmentState(kind: TreatmentKind.loan), debit: false),
        'Choose the loan this repays.');
    expect(
        message(
            const TreatmentState(
              kind: TreatmentKind.loan,
              settles: SettlementTarget.claim('r2', ReceivableKind.reimbursable),
            ),
            debit: false),
        'Choose the loan this repays.');
    expect(message(const TreatmentState(kind: TreatmentKind.reimbursement), debit: false),
        'Choose the purchase this pays back.');
    expect(
        message(const TreatmentState(kind: TreatmentKind.reimbursement, settles: SettlementTarget.expense('x7')),
            debit: false),
        'Add who is paying you back.');
    expect(message(const TreatmentState(kind: TreatmentKind.refund), debit: false), isNull);
  });

  test('a loan offered for repayment leaves out what this movement already repaid', () {
    final List<SettleOption> options = claimOptions(
      claims: <ClaimSummary>[
        _claim(repayments: <ClaimRepayment>[_repayment('e1', 500), _repayment('e0', 200)]),
        // Settled, and not this movement's: not offered.
        _claim(id: 'r9', repayments: <ClaimRepayment>[_repayment('e8', 1500)]),
      ],
      kind: ReceivableKind.loan,
      current: null,
      excludeEntryId: 'e1',
      currency: 'INR',
    );
    expect(options, hasLength(1));
    expect(options.single.received, 200);
    expect(leftAfter(options.single, 1300), 0);
  });

  group('saving', () {
    late SupabaseClient client;
    late _Engine engine;
    late _Ledger ledger;
    late StatementProvider provider;

    setUp(() async {
      SchemaCapabilities.debugReset();
      SchemaCapabilities.debugOverride(transfers: true, creditCards: true, treatments: true, tags: true);
      client = SupabaseClient(
        'http://localhost:54321',
        'test-anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      engine = _Engine();
      ledger = _Ledger(client);
      provider = StatementProvider(ledger, engine: engine);
      await provider.open(userId: 'u1', account: _hdfc);
    });

    tearDown(SchemaCapabilities.debugReset);

    test('the engine builds the body and apply_bank_treatment gets exactly it', () async {
      final Map<String, Object?> request = <String, Object?>{'kind': 'refund', 'direction': 'credit'};
      final int readsBefore = ledger.statementReads;
      final String? tagError = await provider.applyTreatment(
        entry: _entry(direction: LedgerDirection.credit),
        request: request,
        tags: (kind: TagKind.expense, names: <String>['food']),
      );
      expect(tagError, isNull);
      expect(engine.argsOf('treatmentPayload').single['request'], request);
      expect(ledger.treatments.single, <String, Object?>{
        'entryId': 'e1',
        'type': 'from-engine',
        'request': request,
      });
      // The tags go on the row the movement belongs to now.
      final (TagKind kind, String id, List<String> names) = ledger.tagWrites.single;
      expect(kind, TagKind.expense);
      expect(id, 'x-new');
      expect(names, <String>['food']);
      expect(ledger.statementReads, readsBefore + 1, reason: 'the statement is reloaded');
    });

    test('tags that fail are reported; the treatment stays saved', () async {
      ledger.failTags = true;
      final String? tagError = await provider.applyTreatment(
        entry: _entry(),
        request: const <String, Object?>{'kind': 'expense'},
        tags: (kind: TagKind.expense, names: <String>['food']),
      );
      expect(tagError, isNotNull);
      expect(ledger.treatments, hasLength(1));
    });

    test('without migration 005 nothing is sent', () async {
      SchemaCapabilities.debugOverride(treatments: false);
      await expectLater(
        provider.applyTreatment(entry: _entry(), request: const <String, Object?>{}),
        throwsA(isA<Exception>()),
      );
      expect(ledger.treatments, isEmpty);
      expect(engine.argsOf('treatmentPayload'), isEmpty);
    });

    test("the other leg is found by the engine's rule, among the other account's rows", () async {
      ledger.claims = <ClaimSummary>[_claim(ledgerEntryId: 'm2')];
      ledger.otherAccountRows = <LedgerEntry>[
        LedgerEntry(id: 'm1', userId: 'u1', accountId: 'cash1', direction: LedgerDirection.credit, amount: 1500, txnDate: DateTime(2026, 9, 13)),
        LedgerEntry(id: 'm2', userId: 'u1', accountId: 'cash1', direction: LedgerDirection.credit, amount: 1500, txnDate: DateTime(2026, 9, 12)),
      ];
      engine.transferMatches = <Object?>[
        <String, Object?>{'id': 'm1'},
      ];
      final List<LedgerEntry> found = await provider.transferMatches(
        accountId: 'cash1',
        direction: LedgerDirection.debit,
        amount: 1500,
        date: day,
        claims: ledger.claims,
      );
      expect(found.map((LedgerEntry e) => e.id), <String>['m1']);
      final Map<String, Object?> args = engine.argsOf('transferMatches').single;
      expect(args['direction'], 'debit');
      expect(args['date'], '2026-09-12');
      final List<Object?> entries = args['entries']! as List<Object?>;
      // Money lent carries its claim, so it is never taken as the other leg.
      expect((entries[1]! as Map<String, Object?>)['claim'], isNotNull);
      expect((entries[0]! as Map<String, Object?>)['claim'], isNull);
    });

    test('an engine without transferMatches falls back to the import rule', () async {
      engine.knowsTransferMatches = false;
      ledger.otherAccountRows = <LedgerEntry>[
        LedgerEntry(id: 'm1', userId: 'u1', accountId: 'cash1', direction: LedgerDirection.credit, amount: 1500, txnDate: DateTime(2026, 9, 13)),
      ];
      final List<LedgerEntry> found = await provider.transferMatches(
        accountId: 'cash1',
        direction: LedgerDirection.debit,
        amount: 1500,
        date: day,
        claims: const <ClaimSummary>[],
      );
      expect(found.single.id, 'm1');
      final Map<String, Object?> op =
          (engine.argsOf('autoMatches').single['operations']! as List<Object?>).single! as Map<String, Object?>;
      expect(op['autoMatch'], isTrue);
      expect(op['request'], <String, Object?>{
        'transferTarget': <String, Object?>{'type': 'account', 'accountId': 'cash1'},
      });
    });
  });

  group('the sheet', () {
    late SupabaseClient client;
    late _Engine engine;
    late _Ledger ledger;
    late StatementProvider provider;
    late PreferencesService preferences;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      preferences = await PreferencesService.create();
      SchemaCapabilities.debugReset();
      SchemaCapabilities.debugOverride(transfers: true, creditCards: true, treatments: true, tags: true);
      client = SupabaseClient(
        'http://localhost:54321',
        'test-anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      engine = _Engine();
      ledger = _Ledger(client);
      provider = StatementProvider(ledger, engine: engine);
      await provider.open(userId: 'u1', account: _hdfc);
    });

    tearDown(SchemaCapabilities.debugReset);

    Future<void> pump(WidgetTester tester, LedgerEntry entry, {double width = 360}) async {
      tester.view.physicalSize = Size(width * 2, 720 * 2);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MultiProvider(
        providers: <ChangeNotifierProvider<dynamic>>[
          ChangeNotifierProvider<StatementProvider>.value(value: provider),
          ChangeNotifierProvider<CategoryProvider>(create: (_) => _Categories(client)),
          ChangeNotifierProvider<SettingsProvider>(
            create: (_) => SettingsProvider(
              repository: ProfileRepository(client),
              preferences: preferences,
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: EditMovementSheet(
              entry: entry,
              account: _hdfc,
              accounts: const <BankAccount>[_hdfc, _savings, _cash],
              cards: const <CreditCard>[_card],
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    for (final double width in <double>[320, 360]) {
      testWidgets('a plain debit opens as a transfer, with cash as an account, at $width dp',
          (WidgetTester tester) async {
        await pump(tester, _entry(), width: width);
        expect(tester.takeException(), isNull);
        expect(find.text('Edit transaction'), findsOneWidget);
        expect(find.text('Record as'), findsOneWidget);
        for (final String kind in <String>['Expense', 'Transfer', 'Loan']) {
          expect(find.text(kind), findsOneWidget);
        }
        expect(find.text('Your own money moving — not income or spending'), findsOneWidget);
        expect(find.textContaining('Transfer to'), findsOneWidget);
        expect(find.text('Cash'), findsOneWidget);
        expect(find.text('Indian Bank Savings •••• 4462'), findsOneWidget);
        // With a cash account kept, "not tracked" is only that.
        expect(find.text('An account not tracked here'), findsOneWidget);
        expect(find.text('Travel Platinum •••• 0042 — card bill'), findsOneWidget);
        expect(find.text('Only this balance changes. Not income or spending.'), findsOneWidget);
        expect(engine.argsOf('kindsFor').single['treatments'], isTrue);
      });
    }

    testWidgets('choosing the cash account looks for the other leg there', (WidgetTester tester) async {
      ledger.otherAccountRows = <LedgerEntry>[
        LedgerEntry(id: 'm1', userId: 'u1', accountId: 'cash1', direction: LedgerDirection.credit, amount: 1500, txnDate: DateTime(2026, 9, 12), description: 'Cash in hand'),
      ];
      engine.transferMatches = <Object?>[
        <String, Object?>{'id': 'm1'},
      ];
      await pump(tester, _entry());
      await tester.tap(find.text('Cash'));
      await tester.pumpAndSettle();
      expect(find.text('Already on Cash?'), findsOneWidget);
      expect(find.text('Link 12 Sep · Cash in hand'), findsOneWidget);
      expect(find.textContaining('No — add'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final Map<String, Object?> request =
          engine.argsOf('treatmentPayload').single['request']! as Map<String, Object?>;
      expect(request['transferTarget'], <String, Object?>{'type': 'account', 'accountId': 'cash1'});
      // The closest match is linked unless "No — add" is chosen.
      expect(request['matchEntryId'], 'm1');
      expect(ledger.treatments, hasLength(1));
    });

    testWidgets('saving an expense without a category says so and sends nothing',
        (WidgetTester tester) async {
      await pump(tester, _entry());
      await tester.tap(find.text('Expense'));
      await tester.pumpAndSettle();
      expect(find.text('Food & Dining'), findsOneWidget);
      expect(find.text('Paid for someone else'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a category for this expense.'), findsOneWidget);
      expect(find.text('Pick one'), findsOneWidget);
      expect(engine.argsOf('treatmentPayload'), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a repayment offers the open loans with what is left', (WidgetTester tester) async {
      ledger.claims = <ClaimSummary>[
        _claim(ledgerEntryId: 'e0', repayments: <ClaimRepayment>[_repayment('e5', 500)]),
      ];
      await pump(tester, _entry(direction: LedgerDirection.credit, amount: 1000));
      for (final String kind in <String>['Income', 'Refund', 'Transfer', 'Loan', 'Reimbursement']) {
        expect(find.text(kind), findsOneWidget);
      }
      await tester.tap(find.text('Loan'));
      await tester.pumpAndSettle();
      expect(find.text('Repays a loan — not income'), findsOneWidget);
      expect(find.textContaining('Repays'), findsWidgets);
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Arun ·').last);
      await tester.pumpAndSettle();
      expect(find.text('This settles it.'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final Map<String, Object?> request =
          engine.argsOf('treatmentPayload').single['request']! as Map<String, Object?>;
      expect(request['kind'], 'loan');
      expect(request['settles'], <String, Object?>{'receivableId': 'r1'});
    });

    testWidgets('a reimbursement offers purchases to pay back', (WidgetTester tester) async {
      await pump(tester, _entry(direction: LedgerDirection.credit, amount: 900));
      await tester.tap(find.text('Reimbursement'));
      await tester.pumpAndSettle();
      expect(find.text('Pays back a purchase — not income'), findsOneWidget);
      expect(find.textContaining('From'), findsWidgets);
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Corner Cafe'), findsOneWidget);
      await tester.tap(find.textContaining('Corner Cafe'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Add who is paying you back.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('money lent asks who to, when it is due back and a note', (WidgetTester tester) async {
      ledger.claims = <ClaimSummary>[_claim(id: 'r5', ledgerEntryId: 'e0', person: 'Meena')];
      await pump(tester, _entry());
      await tester.tap(find.text('Loan'));
      await tester.pumpAndSettle();
      expect(find.text('Owed back to you — not spending'), findsOneWidget);
      expect(find.textContaining('Lent to'), findsOneWidget);
      expect(find.text('Due back (optional)'), findsOneWidget);
      expect(find.text('Note (optional)'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Add who you lent the money to.'), findsOneWidget);
      // People already used are offered, so "Meena" stays one person.
      await tester.tap(find.widgetWithText(ChoiceChip, 'Meena'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final Map<String, Object?> request =
          engine.argsOf('treatmentPayload').single['request']! as Map<String, Object?>;
      expect(request['kind'], 'loan');
      expect(request['person'], 'Meena');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a transfer that stops being one offers to keep its other side',
        (WidgetTester tester) async {
      await pump(tester, _entry(group: 'g1', other: 'a2'));
      expect(find.textContaining('Keep the other side'), findsNothing);
      await tester.tap(find.text('Expense'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Keep the other side on Indian Bank Savings as plain money in.'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('money lent recorded as something else keeps what was paid back',
        (WidgetTester tester) async {
      ledger.claims = <ClaimSummary>[
        _claim(ledgerEntryId: 'e1', repayments: <ClaimRepayment>[_repayment('e7', 500)]),
      ];
      await pump(tester, _entry());
      expect(find.text('Arun'), findsWidgets, reason: 'it opens as the loan to Arun');
      await tester.tap(find.text('Transfer'));
      await tester.pumpAndSettle();
      expect(find.textContaining('already paid back stays as plain money in on its account'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an unreadable claims list is not mistaken for none', (WidgetTester tester) async {
      ledger.failClaims = true;
      await pump(tester, _entry());
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Record as'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
