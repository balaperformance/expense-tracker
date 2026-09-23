/// Values to open the Add Expense form with, already filled in.
///
/// This is the whole contract between receipt scanning and the expense flow.
/// The scanner never writes an expense: it produces one of these, the normal
/// form opens on it, and the user saves through exactly the path they would
/// have used typing it by hand. That is deliberate — validation, the ledger
/// debit, the category requirement and the error handling all stay in one
/// place, and a scanned expense is indistinguishable from a typed one once
/// saved.
///
/// Every field is optional. A scan that read only the total still saves the
/// user the typing that matters most.
library;

class ExpensePrefill {
  const ExpensePrefill({
    this.amount,
    this.merchant,
    this.date,
    this.description,
    this.notes,
    this.categoryId,
    this.paymentMethodId,
    this.source = ExpensePrefillSource.manual,
  });

  final double? amount;
  final String? merchant;
  final DateTime? date;
  final String? description;
  final String? notes;

  /// Suggested, not imposed: the form shows it selected and the user can
  /// change it like any other choice.
  final String? categoryId;
  final String? paymentMethodId;

  final ExpensePrefillSource source;

  bool get isEmpty =>
      amount == null &&
      merchant == null &&
      date == null &&
      description == null &&
      categoryId == null;

  ExpensePrefill copyWith({
    double? amount,
    String? merchant,
    DateTime? date,
    String? description,
    String? notes,
    String? categoryId,
    String? paymentMethodId,
    bool clearCategory = false,
    bool clearPaymentMethod = false,
  }) {
    return ExpensePrefill(
      amount: amount ?? this.amount,
      merchant: merchant ?? this.merchant,
      date: date ?? this.date,
      description: description ?? this.description,
      notes: notes ?? this.notes,
      categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
      paymentMethodId: clearPaymentMethod
          ? null
          : (paymentMethodId ?? this.paymentMethodId),
      source: source,
    );
  }
}

/// Where a prefill came from, so the form can say so.
enum ExpensePrefillSource { manual, receiptScan }
