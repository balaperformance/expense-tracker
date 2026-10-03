/// Quick add: the purchases the user makes again and again (the morning
/// coffee, the weekly groceries, the monthly recharge) offered as one-tap
/// starting points on a new expense.
///
/// A line-for-line port of the web app's `ui/src/domain/frequentExpenses.ts`.
/// `ui/src/domain/frequentExpenses.fixture.json` is read by the tests on both
/// sides, so the app and the web always suggest the same things.
///
/// A suggestion only fills the form. Saving still goes through the normal
/// path, so validation, the ledger debit and the card outstanding stay where
/// they are, and nothing is written until the user says so.
library;

import 'expense.dart';

/// How far back the habits are read: long enough to see a monthly bill
/// three times.
const int frequentWindowDays = 90;

/// Fewer purchases than this are not a habit yet.
const int frequentMinCount = 3;

const int frequentLimit = 6;

/// The newest purchases read for suggestions: enough for months of typical
/// use, bounded for a busy one.
const int frequentHistoryRows = 300;

enum FrequentSourceKind { cash, account, card }

/// How it was paid last time, while that is still possible.
class FrequentSource {
  const FrequentSource.cash()
      : kind = FrequentSourceKind.cash,
        id = null;
  const FrequentSource.account(String this.id)
      : kind = FrequentSourceKind.account;
  const FrequentSource.card(String this.id) : kind = FrequentSourceKind.card;

  final FrequentSourceKind kind;

  /// The account or card; null for cash.
  final String? id;
}

class FrequentExpense {
  const FrequentExpense({
    required this.key,
    required this.title,
    required this.categoryId,
    required this.amount,
    required this.description,
    required this.merchant,
    required this.paymentMethodId,
    required this.source,
    required this.count,
    required this.lastDate,
  });

  /// The category and the normalised title: stable while the habit lasts.
  final String key;

  /// The merchant or description as last written; null when neither was, so
  /// the category names it.
  final String? title;

  final String categoryId;

  /// The usual amount, or null when it varies (no single amount covers half
  /// of the purchases).
  final double? amount;

  final String? description;
  final String? merchant;

  /// Null when none was set last time or the method has since been deleted.
  final String? paymentMethodId;

  /// Null when the account or card it was last paid from is closed or gone;
  /// the form then starts from cash.
  final FrequentSource? source;

  final int count;
  final DateTime lastDate;
}

class FrequentExpenseContext {
  const FrequentExpenseContext({
    required this.today,
    required this.excludeIds,
    required this.categoryIds,
    required this.paymentMethodIds,
    required this.accountIds,
    required this.cardIds,
  });

  final DateTime today;

  /// Purchases paid on someone else's behalf: owed back, so not the user's
  /// own habits.
  final Set<String> excludeIds;

  /// What the form can offer now, so a suggestion never points at a deleted
  /// category or a closed account.
  final Set<String> categoryIds;
  final Set<String> paymentMethodIds;
  final Set<String> accountIds;
  final Set<String> cardIds;
}

String? _clean(String? text) {
  final String trimmed = (text ?? '').trim();
  return trimmed.isEmpty ? null : trimmed;
}

final RegExp _spaces = RegExp(r'\s+');

/// "Uber", " uber " and "UBER" are one habit.
String _normalise(String title) => title.toLowerCase().replaceAll(_spaces, ' ');

int _cents(double amount) => (amount * 100).round();

/// Negative when [a] happened before [b]: by date, then entry time, then id.
int _chronological(Expense a, Expense b) {
  final int byDate = a.expenseDate.compareTo(b.expenseDate);
  if (byDate != 0) return byDate;
  final DateTime? aCreated = a.createdAt;
  final DateTime? bCreated = b.createdAt;
  final int byCreated = aCreated == null
      ? (bCreated == null ? 0 : -1)
      : (bCreated == null ? 1 : aCreated.compareTo(bCreated));
  return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
}

class _Tally {
  _Tally(this.cents, this.last);

  final int cents;
  int count = 1;
  Expense last;
}

