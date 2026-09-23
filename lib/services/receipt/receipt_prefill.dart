/// Turns a scan into the values the Add Expense form opens with.
///
/// Pure, and separate from the review screen on purpose: this is the step
/// where a receipt becomes an expense, and it is worth being able to test
/// that a given receipt produces a given expense without driving a UI.
///
/// The review screen uses this for its initial state and then hands back
/// whatever the user edited, so the mapping tested here is exactly the one
/// that runs.
library;

import '../../models/expense_category.dart';
import '../../models/expense_prefill.dart';
import '../../models/payment_method.dart';
import 'receipt_result.dart';
import 'receipt_suggester.dart';

class ReceiptPrefill {
  const ReceiptPrefill({ReceiptSuggester suggester = const ReceiptSuggester()})
      : _suggester = suggester;

  final ReceiptSuggester _suggester;

  /// Maps [result] onto a draft expense.
  ///
  /// Nothing is invented. A field the scan did not read stays null, and the
  /// form shows it empty rather than filled with a default the user then has
  /// to notice and correct.
  ExpensePrefill build({
    required ReceiptResult result,
    List<ExpenseCategory> categories = const <ExpenseCategory>[],
    List<PaymentMethod> paymentMethods = const <PaymentMethod>[],
  }) {
    final ReceiptSuggestion<ExpenseCategory>? category =
        _suggester.suggestCategory(result: result, available: categories);
    final ReceiptSuggestion<PaymentMethod>? payment =
        _suggester.suggestPaymentMethod(
      result: result,
      available: paymentMethods,
    );

    return ExpensePrefill(
      // Only a positive amount is worth carrying over; a zero read is a
      // misread, and prefilling it would look like a real figure.
      amount: result.hasUsableTotal ? result.total.value : null,
      merchant: result.merchant.value,
      date: result.date.value,
      description: _suggester.describe(result),
      categoryId: category?.value.id,
      paymentMethodId: payment?.value.id,
      source: ExpensePrefillSource.receiptScan,
    );
  }

  /// Why the category was chosen, for the review screen to show. Null when
  /// nothing was suggested.
  String? categoryReason({
    required ReceiptResult result,
    required List<ExpenseCategory> categories,
  }) =>
      _suggester
          .suggestCategory(result: result, available: categories)
          ?.reason;
}
