import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/balance_adjustment.dart';
import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/models/card_statement.dart';
import 'package:expense_tracker/models/ledger_entry.dart';
import 'package:expense_tracker/models/receivable.dart';
import 'package:expense_tracker/providers/balance_adjustment_provider.dart';
import 'package:expense_tracker/providers/bank_account_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/providers/statement_provider.dart';
import 'package:expense_tracker/repositories/balance_adjustment_repository.dart';
import 'package:expense_tracker/repositories/bank_account_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/repositories/profile_repository.dart';
import 'package:expense_tracker/screens/accounts/balance_adjustment_sheets.dart';
import 'package:expense_tracker/services/preferences_service.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';
import 'package:expense_tracker/services/statement_import/statement_engine.dart';

const BankAccount _hdfc = BankAccount(
  id: 'a1',
  userId: 'u1',
  bankName: 'HDFC',
  nickname: 'Salary Account',
  last4: '6459',
);

SupabaseClient _client() => SupabaseClient(
      'http://localhost:54321',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );

String _rupees(double v) => '₹${v.toStringAsFixed(2)}';

LedgerEntry _adjustmentRow({String id = 'adj-row', String? description}) => LedgerEntry.fromMap(<String, dynamic>{
      'id': id,
      'user_id': 'u1',
      'account_id': 'cash1',
      'direction': 'credit',
      'amount': 1500,
      'txn_date': '2026-09-13',
      'description': description ?? 'Balance adjustment',
      'balance_adjustment_id': 'adj-1',
    });

/// Records what the provider asks the database for.
class _Repository extends BalanceAdjustmentRepository {
  _Repository(super.client);

  final List<Map<String, Object?>> adjusted = <Map<String, Object?>>[];
  final List<String> removed = <String>[];
  List<BalanceAdjustment> rows = <BalanceAdjustment>[];
  bool fail = false;

  @override
  Future<List<BalanceAdjustment>> fetchForAccount({required String userId, required String accountId}) async =>
      rows.where((BalanceAdjustment a) => a.accountId == accountId).toList();

  @override
  Future<String> adjust({
    required String accountId,
    required double balance,
    required DateTime date,
    String? remarks,
  }) async {
    if (fail) throw StateError('The date cannot be in the future.');
    adjusted.add(<String, Object?>{'account': accountId, 'balance': balance, 'date': date, 'remarks': remarks});
    return 'new';
  }

  @override
  Future<void> remove({required String userId, required String id}) async => removed.add(id);
}

class _Engine implements StatementEngine {
  final List<(String, Map<String, Object?>)> calls = <(String, Map<String, Object?>)>[];

  @override
  Future<Object?> call(String name, Map<String, Object?> args) async {
    calls.add((name, args));
    if (name == 'transferMatches') {
      return (args['entries']! as List<Object?>)
          .map((Object? e) => <String, Object?>{'id': (e! as Map<String, Object?>)['id']})
          .toList();
    }
    throw StateError('unexpected call $name');
  }

  @override
  Future<PickedStatementFile?> pickFile() async => null;

  @override
  Future<void> release(String token) async {}
}

class _Ledger extends LedgerRepository {
  _Ledger(super.client);

  List<LedgerEntry> rows = <LedgerEntry>[];

  @override
  Future<List<LedgerEntry>> fetchForAccount({
    required String userId,
    required String accountId,
    DateTime? from,
    DateTime? toExclusive,
  }) async =>
      rows.where((LedgerEntry e) => e.accountId == accountId).toList();

  @override
  Future<double> netBefore({required String userId, required String accountId, required DateTime before}) async => 0;
}