/// The amount that covers at least half of the purchases (and more than
/// one), most recent on a tie.
double? _usualAmount(List<Expense> group) {
  final Map<int, _Tally> tally = <int, _Tally>{};
  for (final Expense expense in group) {
    final int key = _cents(expense.amount);
    final _Tally? seen = tally[key];
    if (seen == null) {
      tally[key] = _Tally(key, expense);
    } else {
      seen.count += 1;
      if (_chronological(expense, seen.last) > 0) seen.last = expense;
    }
  }
  _Tally? best;
  for (final _Tally candidate in tally.values) {
    final _Tally? current = best;
    if (current == null ||
        candidate.count > current.count ||
        (candidate.count == current.count &&
            _chronological(candidate.last, current.last) > 0)) {
      best = candidate;
    }
  }
  final _Tally? found = best;
  return found != null && found.count >= 2 && found.count * 2 >= group.length
      ? found.cents / 100
      : null;
}

FrequentSource? _sourceOf(Expense expense, FrequentExpenseContext context) {
  final String? cardId = expense.creditCardId;
  if (cardId != null) {
    return context.cardIds.contains(cardId) ? FrequentSource.card(cardId) : null;
  }
  final String? accountId = expense.bankAccountId;
  if (accountId != null) {
    return context.accountIds.contains(accountId)
        ? FrequentSource.account(accountId)
        : null;
  }
  return const FrequentSource.cash();
}

/// The user's most frequent purchases over the last [frequentWindowDays]
/// days, most frequent first: grouped by category and title (merchant, else
/// description), each bought at least [frequentMinCount] times. Each one is
/// filled from its latest purchase, with the usual amount when there is one.
List<FrequentExpense> frequentExpenses(
  Iterable<Expense> expenses,
  FrequentExpenseContext context, {
  int limit = frequentLimit,
}) {
  final DateTime today =
      DateTime(context.today.year, context.today.month, context.today.day);
  final DateTime from =
      DateTime(today.year, today.month, today.day - (frequentWindowDays - 1));

  final Map<String, List<Expense>> groups = <String, List<Expense>>{};
  final Map<String, String> categoryOf = <String, String>{};
  for (final Expense expense in expenses) {
    final String? categoryId = expense.categoryId;
    if (categoryId == null ||
        !context.categoryIds.contains(categoryId) ||
        context.excludeIds.contains(expense.id)) {
      continue;
    }
    if (!(expense.amount > 0) ||
        expense.expenseDate.isBefore(from) ||
        expense.expenseDate.isAfter(today)) {
      continue;
    }
    final String? title = _clean(expense.merchant) ?? _clean(expense.description);
    final String key = '$categoryId|${title == null ? '' : _normalise(title)}';
    (groups[key] ??= <Expense>[]).add(expense);
    categoryOf[key] = categoryId;
  }

  final List<(FrequentExpense, Expense)> found = <(FrequentExpense, Expense)>[];
  groups.forEach((String key, List<Expense> group) {
    if (group.length < frequentMinCount) return;
    final Expense latest =
        group.reduce((Expense a, Expense b) => _chronological(b, a) > 0 ? b : a);
    final String? methodId = latest.paymentMethodId;
    found.add((
      FrequentExpense(
        key: key,
        title: _clean(latest.merchant) ?? _clean(latest.description),
        categoryId: categoryOf[key]!,
        amount: _usualAmount(group),
        description: _clean(latest.description),
        merchant: _clean(latest.merchant),
        paymentMethodId:
            methodId != null && context.paymentMethodIds.contains(methodId)
                ? methodId
                : null,
        source: _sourceOf(latest, context),
        count: group.length,
        lastDate: latest.expenseDate,
      ),
      latest,
    ));
  });

  found.sort(((FrequentExpense, Expense) a, (FrequentExpense, Expense) b) {
    final int byCount = b.$1.count - a.$1.count;
    if (byCount != 0) return byCount;
    final int byRecency = _chronological(b.$2, a.$2);
    return byRecency != 0 ? byRecency : a.$1.key.compareTo(b.$1.key);
  });
  return found
      .take(limit < 0 ? 0 : limit)
      .map(((FrequentExpense, Expense) f) => f.$1)
      .toList();
}
