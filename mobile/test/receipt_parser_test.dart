/// Tests for receipt text extraction.
///
/// The parser is the part of scanning most likely to be wrong and the part a
/// user notices immediately when it is, so these tests run real receipt
/// layouts — Indian retail, a cafe bill, a fuel slip, a US-style receipt —
/// rather than tidy synthetic strings.
library;

import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/models/payment_method.dart';
import 'package:expense_tracker/services/receipt/receipt_parser.dart';
import 'package:expense_tracker/services/receipt/receipt_result.dart';
import 'package:expense_tracker/services/receipt/receipt_suggester.dart';
import 'package:flutter_test/flutter_test.dart';

const ReceiptParser parser = ReceiptParser();
const ReceiptSuggester suggester = ReceiptSuggester();

List<String> lines(String block) => block
    .trim()
    .split('\n')
    .map((String line) => line.trim())
    .toList();

void main() {
  group('total', () {
    test('reads a labelled total', () {
      final ReceiptResult result = parser.parse(lines('''
        GREEN LEAF SUPERMARKET
        Rice 5kg          450.00
        Milk 1L            62.00
        Subtotal          512.00
        CGST 2.5%          12.80
        SGST 2.5%          12.80
        TOTAL             537.60
      '''));

      expect(result.total.value, 537.60);
      expect(result.total.confidence, ReceiptConfidence.high);
    });

    test('prefers grand total over the running total above it', () {
      final ReceiptResult result = parser.parse(lines('''
        Total              900.00
        Discount            50.00
        Grand Total        850.00
      '''));

      expect(result.total.value, 850.00);
    });

    test('never mistakes a subtotal for the total', () {
      final ReceiptResult result = parser.parse(lines('''
        Sub Total         1200.00
        Total Savings      150.00
        Amount Payable    1050.00
      '''));

      expect(result.total.value, 1050.00);
    });

    test('never mistakes a tax total for the total', () {
      final ReceiptResult result = parser.parse(lines('''
        Total Tax           90.00
        Total             1090.00
      '''));

      expect(result.total.value, 1090.00);
    });

    test('takes the amount from the line below a bare label', () {
      final ReceiptResult result = parser.parse(lines('''
        Coffee              180.00
        AMOUNT DUE
        212.40
      '''));

      expect(result.total.value, 212.40);
      expect(result.total.confidence, ReceiptConfidence.high);
    });

    test('handles Indian digit grouping', () {
      final ReceiptResult result = parser.parse(lines('''
        Laptop
        Grand Total    1,23,456.78
      '''));

      expect(result.total.value, 123456.78);
    });

    test('handles western digit grouping', () {
      final ReceiptResult result = parser.parse(lines('''
        TOTAL   \$1,234.56
      '''));

      expect(result.total.value, 1234.56);
    });

    test('falls back to the largest amount, marked as a guess', () {
      final ReceiptResult result = parser.parse(lines('''
        CORNER STORE
        Bread            45.00
        Butter          220.00
        Jam              98.50
      '''));

      expect(result.total.value, 220.00);
      expect(result.total.confidence, ReceiptConfidence.medium);
      expect(result.total.shouldVerify, isTrue);
    });

    test('a phone number is not an amount', () {
      final ReceiptResult result = parser.parse(lines('''
        SPICE HOUSE
        Ph: 9876543210
        TOTAL   340.00
      '''));

      expect(result.total.value, 340.00);
    });

    test('a date is not an amount', () {
      // 12.05.2024 would read as 12.05 if dates were not stripped first, and
      // on a receipt with no labelled total that would become the amount.
      final ReceiptResult result = parser.parse(lines('''
        SOME SHOP
        Date 12.05.2024
        Item             75.00
      '''));

      expect(result.total.value, 75.00);
    });

    test('an unreadable receipt yields no total', () {
      final ReceiptResult result = parser.parse(lines('''
        ~~~~~
        ?????
      '''));

      expect(result.total.hasValue, isFalse);
      expect(result.hasUsableTotal, isFalse);
    });
  });

  group('date', () {
    test('reads day-first numeric dates', () {
      final ReceiptResult result = parser.parse(<String>['Date: 14/03/2024']);
      expect(result.date.value, DateTime(2024, 3, 14));
    });

    test('reads ISO dates', () {
      final ReceiptResult result = parser.parse(<String>['2024-03-14 19:42']);
      expect(result.date.value, DateTime(2024, 3, 14));
    });

    test('resolves month-first when the first number cannot be a day', () {
      // 03/28 has no 28th month, so this can only be March 28th.
      final ReceiptResult result = parser.parse(<String>['03/28/2024']);
      expect(result.date.value, DateTime(2024, 3, 28));
    });

    test('expands a two-digit year to this century', () {
      final ReceiptResult result = parser.parse(<String>['05-06-24']);
      expect(result.date.value, DateTime(2024, 6, 5));
    });

    test('reads a written month', () {
      final ReceiptResult result = parser.parse(<String>['12 Mar 2024']);
      expect(result.date.value, DateTime(2024, 3, 12));
    });

    test('reads a leading written month', () {
      final ReceiptResult result = parser.parse(<String>['Mar 12, 2024']);
      expect(result.date.value, DateTime(2024, 3, 12));
    });

    test('rejects an impossible day rather than rolling it over', () {
      // 32 January must not silently become 1 February.
      final ReceiptResult result = parser.parse(<String>['32/01/2024']);
      expect(result.date.hasValue, isFalse);
    });

    test('rejects 31 April', () {
      final ReceiptResult result = parser.parse(<String>['31/04/2024']);
      expect(result.date.hasValue, isFalse);
    });

    test('flags an implausible date instead of dropping it', () {
      final int nextYear = DateTime.now().year + 1;
      final ReceiptResult result =
          parser.parse(<String>['Date 10/10/$nextYear']);

      expect(result.date.hasValue, isTrue, reason: 'offered for correction');
      expect(result.date.confidence, ReceiptConfidence.low);
    });

    test("today's date reads as confident", () {
      final DateTime now = DateTime.now();
      final String text = '${now.day}/${now.month}/${now.year}';
      final ReceiptResult result = parser.parse(<String>[text]);

      expect(result.date.value, DateTime(now.year, now.month, now.day));
      expect(result.date.confidence, ReceiptConfidence.high);
    });
  });

  group('merchant', () {
    test('reads a shouting header and title-cases it', () {
      final ReceiptResult result = parser.parse(lines('''
        SPAR HYPERMARKET
        12 MG Road, Bengaluru 560001
        GSTIN 29ABCDE1234F1Z5
        TOTAL 812.00
      '''));

      expect(result.merchant.value, 'Spar Hypermarket');
      expect(result.merchant.confidence, ReceiptConfidence.high);
    });

    test('leaves a mixed-case name exactly as printed', () {
      final ReceiptResult result = parser.parse(lines('''
        The Daily Grind Cafe
        Total 310.00
      '''));

      expect(result.merchant.value, 'The Daily Grind Cafe');
    });

    test('skips invoice and tax metadata', () {
      final ReceiptResult result = parser.parse(lines('''
        TAX INVOICE
        GSTIN: 29AABCU9603R1ZJ
        BLUE DART LOGISTICS
        Total 500.00
      '''));

      expect(result.merchant.value, 'Blue Dart Logistics');
    });

    test('skips a line that is mostly digits', () {
      final ReceiptResult result = parser.parse(lines('''
        4829 1100 2831
        CITY PHARMACY
        Total 240.00
      '''));

      expect(result.merchant.value, 'City Pharmacy');
    });

    test('reports nothing rather than guessing from an amount-only receipt',
        () {
      final ReceiptResult result = parser.parse(lines('''
        123.00
        456.00
      '''));

      expect(result.merchant.hasValue, isFalse);
      expect(result.merchant.confidence, ReceiptConfidence.none);
    });
  });

  group('line items', () {
    test('reads items and their amounts', () {
      final ReceiptResult result = parser.parse(lines('''
        THE DAILY GRIND
        Flat White             180.00
        Almond Croissant       150.00
        Total                  330.00
      '''));

      expect(result.lineItems.length, 2);
      expect(result.lineItems.first.description, 'Flat White');
      expect(result.lineItems.first.amount, 180.00);
      expect(result.lineItems.last.description, 'Almond Croissant');
    });

    test('reads a quantity prefix', () {
      final ReceiptResult result = parser.parse(lines('''
        CAFE
        2 x Flat White         360.00
        Total                  360.00
      '''));

      expect(result.lineItems.single.quantity, 2);
      expect(result.lineItems.single.description, 'Flat White');
      expect(result.lineItems.single.display, '2 x Flat White');
    });

    test('excludes summary rows from the items', () {
      final ReceiptResult result = parser.parse(lines('''
        SHOP
        Notebook                60.00
        Subtotal                60.00
        CGST                     5.40
        Total                   65.40
        Cash                   100.00
        Change                  34.60
      '''));

      expect(
        result.lineItems.map((ReceiptLineItem i) => i.description),
        <String>['Notebook'],
      );
    });

    test('strips a dot leader between the name and the price', () {
      final ReceiptResult result = parser.parse(lines('''
        DINER
        Soup of the day ....... 120.00
      '''));

      expect(result.lineItems.single.description, 'Soup of the day');
    });
  });

  group('whole receipts', () {
    test('an Indian supermarket bill', () {
      final ReceiptResult result = parser.parse(lines('''
        GREEN LEAF SUPERMARKET
        No 42, 5th Cross, Indiranagar
        GSTIN: 29AABCU9603R1ZJ
        Bill No: 2024/0931
        Date: 14/03/2024  Time: 19:42
        ------------------------------
        Basmati Rice 5kg        450.00
        Amul Butter 500g        265.00
        Tata Salt 1kg            28.00
        ------------------------------
        Sub Total               743.00
        CGST 2.5%                18.58
        SGST 2.5%                18.58
        GRAND TOTAL             780.16
        Paid by UPI
        Thank you, visit again
      '''));

      expect(result.total.value, 780.16);
      expect(result.total.confidence, ReceiptConfidence.high);
      expect(result.merchant.value, 'Green Leaf Supermarket');
      expect(result.date.value, DateTime(2024, 3, 14));
      expect(result.lineItems.length, 3);
      expect(result.hasUsableTotal, isTrue);
      expect(result.fieldsToVerify, isEmpty);
    });

    test('a fuel receipt with no item lines', () {
      final ReceiptResult result = parser.parse(lines('''
        BHARAT PETROLEUM
        Outer Ring Road
        Date 02/09/2026
        Diesel              32.50 L
        Rate                 89.60
        Amount Payable     2912.00
      '''));

      expect(result.total.value, 2912.00);
      expect(result.merchant.value, 'Bharat Petroleum');
      expect(result.date.value, DateTime(2026, 9, 2));
    });

    test('a blurry scan that read almost nothing', () {
      final ReceiptResult result = parser.parse(lines('''
        ####
        ~ ~ ~
      '''));

      expect(result.isEmpty, isTrue);
      expect(result.hasUsableTotal, isFalse);
    });

    test('no lines at all is unreadable', () {
      final ReceiptResult result = parser.parse(<String>[]);
      expect(result.isEmpty, isTrue);
      expect(result.rawLineCount, 0);
    });

    test('blank lines are ignored, not counted', () {
      final ReceiptResult result =
          parser.parse(<String>['   ', 'SHOP NAME', '', 'Total 10.00']);
      expect(result.rawLineCount, 2);
    });

    test('parseText accepts one blob', () {
      final ReceiptResult result =
          parser.parseText('CITY CAFE\nTotal 250.00\n');
      expect(result.total.value, 250.00);
      expect(result.merchant.value, 'City Cafe');
    });
  });

  group('suggestions', () {
    final List<ExpenseCategory> categories = <ExpenseCategory>[
      _category('c1', 'Food'),
      _category('c2', 'Transport'),
      _category('c3', 'Health'),
    ];
    final List<PaymentMethod> methods = <PaymentMethod>[
      _method('p1', 'UPI'),
      _method('p2', 'Credit Card'),
    ];

    test('suggests Food for a supermarket', () {
      final ReceiptResult result =
          parser.parse(lines('GREEN LEAF SUPERMARKET\nTotal 780.16'));

      final ReceiptSuggestion<ExpenseCategory>? suggestion =
          suggester.suggestCategory(result: result, available: categories);

      expect(suggestion?.value.name, 'Food');
      expect(suggestion?.reason, contains('supermarket'));
    });

    test('suggests Transport for a fuel station', () {
      final ReceiptResult result =
          parser.parse(lines('HP PETROL PUMP\nAmount Payable 2000.00'));

      expect(
        suggester.suggestCategory(result: result, available: categories)?.value
            .name,
        'Transport',
      );
    });

    test('suggests nothing when nothing matches', () {
      final ReceiptResult result =
          parser.parse(lines('ZXQV ENTERPRISES\nTotal 100.00'));

      expect(
        suggester.suggestCategory(result: result, available: categories),
        isNull,
        reason: 'a wrong category is worse than none',
      );
    });

    test('suggests nothing when the matching category does not exist', () {
      final ReceiptResult result =
          parser.parse(lines('CITY PHARMACY\nTotal 100.00'));

      final ReceiptSuggestion<ExpenseCategory>? suggestion =
          suggester.suggestCategory(
        result: result,
        available: <ExpenseCategory>[_category('c1', 'Food')],
      );

      expect(suggestion, isNull);
    });

    test('suggests a payment method only on an explicit mention', () {
      final ReceiptResult withUpi =
          parser.parse(lines('SHOP\nPaid by UPI\nTotal 100.00'));
      final ReceiptResult without =
          parser.parse(lines('SHOP\nTotal 100.00'));

      expect(
        suggester.suggestPaymentMethod(result: withUpi, available: methods)
            ?.value.name,
        'UPI',
      );
      expect(
        suggester.suggestPaymentMethod(result: without, available: methods),
        isNull,
      );
    });

    test('describes the purchase from its items', () {
      final ReceiptResult result = parser.parse(lines('''
        CAFE
        Flat White      180.00
        Croissant       150.00
        Total           330.00
      '''));

      expect(suggester.describe(result), 'Flat White, Croissant');
    });

    test('a long item list is summarised, not dumped', () {
      final ReceiptResult result = parser.parse(lines('''
        SHOP
        Item One        10.00
        Item Two        10.00
        Item Three      10.00
        Item Four       10.00
        Item Five       10.00
      '''));

      expect(suggester.describe(result), endsWith('+2 more'));
    });

    test('nothing to describe when no items were read', () {
      final ReceiptResult result = parser.parse(lines('SHOP\nTotal 100.00'));
      expect(suggester.describe(result), isNull);
    });

    test('an empty category list never crashes', () {
      final ReceiptResult result =
          parser.parse(lines('SUPERMARKET\nTotal 100.00'));
      expect(
        suggester.suggestCategory(
          result: result,
          available: const <ExpenseCategory>[],
        ),
        isNull,
      );
    });
  });
}

ExpenseCategory _category(String id, String name) => ExpenseCategory(
      id: id,
      userId: 'u1',
      name: name,
      icon: 'category',
      color: '#78909C',
    );

PaymentMethod _method(String id, String name) =>
    PaymentMethod(id: id, userId: 'u1', name: name);