void main() {
  tearDown(SchemaCapabilities.debugReset);

  group('the adjustment record', () {
    test('reads the row, with amounts as numbers or strings', () {
      final BalanceAdjustment a = BalanceAdjustment.fromMap(<String, dynamic>{
        'id': 'adj-1',
        'account_id': 'a1',
        'adjusted_on': '2026-11-21',
        'adjusted_at': '2026-11-21T09:30:00Z',
        'target_balance': '2000.00',
        'previous_balance': 7320.67,
        'remarks': '  Matched with the bank app ',
      });
      expect(a.adjustedOn, DateTime(2026, 11, 21));
      expect(a.targetBalance, 2000);
      expect(a.previousBalance, 7320.67);
      expect(a.difference, -5320.67);
      expect(a.remarks, 'Matched with the bank app');
    });

    test('blank remarks are none', () {
      final BalanceAdjustment a = BalanceAdjustment.fromMap(<String, dynamic>{
        'id': 'adj-1',
        'account_id': 'a1',
        'adjusted_on': '2026-11-21',
        'target_balance': 10,
        'previous_balance': 10,
        'remarks': '   ',
      });
      expect(a.remarks, isNull);
      expect(a.difference, 0);
    });

    test('the live line says what the adjustment does', () {
      expect(adjustmentEffectText(500, _rupees), 'Adds ₹500.00 as a balance adjustment');
      expect(adjustmentEffectText(-120.5, _rupees), 'Removes ₹120.50 as a balance adjustment');
      expect(adjustmentEffectText(0.001, _rupees), 'Already matches — recorded with no change');
    });

    test('a history row reads date, the balance before, the change and remarks', () {
      final BalanceAdjustment a = BalanceAdjustment(
        id: 'adj-1',
        accountId: 'a1',
        adjustedOn: DateTime(2026, 11, 21),
        targetBalance: 2000,
        previousBalance: 7320.67,
        remarks: 'Matched',
      );
      expect(
        adjustmentHistorySubtitle(a, format: _rupees, date: (DateTime d) => '21 Nov 2026'),
        '21 Nov 2026 · was ₹7320.67 · −₹5320.67 · Matched',
      );
      expect(signedDifference(250, _rupees), '+₹250.00');
      expect(signedDifference(0, _rupees), '₹0.00');
    });

    test('newest first by date, then by when it was made', () {
      BalanceAdjustment at(String id, DateTime on, DateTime made) => BalanceAdjustment(
            id: id,
            accountId: 'a1',
            adjustedOn: on,
            adjustedAt: made,
            targetBalance: 0,
            previousBalance: 0,
          );
      final List<BalanceAdjustment> sorted = newestFirst(<BalanceAdjustment>[
        at('old', DateTime(2026, 10, 1), DateTime(2026, 10, 1, 9)),
        at('late', DateTime(2026, 11, 1), DateTime(2026, 11, 1, 18)),
        at('early', DateTime(2026, 11, 1), DateTime(2026, 11, 1, 8)),
      ]);
      expect(sorted.map((BalanceAdjustment a) => a.id), <String>['late', 'early', 'old']);
    });
  });

  group('its ledger row', () {
    test('is labelled as an adjustment, with the remarks beside it', () {
      final LedgerEntry row = _adjustmentRow(description: 'Balance adjustment · Matched with the bank app');
      expect(row.isBalanceAdjustment, isTrue);
      expect(row.title, 'Balance adjustment');
      expect(row.adjustmentRemarks, 'Matched with the bank app');
      expect(row.categoryLabel, 'Matched with the bank app');
      expect(_adjustmentRow().adjustmentRemarks, isNull);
    });

    test('still counts in the balance, but is never a bank line to match', () {
      final LedgerEntry plain = LedgerEntry(
        id: 'm1',
        userId: 'u1',
        accountId: 'cash1',
        direction: LedgerDirection.debit,
        amount: 1500,
        txnDate: DateTime(2026, 9, 13),
      );
      final LedgerEntry adjustment = _adjustmentRow();
      final AccountStatement statement =
          buildStatement(openingBalance: 100, entries: <LedgerEntry>[plain, adjustment]);
      expect(statement.closingBalance, 100);
      expect(<LedgerEntry>[plain, adjustment].withoutAdjustments(), <LedgerEntry>[plain]);
      final LedgerEntry adjustmentDebit = LedgerEntry.fromMap(<String, dynamic>{
        'id': 'adj-row-2',
        'user_id': 'u1',
        'account_id': 'cash1',
        'direction': 'debit',
        'amount': 200,
        'txn_date': '2026-09-13',
        'balance_adjustment_id': 'adj-2',
      });
      expect(isLinkableDebit(adjustmentDebit), isFalse, reason: 'never offered as a card bill payment');
      expect(isLinkableDebit(plain), isTrue);
      expect(EngineJson.ledgerEntry(adjustment)['balanceAdjustmentId'], 'adj-1');
      expect(EngineJson.ledgerEntry(plain).containsKey('balanceAdjustmentId'), isFalse);
      // The duplicate check's entries carry it too, so the engine skips them.
      expect(EngineJson.existing(adjustment)['balanceAdjustmentId'], 'adj-1');
    });

    test('is never offered as the other leg of a transfer', () async {
      SchemaCapabilities.debugOverride(transfers: true, creditCards: true, treatments: true);
      final _Engine engine = _Engine();
      final _Ledger ledger = _Ledger(_client())
        ..rows = <LedgerEntry>[
          LedgerEntry(
            id: 'm1',
            userId: 'u1',
            accountId: 'cash1',
            direction: LedgerDirection.credit,
            amount: 1500,
            txnDate: DateTime(2026, 9, 13),
          ),
          _adjustmentRow(),
        ];
      final StatementProvider provider = StatementProvider(ledger, engine: engine);
      await provider.open(userId: 'u1', account: _hdfc);
      final List<LedgerEntry> found = await provider.transferMatches(
        accountId: 'cash1',
        direction: LedgerDirection.debit,
        amount: 1500,
        date: DateTime(2026, 9, 12),
        claims: const <ClaimSummary>[],
      );
      expect(found.map((LedgerEntry e) => e.id), <String>['m1']);
      final List<Object?> sent = engine.calls
          .where(((String, Map<String, Object?>) c) => c.$1 == 'transferMatches')
          .single
          .$2['entries']! as List<Object?>;
      expect(sent, hasLength(1));
    });
  });

  group('the provider', () {
    test('is empty and asks nothing before migration 021', () async {
      SchemaCapabilities.debugOverride(balanceAdjustments: false);
      final _Repository repository = _Repository(_client())
        ..rows = <BalanceAdjustment>[
          BalanceAdjustment(id: 'x', accountId: 'a1', adjustedOn: DateTime(2026), targetBalance: 1, previousBalance: 0),
        ];
      final BalanceAdjustmentProvider provider = BalanceAdjustmentProvider(repository);
      await provider.load(userId: 'u1', accountId: 'a1');
      expect(provider.forAccount('a1'), isEmpty);
      expect(
        await BalanceAdjustmentRepository(_client()).fetchForAccount(userId: 'u1', accountId: 'a1'),
        isEmpty,
      );
    });

    test('adjusts through the database, then re-reads the history', () async {
      SchemaCapabilities.debugOverride(bankAccounts: true, balanceAdjustments: true);
      final _Repository repository = _Repository(_client());
      final BalanceAdjustmentProvider provider = BalanceAdjustmentProvider(repository);
      await provider.load(userId: 'u1', accountId: 'a1');
      final BalanceAdjustment made = BalanceAdjustment(
        id: 'adj-1',
        accountId: 'a1',
        adjustedOn: DateTime(2026, 11, 21),
        targetBalance: 2000,
        previousBalance: 7320.67,
      );
      repository.rows = <BalanceAdjustment>[made];
      expect(
        await provider.adjust(accountId: 'a1', balance: 2000, date: DateTime(2026, 11, 21), remarks: 'bank app'),
        isTrue,
      );
      expect(repository.adjusted.single['balance'], 2000);
      expect(repository.adjusted.single['remarks'], 'bank app');
      expect(provider.latestFor('a1')?.id, 'adj-1');
      expect(provider.byId('adj-1'), same(provider.forAccount('a1').single));

      expect(await provider.remove(made), isTrue);
      expect(repository.removed, <String>['adj-1']);
    });

    test("a refusal is the database's message, and nothing is kept", () async {
      SchemaCapabilities.debugOverride(bankAccounts: true, balanceAdjustments: true);
      final _Repository repository = _Repository(_client())..fail = true;
      final BalanceAdjustmentProvider provider = BalanceAdjustmentProvider(repository);
      await provider.load(userId: 'u1', accountId: 'a1');
      expect(await provider.adjust(accountId: 'a1', balance: 5, date: DateTime(2026, 11, 21)), isFalse);
      expect(provider.errorMessage, isNotNull);
      expect(provider.forAccount('a1'), isEmpty);
    });
  });

  group('the Adjust balance sheet', () {
    late PreferencesService preferences;
    late _Repository repository;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      preferences = await PreferencesService.create();
      SchemaCapabilities.debugOverride(bankAccounts: true, balanceAdjustments: true);
      repository = _Repository(_client());
    });

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360 * 2, 720 * 2);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final SupabaseClient client = _client();
      await tester.pumpWidget(MultiProvider(
        providers: <ChangeNotifierProvider<dynamic>>[
          ChangeNotifierProvider<SettingsProvider>(
            create: (_) => SettingsProvider(repository: ProfileRepository(client), preferences: preferences),
          ),
          ChangeNotifierProvider<BalanceAdjustmentProvider>(create: (_) => BalanceAdjustmentProvider(repository)),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(body: AdjustBalanceSheet(account: _hdfc, currentBalance: 7320.67)),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the app balance, and what the typed balance changes', (WidgetTester tester) async {
      await pump(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Adjust balance'), findsOneWidget);
      expect(find.text('Balance in the app'), findsOneWidget);
      // Required: the label carries " *".
      expect(find.text('Actual balance *', findRichText: true), findsOneWidget);
      expect(find.text('The day the bank showed this balance'), findsOneWidget);
      expect(
        find.text('Transactions after this date count from the new balance. No transaction is changed or deleted.'),
        findsOneWidget,
      );

      await tester.enterText(find.byKey(const ValueKey<String>('adjust-balance-amount')), '2000');
      await tester.pump();
      expect(find.textContaining('Removes'), findsOneWidget);
      expect(find.textContaining('as a balance adjustment'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey<String>('adjust-balance-amount')), '7320.67');
      await tester.pump();
      expect(find.text('Already matches — recorded with no change'), findsOneWidget);

      // An overdrawn account: a leading minus is allowed.
      await tester.enterText(find.byKey(const ValueKey<String>('adjust-balance-amount')), '-50');
      await tester.pump();
      expect(find.textContaining('Removes'), findsOneWidget);

      // For an earlier day the database works out that day's balance: no
      // line based on today's.
      await tester.tap(find.text('Yest'));
      await tester.pump();
      expect(find.textContaining('as a balance adjustment'), findsNothing);
    });

    testWidgets('asks for the balance before saving anything', (WidgetTester tester) async {
      await pump(tester);
      await tester.tap(find.text('Save adjustment'));
      await tester.pump();
      expect(find.text('Enter the balance shown by your bank.'), findsOneWidget);
      expect(repository.adjusted, isEmpty);
    });
  });

  testWidgets("the account's card offers the action and lists the history", (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final PreferencesService preferences = await PreferencesService.create();
    SchemaCapabilities.debugOverride(bankAccounts: true, balanceAdjustments: true);
    final SupabaseClient client = _client();
    final _Repository repository = _Repository(client)
      ..rows = <BalanceAdjustment>[
        BalanceAdjustment(
          id: 'adj-1',
          accountId: 'a1',
          adjustedOn: DateTime(2026, 11, 21),
          targetBalance: 2000,
          previousBalance: 7320.67,
          remarks: 'Matched with the bank app',
        ),
      ];
    final BalanceAdjustmentProvider adjustments = BalanceAdjustmentProvider(repository);
    await adjustments.load(userId: 'u1', accountId: 'a1');
    tester.view.physicalSize = const Size(360 * 2, 720 * 2);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiProvider(
      providers: <ChangeNotifierProvider<dynamic>>[
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(repository: ProfileRepository(client), preferences: preferences),
        ),
        ChangeNotifierProvider<BankAccountProvider>(
          create: (_) => BankAccountProvider(accounts: BankAccountRepository(client), ledger: LedgerRepository(client)),
        ),
        ChangeNotifierProvider<BalanceAdjustmentProvider>.value(value: adjustments),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(body: AccountBalanceAdjustments(account: _hdfc)),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Balance does not match the bank?'), findsOneWidget);
    expect(find.text('Adjust balance'), findsOneWidget);
    expect(find.text('Balance adjustments'), findsOneWidget);
    expect(find.text('1 adjustment'), findsOneWidget);
    expect(find.textContaining('Set to'), findsOneWidget);
    expect(find.textContaining('Matched with the bank app'), findsOneWidget);
  });

  test('a typed balance is read with its sign, and nonsense is not', () {
    expect(parseSignedAmount('-1,250.50'), -1250.5);
    expect(parseSignedAmount('2000'), 2000);
    expect(parseSignedAmount('-'), isNull);
    expect(parseSignedAmount(''), isNull);
    expect(parseSignedAmount('1000000000000'), isNull);
  });
}
