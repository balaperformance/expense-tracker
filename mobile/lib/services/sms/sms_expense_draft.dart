/// Turns a parsed bank SMS into the expense the review screen opens on.
///
/// Pure, and separate from the screen on purpose: this is the step where a
/// message becomes a proposed expense, and it is worth being able to test
/// that a given SMS produces a given draft without driving a UI.
///
/// Nothing here writes anything. The draft is a proposal; the review screen
/// shows it, the user edits it, and only then does the existing expense
/// creation path run.
library;

import '../../models/bank_account.dart';
import '../../models/expense_category.dart';
import '../receipt/receipt_suggester.dart';
import 'bank_sms.dart';
import 'sms_account_matcher.dart';

/// Where a category came from, so the review screen can say so honestly
/// instead of presenting every choice as equally considered.
enum SmsCategorySource {
  /// A keyword in the payee matched, on this device.
  keyword,

  /// The AI classifier suggested it.
  assistant,

  /// Nothing matched, so the catch-all category was used.
  fallback,

  /// The user changed it.
  user,

  /// No category is selected.
  none,
}

/// One proposed expense, fully editable by the review screen.
class SmsExpenseDraft {
  const SmsExpenseDraft({
    required this.amount,
    required this.date,
    this.merchant,
    this.categoryId,
    this.categorySource = SmsCategorySource.none,
    this.categoryReason,
    this.bankAccountId,
    this.accountMatch,
    this.reference,
  });

  final double amount;
  final DateTime date;

  /// The payee, when the message named one.
  final String? merchant;

  final String? categoryId;
  final SmsCategorySource categorySource;

  /// Short explanation of the category choice: "matched 'fuel'".
  final String? categoryReason;

  /// Null means Cash — the same convention the Add Expense form uses, where
  /// null leaves every bank balance untouched.
  final String? bankAccountId;

  /// How the account was identified. Null when nothing matched, which the
  /// review screen says out loud.
  final SmsAccountMatch? accountMatch;

  final String? reference;

  bool get accountMatched => bankAccountId != null;

  SmsExpenseDraft copyWith({
    double? amount,
    DateTime? date,
    String? merchant,
    String? categoryId,
    SmsCategorySource? categorySource,
    String? categoryReason,
    String? bankAccountId,
    bool clearMerchant = false,
    bool clearCategory = false,
    bool clearAccount = false,
    bool clearCategoryReason = false,
  }) {
    return SmsExpenseDraft(
      amount: amount ?? this.amount,
      date: date ?? this.date,
      merchant: clearMerchant ? null : (merchant ?? this.merchant),
      categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
      categorySource: categorySource ?? this.categorySource,
      categoryReason:
          clearCategoryReason ? null : (categoryReason ?? this.categoryReason),
      bankAccountId:
          clearAccount ? null : (bankAccountId ?? this.bankAccountId),
      accountMatch: accountMatch,
      reference: reference,
    );
  }
}

class SmsDraftBuilder {
  const SmsDraftBuilder({
    ReceiptSuggester suggester = const ReceiptSuggester(),
    SmsAccountMatcher matcher = const SmsAccountMatcher(),
  })  : _suggester = suggester,
        _matcher = matcher;

  final ReceiptSuggester _suggester;
  final SmsAccountMatcher _matcher;

  /// Names that mean "I could not tell", in the order they are preferred.
  static const List<String> _fallbackNames = <String>[
    'other',
    'others',
    'miscellaneous',
    'misc',
    'uncategorised',
    'uncategorized',
    'general',
  ];

  /// Builds the draft for [sms].
  ///
  /// Only the payee is used for the category. The rest of the message is
  /// account numbers, reference ids and balances, which say nothing about
  /// what was bought and would only produce spurious keyword hits.
  SmsExpenseDraft build({
    required ParsedBankSms sms,
    required List<BankAccount> accounts,
    required List<ExpenseCategory> categories,
    required DateTime today,
  }) {
    final SmsAccountMatch? match =
        _matcher.match(sms: sms, accounts: accounts);

    final ReceiptSuggestion<ExpenseCategory>? keyword =
        sms.counterparty == null
            ? null
            : _suggester.suggestCategoryForText(
                text: sms.counterparty!,
                available: categories,
              );

    final ExpenseCategory? fallback = fallbackCategory(categories);

    return SmsExpenseDraft(
      amount: sms.amount ?? 0,
      date: sms.date ?? today,
      merchant: sms.counterparty,
      categoryId: keyword?.value.id ?? fallback?.id,
      categorySource: keyword != null
          ? SmsCategorySource.keyword
          : (fallback != null
              ? SmsCategorySource.fallback
              : SmsCategorySource.none),
      categoryReason: keyword?.reason,
      bankAccountId: match?.account.id,
      accountMatch: match,
      reference: sms.reference,
    );
  }

  /// The catch-all category, when the user has one.
  ///
  /// Never invented: if nothing in the list reads as a catch-all, the draft
  /// carries no category and the review screen asks for one rather than
  /// quietly filing the expense under whatever happened to be first.
  static ExpenseCategory? fallbackCategory(List<ExpenseCategory> categories) {
    for (final String wanted in _fallbackNames) {
      for (final ExpenseCategory category in categories) {
        if (category.name.trim().toLowerCase() == wanted) return category;
      }
    }
    return null;
  }

  /// Finds the category the AI named, matching on the user's own names only.
  ///
  /// The model is told which names exist, but its answer is still checked
  /// against the list here rather than trusted — a suggestion that is not one
  /// of the user's categories is discarded, not created.
  static ExpenseCategory? categoryByName(
    List<ExpenseCategory> categories,
    String? name,
  ) {
    final String? wanted = name?.trim().toLowerCase();
    if (wanted == null || wanted.isEmpty) return null;
    for (final ExpenseCategory category in categories) {
      if (category.name.trim().toLowerCase() == wanted) return category;
    }
    return null;
  }
}

/// How a transaction reference is recorded on the expense.
///
/// One place, because the writer and the duplicate check have to agree
/// exactly: if the note format drifts, duplicate detection silently stops
/// working and the user gets no warning at all.
///
/// The reference goes in `notes`, a column that already exists. Nothing about
/// this feature needs a schema change.
class SmsReferenceNote {
  const SmsReferenceNote._();

  static const String prefix = 'Bank SMS ref';

  /// The note text stored on an expense imported from a message.
  static String forReference(String reference) => '$prefix $reference';

  /// The fragment a duplicate search looks for. Narrow enough that an
  /// ordinary note mentioning a number cannot collide with it.
  static String searchTerm(String reference) => '$prefix $reference';
}
