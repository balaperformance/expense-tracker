// Money owed to the user (migration 005): the claim figures ported from the
// web app's domain/receivables.ts, and what saving an expense writes about
// who it was paid for. Pure helpers are asserted directly; the save path runs
// through ExpenseProvider with recording fakes, so nothing reaches a
// database. Every name and figure is invented.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/income.dart';
import 'package:expense_tracker/models/ledger_entry.dart';
import 'package:expense_tracker/models/receivable.dart';
import 'package:expense_tracker/providers/expense_provider.dart';
import 'package:expense_tracker/providers/income_provider.dart';
import 'package:expense_tracker/providers/receivable_provider.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/income_repository.dart';
import 'package:expense_tracker/repositories/receivable_repository.dart';
import 'package:expense_tracker/repositories/tag_repository.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';

Receivable claim(
  String id, {
  ReceivableKind kind = ReceivableKind.loan,
  String person = 'Arun',
  DateTime? due,
  String? note,
  String? expenseId,
}) =>
    Receivable(
      id: id,
      userId: 'u1',
      kind: kind,
      person: person,
      ledgerEntryId: kind == ReceivableKind.loan ? 'l-$id' : null,
      expenseId: expenseId,
      dueDate: due,
      note: note,
    );

ClaimSource source(double amount, DateTime date) =>
    ClaimSource(date: date, amount: amount, title: 'Money lent');

ClaimRepayment repaid(String claimId, double amount, DateTime date) =>
    ClaimRepayment(
      entryId: 'r-$claimId-${date.day}',
      receivableId: claimId,
      accountId: 'a1',
      amount: amount,
      date: date,
    );

final DateTime today = DateTime(2026, 9, 20);

/// Records every write; nothing reaches a database.
class FakeExpenses extends ExpenseRepository {
  FakeExpenses(super.client);

  final List<Expense> created = <Expense>[];
  final List<Expense> updated = <Expense>[];

  static Expense _saved(Expense e, String id) => Expense(
        id: id,
        userId: e.userId,
        amount: e.amount,
        expenseDate: e.expenseDate,
        categoryId: e.categoryId,
        bankAccountId: e.bankAccountId,
        description: e.description,
      );

  @override
  Future<Expense> create(Expense expense, {MovementDetails? details}) async {
    created.add(expense);
    return _saved(expense, 'e${created.length}');
  }

  @override
  Future<Expense> update(Expense expense) async {
    updated.add(expense);
    return _saved(expense, expense.id);
  }
}

class FakeIncome extends IncomeRepository {
  FakeIncome(super.client);

  @override
  Future<Income> create(Income income, {MovementDetails? details}) async =>
      Income(
        id: 'i1',
        userId: income.userId,
        amount: income.amount,
        incomeDate: income.incomeDate,
      );
}

class FakeReceivables extends ReceivableRepository {
  FakeReceivables(super.client, {this.claims = const <ClaimSummary>[]});

  final List<ClaimSummary> claims;
  final List<(String, PaidForDraft?)> writes = <(String, PaidForDraft?)>[];
  bool fail = false;

  @override
  Future<List<ClaimSummary>> fetchClaims(String userId) async => claims;

  @override
  Future<void> setExpensePaidFor({
    required String userId,
    required String expenseId,
    required PaidForDraft? paidFor,
  }) async {
    if (fail) throw StateError('claim failed');
    writes.add((expenseId, paidFor));
  }
}

class FakeTags extends TagRepository {
  FakeTags(super.client);

  final List<(TagKind, String, List<String>)> sets =
      <(TagKind, String, List<String>)>[];
  bool fail = false;

  @override
  Future<void> setTags({
    required TagKind kind,
    required String id,
    required List<String> names,
  }) async {
    if (fail) throw StateError('tags failed');
    sets.add((kind, id, names));
  }
}

