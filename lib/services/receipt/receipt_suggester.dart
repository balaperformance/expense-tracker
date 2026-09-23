/// Suggests a category and a payment method for a scanned receipt.
///
/// Pure Dart and deliberately conservative. A suggestion is a shortcut, never
/// a decision: when the evidence is thin the suggester returns nothing, so the
/// review screen leaves the field empty rather than pre-filling it with a
/// plausible-looking wrong answer the user then has to notice and undo.
library;

import '../../models/expense_category.dart';
import '../../models/payment_method.dart';
import 'receipt_result.dart';

/// A suggested value plus why it was suggested, so the UI can say so.
class ReceiptSuggestion<T> {
  const ReceiptSuggestion({required this.value, required this.reason});

  final T value;

  /// Short, user-facing: "matched 'cafe'".
  final String reason;
}

class ReceiptSuggester {
  const ReceiptSuggester();

  /// Words that point at a kind of spending, grouped by the default category
  /// they belong to.
  ///
  /// Matched against the merchant name and the item descriptions. The keys are
  /// the seed category names; a user who renamed or added categories is
  /// matched by name below, and simply gets no suggestion if nothing lines up.
  static const Map<String, List<String>> _categoryKeywords =
      <String, List<String>>{
    'Food': <String>[
      'restaurant', 'cafe', 'coffee', 'pizza', 'burger', 'kitchen', 'bakery',
      'bakers', 'dhaba', 'biryani', 'foods', 'eatery', 'diner', 'bistro',
      'juice', 'tea ', 'chai', 'swiggy', 'zomato', 'grocery', 'supermarket',
      'hypermarket', 'mart', 'provision', 'bar & grill', 'canteen',
    ],
    'Transport': <String>[
      'fuel', 'petrol', 'diesel', 'petroleum', 'filling station', 'gas ',
      'uber', 'ola ', 'rapido', 'cab', 'taxi', 'metro', 'parking', 'toll',
      'transport', 'travels', 'bus ',
    ],
    'Shopping': <String>[
      'store', 'retail', 'fashion', 'apparel', 'clothing', 'lifestyle',
      'trends', 'boutique', 'footwear', 'electronics', 'amazon', 'flipkart',
      'myntra', 'department', 'shoppe', 'shopping',
    ],
    'Bills': <String>[
      'electricity', 'power', 'water board', 'broadband', 'telecom',
      'recharge', 'postpaid', 'prepaid', 'airtel', 'jio', 'vodafone',
      'internet', 'utility', 'gas bill', 'insurance', 'premium',
    ],
    'Entertainment': <String>[
      'cinema', 'cinemas', 'multiplex', 'pvr', 'inox', 'theatre', 'theater',
      'movie', 'netflix', 'spotify', 'prime video', 'gaming', 'bowling',
      'amusement',
    ],
    'Health': <String>[
      'pharmacy', 'pharma', 'medical', 'medicos', 'chemist', 'hospital',
      'clinic', 'diagnostic', 'laboratory', 'labs', 'dental', 'apollo',
      'wellness', 'optical',
    ],
    'Travel': <String>[
      'airlines', 'airways', 'indigo', 'hotel', 'resort', 'lodge', 'inn ',
      'makemytrip', 'goibibo', 'irctc', 'railway', 'booking', 'tourism',
    ],
    'Education': <String>[
      'school', 'college', 'university', 'institute', 'academy', 'tuition',
      'books', 'stationery', 'stationers', 'coaching', 'course',
    ],
  };

  /// How a receipt says which tender was used.
  ///
  /// Keyed by the seed payment-method names.
  static const Map<String, List<String>> _paymentKeywords =
      <String, List<String>>{
    'UPI': <String>['upi', 'gpay', 'google pay', 'phonepe', 'paytm', 'bhim'],
    'Credit Card': <String>['credit card', 'creditcard', 'visa credit'],
    'Debit Card': <String>['debit card', 'debitcard', 'visa debit', 'rupay'],
    'Net Banking': <String>['net banking', 'netbanking', 'imps', 'neft'],
    'Wallet': <String>['wallet', 'paytm wallet'],
    'Cash': <String>['cash tendered', 'cash paid', 'by cash', 'cash:'],
  };

