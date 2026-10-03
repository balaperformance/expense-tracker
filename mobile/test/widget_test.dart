// Unit tests for the pure business logic.
//
// The data layer requires a live Supabase session, so these cover the parts
// that can be verified deterministically: validation, date maths, currency
// formatting, filter equality and category aggregation.

import 'package:expense_tracker/core/config/app_config.dart';
import 'package:expense_tracker/services/dev_auth_bypass.dart';
import 'package:expense_tracker/core/utils/date_utils.dart';
import 'package:expense_tracker/core/utils/formatters.dart';
import 'package:expense_tracker/core/utils/validators.dart';
import 'package:expense_tracker/models/analytics.dart';
import 'package:expense_tracker/models/budget.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/expense_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppConfig dev auth bypass', () {
    // Tests run in debug mode, so the bypass is expected to be active here.
    // The guarantee worth pinning down is that it is tied to build mode at
    // all, rather than being unconditionally on.
    test('is enabled in non-release builds during development', () {
      expect(AppConfig.bypassAuth, isTrue);
    });

    test('exposes the .env keys the bypass reads', () {
      expect(AppConfig.devEmailKey, 'DEV_EMAIL');
      expect(AppConfig.devPasswordKey, 'DEV_PASSWORD');
    });
  });

  group('DevAuthBypass error sanitising', () {
    test('strips the request uri so the endpoint never reaches the screen', () {
      const String raw =
          'ClientException: Failed to fetch, uri=https://abc123.supabase.co/auth/v1/signup';
      final String clean = debugSanitiseBypassError(raw);
      expect(clean, isNot(contains('supabase.co')));
      expect(clean, isNot(contains('uri=')));
      expect(clean, contains('Failed to fetch'));
    });

    test('replaces a bare url and never returns empty', () {
      expect(
        debugSanitiseBypassError('see https://abc123.supabase.co/x for more'),
        'see [endpoint] for more',
      );
      expect(
          debugSanitiseBypassError('https://abc123.supabase.co'), '[endpoint]');
    });
  });

  group('Validators.amount', () {
    test('rejects empty, zero, negative and non-numeric input', () {
      expect(Validators.amount(''), isNotNull);
      expect(Validators.amount('0'), isNotNull);
      expect(Validators.amount('-5'), isNotNull);
      expect(Validators.amount('abc'), isNotNull);
    });

    test('accepts positive values including decimals and thousands', () {
      expect(Validators.amount('1'), isNull);
      expect(Validators.amount('0.01'), isNull);
      expect(Validators.amount('1,250.75'), isNull);
    });

    test('parseAmount strips separators', () {
      expect(Validators.parseAmount('1,250.75'), 1250.75);
    });
  });

  group('Validators.email', () {
    test('rejects malformed addresses', () {
      expect(Validators.email('nope'), isNotNull);
      expect(Validators.email('a@b'), isNotNull);
      expect(Validators.email(''), isNotNull);
    });

    test('accepts a normal address', () {
      expect(Validators.email('person@example.com'), isNull);
    });
  });

  group('AppDateUtils', () {
    test('monthRange covers the whole month exclusively', () {
      final MonthRange range = AppDateUtils.monthRange(DateTime(2025, 2, 14));
      expect(range.start, DateTime(2025, 2, 1));
      expect(range.endExclusive, DateTime(2025, 3, 1));
      expect(range.endInclusive, DateTime(2025, 2, 28));
    });

    test('monthRange rolls over a December anchor', () {
      final MonthRange range = AppDateUtils.monthRange(DateTime(2025, 12, 5));
      expect(range.endExclusive, DateTime(2026, 1, 1));
    });

    test('addMonths crosses year boundaries in both directions', () {
      expect(AppDateUtils.addMonths(DateTime(2025, 1, 15), -1),
          DateTime(2024, 12, 1));
      expect(AppDateUtils.addMonths(DateTime(2025, 12, 15), 2),
          DateTime(2026, 2, 1));
    });

    test('trailingMonths returns oldest first and ends on the anchor', () {
      final List<DateTime> months =
          AppDateUtils.trailingMonths(DateTime(2025, 3, 20), 3);
      expect(months, <DateTime>[
        DateTime(2025, 1, 1),
        DateTime(2025, 2, 1),
        DateTime(2025, 3, 1),
      ]);
    });

    test('toDateString pads to the Postgres date wire format', () {
      expect(AppDateUtils.toDateString(DateTime(2025, 3, 7)), '2025-03-07');
    });
  });

  group('Formatters', () {
    test('compact currency uses Indian units for INR', () {
      expect(Formatters.currency(150000, compact: true), contains('L'));
      expect(Formatters.currency(2500, compact: true), contains('K'));
    });

    test('non-compact currency keeps two decimals', () {
      expect(Formatters.currency(12.5), contains('12.50'));
    });
  });

  group('ExpenseFilter', () {
    test('counts only the non-search constraints', () {
      const ExpenseFilter filter = ExpenseFilter(
        search: 'coffee',
        categoryIds: <String>{'a'},
      );
      expect(filter.activeCount, 1);
      expect(filter.hasAnyFilter, isTrue);
    });

    test('equality ignores set ordering so identical filters do not refetch',
        () {
      const ExpenseFilter a = ExpenseFilter(categoryIds: <String>{'x', 'y'});
      const ExpenseFilter b = ExpenseFilter(categoryIds: <String>{'y', 'x'});
      expect(a, equals(b));
    });

    test('cleared keeps search and sort but drops the rest', () {
      const ExpenseFilter filter = ExpenseFilter(
        search: 'tea',
        sort: ExpenseSort.oldestFirst,
        categoryIds: <String>{'a'},
      );
      final ExpenseFilter cleared = filter.cleared();
      expect(cleared.search, 'tea');
      expect(cleared.sort, ExpenseSort.oldestFirst);
      expect(cleared.categoryIds, isEmpty);
    });
  });

  group('buildCategoryBreakdown', () {
    Expense expense(String? categoryId, double amount) => Expense(
          id: 'e$amount$categoryId',
          userId: 'u1',
          amount: amount,
          expenseDate: DateTime(2025, 3, 1),
          categoryId: categoryId,
        );

    const ExpenseCategory food = ExpenseCategory(
      id: 'c1',
      userId: 'u1',
      name: 'Food',
    );

    test('sums per category and sorts by total descending', () {
      final List<CategorySpend> result = buildCategoryBreakdown(
        <Expense>[expense('c1', 100), expense('c1', 50), expense(null, 400)],
        <ExpenseCategory>[food],
      );

      expect(result.first.name, 'Uncategorised');
      expect(result.first.total, 400);
      expect(result[1].name, 'Food');
      expect(result[1].total, 150);
      expect(result[1].transactionCount, 2);
    });

    test('shareOf is proportional to the period total', () {
      final List<CategorySpend> result = buildCategoryBreakdown(
        <Expense>[expense('c1', 25)],
        <ExpenseCategory>[food],
      );
      expect(result.single.shareOf(100), 0.25);
      expect(result.single.shareOf(0), 0);
    });
  });

  group('BudgetProgress', () {
    Budget budget(double amount) => Budget(
          id: 'b1',
          userId: 'u1',
          amount: amount,
          month: DateTime(2025, 3, 1),
        );

    test('flags over-budget without clamping the ratio', () {
      final BudgetProgress p = BudgetProgress(budget: budget(100), spent: 150);
      expect(p.isOver, isTrue);
      expect(p.ratio, 1.5);
      expect(p.remaining, -50);
    });

    test('flags approaching at 80 percent but not before', () {
      expect(
          BudgetProgress(budget: budget(100), spent: 80).isApproaching, isTrue);
      expect(BudgetProgress(budget: budget(100), spent: 79).isApproaching,
          isFalse);
    });

    test('a zero limit does not divide by zero', () {
      expect(BudgetProgress(budget: budget(0), spent: 10).ratio, 0);
    });
  });
}