void main() {
  group('claim figures', () {
    test('a row reads as the web reads it', () {
      final Receivable r = Receivable.fromMap(<String, dynamic>{
        'id': 'c1',
        'user_id': 'u1',
        'kind': 'reimbursable',
        'person': '   ',
        'expense_id': 'e1',
        'due_date': '2026-10-01',
        'note': 'Concert tickets',
      });
      expect(r.kind, ReceivableKind.reimbursable);
      expect(r.person, 'Someone');
      expect(r.dueDate, DateTime(2026, 10, 1));
      expect(r.title, 'Paid for Someone');
      expect(claim('c2').title, 'Loan to Arun');
      expect(
        Receivable.fromMap(<String, dynamic>{'id': 'c3', 'user_id': 'u1', 'kind': 'x', 'person': 'Bea'}).kind,
        ReceivableKind.loan,
      );
    });

    test('status is decided in whole cents', () {
      expect(claimStatus(100, 0), ClaimStatus.open);
      expect(claimStatus(100, 40), ClaimStatus.partial);
      expect(claimStatus(0.3, 0.1 + 0.2), ClaimStatus.settled);
      expect(claimStatus(100, 100.01), ClaimStatus.overpaid);
      expect(ClaimStatus.partial.isOpen, isTrue);
      expect(ClaimStatus.overpaid.isOpen, isFalse);
      expect(ClaimStatus.open.label, 'Not repaid yet');
    });

    test('summaries: open first then newest, repayments oldest first', () {
      final List<ClaimSummary> claims = summariseClaims(
        receivables: <Receivable>[
          claim('old', due: DateTime(2026, 9, 1)),
          claim('new'),
          claim('done'),
          claim('lost'),
        ],
        sources: <String, ClaimSource>{
          'old': source(1000, DateTime(2026, 8, 1)),
          'new': source(500, DateTime(2026, 9, 10)),
          'done': source(200, DateTime(2026, 9, 15)),
        },
        repayments: <ClaimRepayment>[
          repaid('old', 300, DateTime(2026, 9, 12)),
          repaid('old', 100, DateTime(2026, 8, 20)),
          repaid('done', 200, DateTime(2026, 9, 16)),
        ],
        today: today,
      );
      expect(claims.map((ClaimSummary c) => c.receivable.id).toList(),
          <String>['new', 'old', 'done', 'lost'],
          reason: 'open first, then newest; no source date sorts last');
      final ClaimSummary old = claims[1];
      expect(old.received, 400);
      expect(old.outstanding, 600);
      expect(old.status, ClaimStatus.partial);
      expect(old.overdue, isTrue);
      expect(old.repayments.map((ClaimRepayment r) => r.amount), <double>[100, 300]);
      expect(claims[2].status, ClaimStatus.settled);
      expect(claims[2].overdue, isFalse);
      final ClaimSummary lost = claims.last;
      expect(lost.source, isNull);
      expect(lost.principal, 0);
      expect(lost.status, ClaimStatus.settled, reason: 'a missing source counts nothing');
      expect(totalOutstanding(claims), 1100);
    });

    test('people: one per spelling, the capitalised one shown, most owed first', () {
      final List<ClaimSummary> claims = summariseClaims(
        receivables: <Receivable>[
          claim('a1', person: 'arun '),
          claim('a2', person: 'Arun'),
          claim('b1', person: 'Bea'),
          claim('c1', person: 'Chitra'),
        ],
        sources: <String, ClaimSource>{
          'a1': source(100, DateTime(2026, 9, 1)),
          'a2': source(150, DateTime(2026, 9, 2)),
          'b1': source(900, DateTime(2026, 9, 3)),
          'c1': source(50, DateTime(2026, 9, 18)),
        },
        repayments: <ClaimRepayment>[repaid('c1', 50, DateTime(2026, 9, 19))],
        today: today,
      );
      final List<PersonBalance> people = balancesByPerson(claims);
      expect(people.map((PersonBalance p) => p.person).toList(),
          <String>['Bea', 'Arun', 'Chitra']);
      expect(people[1].outstanding, 250);
      expect(people[1].open, 2);
      expect(people[1].claims, hasLength(2));
      expect(people[2].open, 0);
      expect(knownPeople(claims), <String>['Chitra', 'Bea', 'Arun'],
          reason: 'most recent first, as last written');
      expect(personKey('  ARUN   kumar '), 'arun kumar');
    });

    test('due dates read in whole days', () {
      ClaimSummary due(DateTime date, {double received = 0}) => summariseClaims(
            receivables: <Receivable>[claim('d', due: date)],
            sources: <String, ClaimSource>{'d': source(100, DateTime(2026, 9, 1))},
            repayments: <ClaimRepayment>[
              if (received > 0) repaid('d', received, DateTime(2026, 9, 2)),
            ],
            today: today,
          ).single;
      expect(dueText(due(DateTime(2026, 9, 19)), today), 'Overdue by 1 day');
      expect(dueText(due(DateTime(2026, 9, 10)), today), 'Overdue by 10 days');
      expect(dueText(due(DateTime(2026, 9, 20)), today), 'Due today');
      expect(dueText(due(DateTime(2026, 9, 21)), today), 'Due in 1 day');
      expect(dueText(due(DateTime(2026, 11, 1)), today), 'Due in 42 days');
      expect(dueText(due(DateTime(2026, 9, 1), received: 100), today), isNull,
          reason: 'nothing is owed');
    });
  });

  group('paid for someone else', () {
    final Receivable marked = claim('c1',
        kind: ReceivableKind.reimbursable,
        expenseId: 'e9',
        due: DateTime(2026, 10, 5),
        note: 'Split later');

    test('the form marks, unmarks or leaves alone, as the web form does', () {
      final PaidForChange mark =
          paidForChange(known: true, paidFor: true, person: '  Arun ');
      expect(mark.keeps, isFalse);
      expect(mark.draft!.person, 'Arun');
      expect(mark.draft!.dueDate, isNull);

      final PaidForChange again = paidForChange(
          known: true, paidFor: true, person: 'Arun K', claim: marked);
      expect(again.draft!.person, 'Arun K');
      expect(again.draft!.dueDate, DateTime(2026, 10, 5),
          reason: 'the form does not edit the due date, so it is kept');
      expect(again.draft!.note, 'Split later');

      expect(
          paidForChange(known: true, paidFor: false, person: '', claim: marked)
              .clears,
          isTrue);
      expect(
          paidForChange(known: true, paidFor: false, person: 'Arun').keeps,
          isTrue,
          reason: 'never was, still is not');
      expect(
          paidForChange(known: false, paidFor: false, person: '', claim: marked)
              .keeps,
          isTrue,
          reason: 'an unread claim is never unmarked');
    });

    test('the row written is the web app\'s', () {
      final Map<String, dynamic> row = ReceivableRepository.paidForRow(
        userId: 'u1',
        expenseId: 'e9',
        draft: PaidForDraft(
            person: ' Arun ', dueDate: DateTime(2026, 10, 5), note: '  '),
        now: DateTime.utc(2026, 9, 20, 10),
      );
      expect(row, <String, dynamic>{
        'user_id': 'u1',
        'kind': 'reimbursable',
        'person': 'Arun',
        'expense_id': 'e9',
        'due_date': '2026-10-05',
        'note': null,
        'updated_at': '2026-09-20T10:00:00.000Z',
      });
    });
  });

  group('saving an expense', () {
    late SupabaseClient client;
    late FakeExpenses expenses;
    late FakeReceivables receivables;
    late FakeTags tags;
    late ExpenseProvider provider;

    setUp(() {
      SchemaCapabilities.debugOverride(treatments: true, tags: true);
      client = SupabaseClient(
        'http://localhost:54321',
        'test-anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      expenses = FakeExpenses(client);
      receivables = FakeReceivables(client);
      tags = FakeTags(client);
      provider = ExpenseProvider(expenses, tags: tags, receivables: receivables);
    });
    tearDown(SchemaCapabilities.debugReset);

    Expense draft({String id = ''}) => Expense(
          id: id,
          userId: 'u1',
          amount: 400,
          expenseDate: DateTime(2026, 9, 20),
          categoryId: 'food',
        );

    test('a new purchase is marked with the id it was saved under', () async {
      final bool ok = await provider.save(
        draft(),
        paidFor: const PaidForChange.mark(PaidForDraft(person: 'Arun')),
        tags: <String>['family'],
      );
      expect(ok, isTrue);
      expect(expenses.created, hasLength(1));
      expect(receivables.writes.single.$1, 'e1');
      expect(receivables.writes.single.$2!.person, 'Arun');
      expect(tags.sets.single.$1, TagKind.expense);
      expect(tags.sets.single.$2, 'e1');
      expect(tags.sets.single.$3, <String>['family']);
      expect(provider.saveWarning, isNull);
      expect(provider.revision, 1);
    });

    test('an edit updates, unmarks, and leaves unread tags alone', () async {
      await provider.save(draft(id: 'e9'), paidFor: const PaidForChange.clear());
      expect(expenses.updated.single.id, 'e9');
      expect(receivables.writes.single, ('e9', null));
      expect(tags.sets, isEmpty);
    });

    test('left alone writes no claim', () async {
      await provider.save(draft(id: 'e9'));
      expect(receivables.writes, isEmpty);
    });

    test('a failed claim or tag write keeps the expense and says so', () async {
      receivables.fail = true;
      tags.fail = true;
      final bool ok = await provider.save(
        draft(),
        paidFor: const PaidForChange.mark(PaidForDraft(person: 'Arun')),
        tags: <String>['family'],
      );
      expect(ok, isTrue, reason: 'saving again would add a second expense');
      expect(expenses.created, hasLength(1));
      expect(provider.saveWarning,
          'The expense was saved, but it could not be marked as paid for '
          'someone else, and its tags were not. Open it to try again.');
    });

    test('nothing about claims or tags is written before their migrations',
        () async {
      SchemaCapabilities.debugReset();
      SchemaCapabilities.debugOverride(treatments: false, tags: false);
      expect(provider.paidForAvailable, isFalse);
      expect(provider.tagsAvailable, isFalse);
      await provider.save(
        draft(),
        paidFor: const PaidForChange.mark(PaidForDraft(person: 'Arun')),
        tags: <String>['family'],
      );
      expect(receivables.writes, isEmpty);
      expect(tags.sets, isEmpty);
    });

    test('income saves its tags under its own kind', () async {
      final IncomeProvider income = IncomeProvider(FakeIncome(client), tags: tags);
      final bool ok = await income.save(
        Income(id: '', userId: 'u1', amount: 50000, incomeDate: DateTime(2026, 9, 1)),
        tags: <String>['salary'],
      );
      expect(ok, isTrue);
      expect(tags.sets.single.$1, TagKind.income);
      expect(tags.sets.single.$2, 'i1');
      expect(tags.sets.single.$3, <String>['salary']);
    });
  });

  test('the provider answers for one expense and follows the user', () async {
    SchemaCapabilities.debugOverride(treatments: true);
    addTearDown(SchemaCapabilities.debugReset);
    final SupabaseClient client = SupabaseClient(
      'http://localhost:54321',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    final ReceivableProvider owed = ReceivableProvider(FakeReceivables(
      client,
      claims: summariseClaims(
        receivables: <Receivable>[
          claim('c1', kind: ReceivableKind.reimbursable, expenseId: 'e9'),
          claim('c2', person: 'Bea'),
        ],
        sources: <String, ClaimSource>{
          'c1': source(400, DateTime(2026, 9, 10)),
          'c2': source(1000, DateTime(2026, 9, 12)),
        },
        repayments: const <ClaimRepayment>[],
        today: today,
      ),
    ));
    await owed.load(userId: 'u1');
    expect(owed.claimForExpense('e9')?.receivable.person, 'Arun');
    expect(owed.claimForExpense('e1'), isNull);
    expect(owed.outstanding, 1400);
    expect(owed.openCount, 2);
    expect(owed.people, <String>['Bea', 'Arun']);

    owed.attachUser('u2');
    expect(owed.claims, isEmpty, reason: 'never shown to another user');
  });
}
