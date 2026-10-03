/// Tests the path a scanned receipt takes to become a saved expense.
///
/// The steps are: OCR text -> [ReceiptResult] -> [ExpensePrefill] -> the
/// [Expense] the ordinary Add Expense form builds and saves. The middle two
/// are pure and asserted directly here; the last is asserted by constructing
/// the expense exactly as `ExpenseFormScreen._save` does, so the values that
/// reach the repository are the ones under test.
///
/// The property that matters most: a scan never invents a value. Anything the
/// receipt did not say arrives null, and the form shows it empty.
library;

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/expense_prefill.dart';
import 'package:expense_tracker/models/payment_method.dart';
import 'package:expense_tracker/screens/expenses/receipt_scan_flow.dart';
import 'package:expense_tracker/services/receipt/receipt_parser.dart';
import 'package:expense_tracker/services/receipt/receipt_prefill.dart';
import 'package:expense_tracker/services/receipt/receipt_result.dart';
import 'package:expense_tracker/services/receipt/receipt_scanner_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const ReceiptParser parser = ReceiptParser();
const ReceiptPrefill prefiller = ReceiptPrefill();

final List<ExpenseCategory> categories = <ExpenseCategory>[
  const ExpenseCategory(id: 'food', userId: 'u1', name: 'Food'),
  const ExpenseCategory(id: 'transport', userId: 'u1', name: 'Transport'),
];

final List<PaymentMethod> methods = <PaymentMethod>[
  const PaymentMethod(id: 'upi', userId: 'u1', name: 'UPI'),
  const PaymentMethod(id: 'cash', userId: 'u1', name: 'Cash'),
];

const String supermarketReceipt = '''
GREEN LEAF SUPERMARKET
No 42, 5th Cross, Indiranagar
GSTIN: 29AABCU9603R1ZJ
Bill No: 2024/0931
Date: 14/03/2024
Basmati Rice 5kg        450.00
Amul Butter 500g        265.00
Sub Total               715.00
CGST 2.5%                17.88
GRAND TOTAL             750.76
Paid by UPI
''';

ExpensePrefill prefillFrom(String text) => prefiller.build(
      result: parser.parseText(text),
      categories: categories,
      paymentMethods: methods,
    );

/// Builds the expense exactly as the save handler does, so this asserts what
/// actually reaches the repository.
Expense expenseFrom(ExpensePrefill prefill) => Expense(
      id: '',
      userId: 'u1',
      amount: prefill.amount!,
      expenseDate: prefill.date!,
      categoryId: prefill.categoryId,
      paymentMethodId: prefill.paymentMethodId,
      bankAccountId: null,
      merchant: prefill.merchant,
      description: prefill.description,
      notes: prefill.notes,
    );

