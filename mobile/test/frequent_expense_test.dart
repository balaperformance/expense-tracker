/// Quick add, held to the same fixture as the web app's
/// `ui/src/domain/frequentExpenses.test.ts`: the app and the web must always
/// suggest the same habits, filled in the same way.
library;

import 'dart:convert';
import 'dart:io';

import 'package:expense_tracker/core/utils/date_utils.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/frequent_expense.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lives with the web app, next to `frequentExpenses.ts`; `flutter test`
/// runs from this package's root.
final File fixtureFile = File('../ui/src/domain/frequentExpenses.fixture.json');

List<Map<String, dynamic>> loadCases() {
  if (!fixtureFile.existsSync()) {
    throw StateError(
      'The shared quick-add fixture is missing: ${fixtureFile.path}',
    );
  }
  final Map<String, dynamic> fixture =
      jsonDecode(fixtureFile.readAsStringSync()) as Map<String, dynamic>;
  return (fixture['cases'] as List<dynamic>).cast<Map<String, dynamic>>();
}

Expense expenseFrom(Map<String, dynamic> row) => Expense(
      id: row['id'] as String,
      userId: 'u1',
      amount: (row['amount'] as num).toDouble(),
      expenseDate: AppDateUtils.parseDate(row['expenseDate'] as String),
      categoryId: row['categoryId'] as String?,
      paymentMethodId: row['paymentMethodId'] as String?,
      bankAccountId: row['bankAccountId'] as String?,
      creditCardId: row['creditCardId'] as String?,
      merchant: row['merchant'] as String?,
      description: row['description'] as String?,
      createdAt: row['createdAt'] == null
          ? null
          : DateTime.parse(row['createdAt'] as String),
    );

Set<String> ids(Object? list) => (list as List<dynamic>).cast<String>().toSet();

FrequentExpenseContext contextFrom(Map<String, dynamic> c) {
  final Map<String, dynamic> sets = c['context'] as Map<String, dynamic>;
  return FrequentExpenseContext(
    today: AppDateUtils.parseDate(c['today'] as String),
    excludeIds: ids(sets['excludeIds']),
    categoryIds: ids(sets['categoryIds']),
    paymentMethodIds: ids(sets['paymentMethodIds']),
    accountIds: ids(sets['accountIds']),
    cardIds: ids(sets['cardIds']),
  );
}

List<Expense> expensesFrom(Map<String, dynamic> c) =>
    (c['expenses'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(expenseFrom)
        .toList();

/// The web app's JSON shape, so the fixture's expectations compare as data.
Map<String, Object?> asJson(FrequentExpense s) {
  final FrequentSource? source = s.source;
  return <String, Object?>{
    'key': s.key,
    'title': s.title,
    'categoryId': s.categoryId,
    'amount': s.amount,
    'description': s.description,
    'merchant': s.merchant,
    'paymentMethodId': s.paymentMethodId,
    'source': source == null
        ? null
        : <String, Object?>{
            'kind': source.kind.name,
            if (source.id != null) 'id': source.id,
          },
    'count': s.count,
    'lastDate': AppDateUtils.toDateString(s.lastDate),
  };
}

void main() {
  final List<Map<String, dynamic>> cases = loadCases();

  group('frequentExpenses (shared fixture with the web app)', () {
    for (final Map<String, dynamic> c in cases) {
      test(c['name'] as String, () {
        final List<FrequentExpense> found = frequentExpenses(
          expensesFrom(c),
          contextFrom(c),
          limit: c['limit'] as int,
        );
        expect(found.map(asJson).toList(), c['expected']);
      });
    }

    final Map<String, dynamic> first = cases.first;
    final List<dynamic> expected = first['expected'] as List<dynamic>;

    test('offers the six most frequent by default', () {
      final List<FrequentExpense> found =
          frequentExpenses(expensesFrom(first), contextFrom(first));
      expect(found.map(asJson).toList(), expected.take(frequentLimit).toList());
    });

    test('does not depend on the order the purchases arrive in', () {
      final List<FrequentExpense> found = frequentExpenses(
        expensesFrom(first).reversed,
        contextFrom(first),
        limit: first['limit'] as int,
      );
      expect(found.map(asJson).toList(), expected);
    });

    test('counts purchases paid for someone else once they are no longer marked',
        () {
      final FrequentExpenseContext marked = contextFrom(first);
      final FrequentExpenseContext unmarked = FrequentExpenseContext(
        today: marked.today,
        excludeIds: const <String>{},
        categoryIds: marked.categoryIds,
        paymentMethodIds: marked.paymentMethodIds,
        accountIds: marked.accountIds,
        cardIds: marked.cardIds,
      );
      final FrequentExpense lunch = frequentExpenses(
        expensesFrom(first),
        unmarked,
        limit: first['limit'] as int,
      ).singleWhere((FrequentExpense s) => s.key == 'catFood|team lunch');
      expect(lunch.count, 3);
      expect(lunch.amount, 400);
      expect(lunch.source?.kind, FrequentSourceKind.account);
      expect(lunch.source?.id, 'accMain');
    });
  });
}