  /// Picks a category from [available], or nothing.
  ///
  /// Only the merchant name and item descriptions are searched — never the
  /// amount, which carries no signal about what was bought.
  ReceiptSuggestion<ExpenseCategory>? suggestCategory({
    required ReceiptResult result,
    required List<ExpenseCategory> available,
  }) =>
      suggestCategoryForText(text: _haystack(result), available: available);

  /// The same keyword matching against any merchant-ish text.
  ///
  /// Exists so bank-SMS import can classify a payee without duplicating the
  /// table above. The two features then agree by construction: adding
  /// "dhaba" to Food fixes both a scanned receipt and a pasted SMS, and
  /// neither can drift into classifying the same merchant differently.
  ///
  /// The caller decides what text is fair game. A receipt passes the merchant
  /// and the item names; an SMS passes the payee. Neither passes the whole
  /// message, because an address containing "School Road" would suggest
  /// Education for a grocery run.
  ReceiptSuggestion<ExpenseCategory>? suggestCategoryForText({
    required String text,
    required List<ExpenseCategory> available,
  }) {
    if (available.isEmpty) return null;

    final String haystack = text.toLowerCase();
    if (haystack.trim().isEmpty) return null;

    for (final MapEntry<String, List<String>> entry
        in _categoryKeywords.entries) {
      final String? hit = _firstHit(haystack, entry.value);
      if (hit == null) continue;

      final ExpenseCategory? category = _byName(available, entry.key);
      if (category == null) continue;

      return ReceiptSuggestion<ExpenseCategory>(
        value: category,
        reason: "matched '${hit.trim()}'",
      );
    }

    return null;
  }

  /// Picks a payment method from [available], or nothing.
  ///
  /// Searches the whole receipt, not just the merchant and items, because the
  /// tender is stated in a footer line — "Paid by UPI", "CARD XXXX 4821" —
  /// that belongs to neither. Category matching deliberately does *not* read
  /// the whole receipt: an address containing "School Road" would suggest
  /// Education for a grocery run.
  ///
  /// Receipts state the tender far less reliably than the total, so this only
  /// fires on an explicit mention.
  ReceiptSuggestion<PaymentMethod>? suggestPaymentMethod({
    required ReceiptResult result,
    required List<PaymentMethod> available,
  }) {
    if (available.isEmpty) return null;

    final String haystack = result.rawLines.join(' ').toLowerCase();
    if (haystack.isEmpty) return null;

    for (final MapEntry<String, List<String>> entry
        in _paymentKeywords.entries) {
      final String? hit = _firstHit(haystack, entry.value);
      if (hit == null) continue;

      final PaymentMethod? method = _byNameMethod(available, entry.key);
      if (method == null) continue;

      return ReceiptSuggestion<PaymentMethod>(
        value: method,
        reason: "matched '${hit.trim()}'",
      );
    }

    return null;
  }

  /// A short description built from the scan, used to prefill the expense.
  ///
  /// Item names are the most useful thing a receipt adds beyond the total, so
  /// the first few become the description. Returns null when there is nothing
  /// worth saying.
  String? describe(ReceiptResult result) {
    if (result.lineItems.isEmpty) return null;

    final List<String> names = result.lineItems
        .take(3)
        .map((ReceiptLineItem item) => item.display)
        .toList();

    final String joined = names.join(', ');
    return result.lineItems.length > names.length
        ? '$joined +${result.lineItems.length - names.length} more'
        : joined;
  }

  String _haystack(ReceiptResult result) {
    final StringBuffer buffer = StringBuffer();
    final String? merchant = result.merchant.value;
    if (merchant != null) buffer.write('$merchant ');
    for (final ReceiptLineItem item in result.lineItems) {
      buffer.write('${item.description} ');
    }
    return buffer.toString().toLowerCase();
  }

  String? _firstHit(String haystack, List<String> keywords) {
    for (final String keyword in keywords) {
      if (haystack.contains(keyword)) return keyword;
    }
    return null;
  }

  ExpenseCategory? _byName(List<ExpenseCategory> all, String name) {
    final String target = name.toLowerCase();
    for (final ExpenseCategory category in all) {
      if (category.name.toLowerCase() == target) return category;
    }
    return null;
  }

  PaymentMethod? _byNameMethod(List<PaymentMethod> all, String name) {
    final String target = name.toLowerCase();
    for (final PaymentMethod method in all) {
      if (method.name.toLowerCase() == target) return method;
    }
    return null;
  }
}