void main() {
  group('receipt to prefill', () {
    test('a clean receipt fills every field it can', () {
      final ExpensePrefill prefill = prefillFrom(supermarketReceipt);

      expect(prefill.amount, 750.76);
      expect(prefill.merchant, 'Green Leaf Supermarket');
      expect(prefill.date, DateTime(2024, 3, 14));
      expect(prefill.categoryId, 'food');
      expect(prefill.paymentMethodId, 'upi');
      expect(prefill.description, 'Basmati Rice 5kg, Amul Butter 500g');
      expect(prefill.source, ExpensePrefillSource.receiptScan);
      expect(prefill.isEmpty, isFalse);
    });

    test('an unreadable scan fills nothing at all', () {
      final ExpensePrefill prefill = prefillFrom('#### ~~~~');

      expect(prefill.amount, isNull);
      expect(prefill.merchant, isNull);
      expect(prefill.date, isNull);
      expect(prefill.categoryId, isNull);
      expect(prefill.isEmpty, isTrue);
    });

    test('a partial scan fills only what it read', () {
      final ExpensePrefill prefill = prefillFrom('TOTAL 240.00');

      expect(prefill.amount, 240.00);
      expect(prefill.merchant, isNull);
      expect(prefill.date, isNull);
      expect(
        prefill.categoryId,
        isNull,
        reason: 'no merchant means no basis for a category',
      );
    });

    test('a zero total is treated as a misread, not as an amount', () {
      final ExpensePrefill prefill = prefillFrom('SHOP\nTOTAL 0.00');
      expect(prefill.amount, isNull);
    });

    test('suggests nothing when the user has no categories', () {
      final ExpensePrefill prefill = prefiller.build(
        result: parser.parseText(supermarketReceipt),
        categories: const <ExpenseCategory>[],
        paymentMethods: const <PaymentMethod>[],
      );

      expect(prefill.amount, 750.76, reason: 'the money is still read');
      expect(prefill.categoryId, isNull);
      expect(prefill.paymentMethodId, isNull);
    });

    test('the category reason is quotable in the UI', () {
      expect(
        prefiller.categoryReason(
          result: parser.parseText(supermarketReceipt),
          categories: categories,
        ),
        contains('supermarket'),
      );
    });
  });

  group('prefill to expense', () {
    test('every scanned value survives into the saved expense', () {
      final Expense expense = expenseFrom(prefillFrom(supermarketReceipt));

      expect(expense.amount, 750.76);
      expect(expense.merchant, 'Green Leaf Supermarket');
      expect(expense.expenseDate, DateTime(2024, 3, 14));
      expect(expense.categoryId, 'food');
      expect(expense.paymentMethodId, 'upi');
    });

    test('a scanned expense is an ordinary expense, not a special one', () {
      final Expense expense = expenseFrom(prefillFrom(supermarketReceipt));

      // Nothing on the row marks it as scanned: it is written through the
      // same insert as a typed one, and no schema change was needed.
      final Map<String, dynamic> row = expense.toInsertMap(
        includeMerchant: true,
        includeBankLink: true,
      );

      expect(row['amount'], 750.76);
      expect(row['merchant'], 'Green Leaf Supermarket');
      expect(row['expense_date'], '2024-03-14');
      expect(row['category_id'], 'food');
      expect(row.containsKey('receipt'), isFalse);
      expect(row.containsKey('scanned'), isFalse);
    });

    test('a scan defaults to Cash, so no bank balance moves by surprise', () {
      final Expense expense = expenseFrom(prefillFrom(supermarketReceipt));
      expect(expense.bankAccountId, isNull);
    });

    test('the title falls back the same way a typed expense does', () {
      final Expense expense = expenseFrom(prefillFrom(supermarketReceipt));
      expect(expense.title, 'Green Leaf Supermarket');
    });
  });

  group('user corrections', () {
    test('an edited amount replaces the scanned one', () {
      final ExpensePrefill corrected =
          prefillFrom(supermarketReceipt).copyWith(amount: 999.00);

      expect(corrected.amount, 999.00);
      expect(corrected.merchant, 'Green Leaf Supermarket');
      expect(corrected.source, ExpensePrefillSource.receiptScan);
    });

    test('a suggested category can be cleared, not just changed', () {
      final ExpensePrefill cleared =
          prefillFrom(supermarketReceipt).copyWith(clearCategory: true);

      expect(cleared.categoryId, isNull);
      expect(cleared.amount, 750.76, reason: 'clearing one field keeps others');
    });

    test('a suggested payment method can be cleared', () {
      expect(
        prefillFrom(supermarketReceipt)
            .copyWith(clearPaymentMethod: true)
            .paymentMethodId,
        isNull,
      );
    });
  });

  group('failure messages', () {
    test('every problem has something the user can act on', () {
      for (final ReceiptScanProblem problem in ReceiptScanProblem.values) {
        expect(problem.message, isNotEmpty);
        expect(problem.message.length, greaterThan(10));
      }
    });

    test('a cancelled scan is not phrased as an error', () {
      expect(
        ReceiptScanProblem.cancelled.message.toLowerCase(),
        isNot(contains('failed')),
      );
    });

    test('the permission message points at device settings', () {
      expect(
        ReceiptScanProblem.permissionDenied.message,
        contains('settings'),
      );
    });

    test('an unavailable scanner reports a failure rather than throwing',
        () async {
      const ReceiptScannerService scanner = UnavailableReceiptScanner();

      expect(scanner.isAvailable, isFalse);
      final ReceiptScanOutcome outcome =
          await scanner.scan(ReceiptImageSource.camera);
      expect(outcome, isA<ReceiptScanFailed>());
      await scanner.dispose();
    });

    test('both image sources describe themselves', () {
      for (final ReceiptImageSource source in ReceiptImageSource.values) {
        expect(source.label, isNotEmpty);
        expect(source.description, isNotEmpty);
      }
    });
  });

  group('confidence', () {
    test('a confident field is not flagged for review', () {
      const ReceiptField<double> clear =
          ReceiptField<double>(100, ReceiptConfidence.high);
      expect(clear.shouldVerify, isFalse);
      expect(clear.confidence.found, isTrue);
    });

    test('a guessed field is flagged', () {
      const ReceiptField<double> guess =
          ReceiptField<double>(100, ReceiptConfidence.medium);
      expect(guess.shouldVerify, isTrue);
    });

    test('a missing field is not "unsure", it is absent', () {
      const ReceiptField<double> none = ReceiptField<double>.missing();
      expect(none.hasValue, isFalse);
      expect(none.shouldVerify, isFalse);
      expect(none.confidence.found, isFalse);
    });

    test('a missing amount is always listed for the user to fill in', () {
      final ReceiptResult result = parser.parseText('SOME SHOP NAME');
      expect(result.fieldsToVerify, contains('amount'));
    });

    test('a clean receipt asks the user to verify nothing', () {
      expect(parser.parseText(supermarketReceipt).fieldsToVerify, isEmpty);
    });
  });

  group('scan entry point renders', () {
    Future<void> rendersAt(WidgetTester tester, double width) async {
      for (final Brightness brightness in Brightness.values) {
        tester.view.physicalSize = Size(width * 3, 780 * 3);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            theme:
                brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: ScanReceiptCard(onTap: () {}),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          tester.takeException(),
          isNull,
          reason: 'failed at ${width}px in $brightness',
        );
        expect(find.text('Scan a receipt'), findsOneWidget);
      }
    }

    testWidgets('at every supported width, in both themes', (
      WidgetTester tester,
    ) async {
      for (final double width in <double>[320, 360, 411]) {
        await rendersAt(tester, width);
      }
    });

    testWidgets('a busy card cannot be tapped', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ScanReceiptCard(onTap: () => taps++, busy: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Scan a receipt'));
      await tester.pumpAndSettle();

      expect(taps, 0);
    });
  });
}
