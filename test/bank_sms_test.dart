/// Tests the path a pasted bank SMS takes to become a saved expense.
///
/// The steps are: message text -> [ParsedBankSms] -> [SmsExpenseDraft] ->
/// the [Expense] the review screen builds and saves. The first two are pure
/// and asserted directly; the last is asserted by driving the real review
/// screen against fake providers, so what is checked is what actually reaches
/// the repository.
///
/// Two properties matter more than any individual field:
///
///   * The parser never invents. Anything the message did not state arrives
///     null, and the review screen says so rather than filling a gap.
///   * Nothing is written until the user confirms. That is asserted against
///     the real screen, not by reading the code.
library;

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/ai_chat.dart';
import 'package:expense_tracker/models/bank_account.dart';
import 'package:expense_tracker/models/expense.dart';
import 'package:expense_tracker/models/expense_category.dart';
import 'package:expense_tracker/providers/auth_provider.dart';
import 'package:expense_tracker/providers/bank_account_provider.dart';
import 'package:expense_tracker/providers/category_provider.dart';
import 'package:expense_tracker/providers/expense_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/repositories/auth_repository.dart';
import 'package:expense_tracker/repositories/bank_account_repository.dart';
import 'package:expense_tracker/repositories/category_repository.dart';
import 'package:expense_tracker/repositories/expense_repository.dart';
import 'package:expense_tracker/repositories/ledger_repository.dart';
import 'package:expense_tracker/repositories/profile_repository.dart';
import 'package:expense_tracker/screens/expenses/sms_review_screen.dart';
import 'package:expense_tracker/services/ai/ai_chat_service.dart';
import 'package:expense_tracker/services/preferences_service.dart';
import 'package:expense_tracker/services/sms/bank_sms.dart';
import 'package:expense_tracker/services/sms/bank_sms_parser.dart';
import 'package:expense_tracker/services/sms/sms_account_matcher.dart';
import 'package:expense_tracker/services/sms/sms_category_assistant.dart';
import 'package:expense_tracker/services/sms/sms_expense_draft.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthClientOptions, GoTrueClient, SupabaseClient;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const BankSmsParser parser = BankSmsParser();
const SmsAccountMatcher matcher = SmsAccountMatcher();
const SmsDraftBuilder builder = SmsDraftBuilder();

/// A fixed "now", so two-digit years resolve the same way for ever.
final DateTime today = DateTime(2026, 9, 22);

/// The three messages from the brief, verbatim including the line breaks and
/// the trailing full stop on the third.
const String hdfcKeyMakers = 'Sent Rs.2900.00\n'
    'From HDFC Bank A/C *6459\n'
    'To CHENNAI KEY MAKERS\n'
    'On 19/09/26';

const String airtelSmall =
    'Rs. 30.00 debited from Airtel Payments Bank a/c Txn ID 663129068661 '
    'Bal:183.03';

const String hdfcPerson = 'Sent Rs.250.00\n'
    'From HDFC Bank A/C *6459\n'
    'To Mrs Malathi Ramu\n'
    'On 22/09/26.';

final List<ExpenseCategory> testCategories = <ExpenseCategory>[
  const ExpenseCategory(id: 'food', userId: 'u1', name: 'Food'),
  const ExpenseCategory(id: 'transport', userId: 'u1', name: 'Transport'),
  const ExpenseCategory(id: 'other', userId: 'u1', name: 'Other'),
];

final List<BankAccount> testAccounts = <BankAccount>[
  const BankAccount(
    id: 'acc-hdfc',
    userId: 'u1',
    bankName: 'HDFC Bank',
    nickname: 'HDFC Salary',
    last4: '6459',
  ),
  const BankAccount(
    id: 'acc-icici',
    userId: 'u1',
    bankName: 'ICICI Bank',
    nickname: 'ICICI Savings',
    last4: '1122',
  ),
];

ParsedBankSms read(String text) => parser.parse(text, now: today);

SmsExpenseDraft draftFor(
  String text, {
  List<BankAccount>? withAccounts,
  List<ExpenseCategory>? withCategories,
}) =>
    builder.build(
      sms: read(text),
      accounts: withAccounts ?? testAccounts,
      categories: withCategories ?? testCategories,
      today: today,
    );

void main() {
  // ---------------------------------------------------------------------
  // The three messages from the brief
  // ---------------------------------------------------------------------
  group('parses the provided examples', () {
    test('HDFC debit to a merchant, every field', () {
      final ParsedBankSms sms = read(hdfcKeyMakers);

      expect(sms.isUsable, isTrue);
      expect(sms.direction, SmsDirection.debit);
      expect(sms.amount, 2900.0);
      expect(sms.bankName, 'HDFC Bank');
      expect(sms.last4, '6459');
      expect(sms.counterparty, 'CHENNAI KEY MAKERS');
      expect(sms.date, DateTime(2026, 9, 19));
      expect(sms.reference, isNull);
      expect(sms.availableBalance, isNull);
    });

    test('Airtel debit: no payee, no date, but an id and a balance', () {
      final ParsedBankSms sms = read(airtelSmall);

      expect(sms.direction, SmsDirection.debit);
      expect(sms.amount, 30.0);
      expect(sms.bankName, 'Airtel Payments Bank');
      expect(sms.reference, '663129068661');
      expect(sms.availableBalance, 183.03);

      // Nothing invented for what the message does not say.
      expect(sms.counterparty, isNull);
      expect(sms.date, isNull);
      expect(sms.last4, isNull,
          reason: 'the twelve-digit txn id is not an account number');
    });

    test('HDFC debit to a person, with a trailing full stop', () {
      final ParsedBankSms sms = read(hdfcPerson);

      expect(sms.amount, 250.0);
      expect(sms.counterparty, 'Mrs Malathi Ramu',
          reason: 'the full stop is punctuation, not part of the name');
      expect(sms.date, DateTime(2026, 9, 22));
      expect(sms.last4, '6459');
    });
  });

  // ---------------------------------------------------------------------
  // Field-by-field, across the variations banks actually send
  // ---------------------------------------------------------------------
  group('amount', () {
    test('reads every currency spelling', () {
      for (final String text in <String>[
        'Rs.100 debited from HDFC Bank a/c',
        'Rs 100 debited from HDFC Bank a/c',
        'INR 100 debited from HDFC Bank a/c',
        'INR100 debited from HDFC Bank a/c',
        '₹100 debited from HDFC Bank a/c',
        '100 INR debited from HDFC Bank a/c',
      ]) {
        expect(read(text).amount, 100.0, reason: text);
      }
    });

    test('handles Indian digit grouping and paise', () {
      expect(read('Rs.1,23,456.78 debited from a/c').amount, 123456.78);
    });

    test('never mistakes the balance for the amount', () {
      // The balance is the larger, later figure in each of these.
      expect(read(airtelSmall).amount, 30.0);
      expect(
        read('Rs 250 spent at SHOP. Avl Bal Rs 9,000.00').amount,
        250.0,
      );
      expect(
        read('Rs 250 spent at SHOP. Available balance INR 9000').amount,
        250.0,
      );
    });

    test('reads an amount with no currency marker at all', () {
      expect(read('Your a/c is debited by 500 at SHOP').amount, 500.0);
    });

    test('rejects a figure that is not money', () {
      expect(read('Rs 0.00 debited from a/c').isUsable, isFalse);
    });
  });

  group('direction', () {
    test('every debit verb', () {
      for (final String verb in <String>[
        'debited', 'spent', 'paid', 'sent', 'withdrawn',
      ]) {
        expect(read('Rs 50 $verb from a/c').direction, SmsDirection.debit,
            reason: verb);
      }
    });

    test('every credit verb', () {
      for (final String verb in <String>[
        'credited', 'received', 'deposited', 'refunded',
      ]) {
        expect(read('Rs 50 $verb to a/c').direction, SmsDirection.credit,
            reason: verb);
      }
    });

    test('the leading verb decides, not a later incidental mention', () {
      // "debit card" appears after "credited" and must not flip it.
      final ParsedBankSms sms =
          read('Rs 500 credited to a/c linked to your debit card');
      expect(sms.direction, SmsDirection.credit);
    });

    test('a message with no verb is not a transaction', () {
      expect(read('Your balance is Rs 500').isUsable, isFalse);
    });
  });

  group('bank and account digits', () {
    test('reads the bank out of the clause before a/c', () {
      expect(read(hdfcKeyMakers).bankName, 'HDFC Bank');
      expect(read(airtelSmall).bankName, 'Airtel Payments Bank');
      expect(
        read('Rs 10 debited from State Bank of India a/c XX1234').bankName,
        'State Bank of India',
        reason: 'four words back covers the longest names in use',
      );
    });

    test('reads a bank named without any a/c', () {
      expect(read('Rs 10 spent using Kotak Bank card').bankName, 'Kotak Bank');
    });

    test('reads masked digits in each shape', () {
      for (final String clause in <String>[
        'A/C *6459',
        'a/c XX6459',
        'A/c no. XXXXXX6459',
        'ac 6459',
        'account no: 6459',
      ]) {
        expect(read('Rs 10 debited from HDFC Bank $clause').last4, '6459',
            reason: clause);
      }
    });

    test('reads a card ending instead', () {
      expect(
        read('Rs 10 spent on card ending 4821 at SHOP').last4,
        '4821',
      );
    });

    test('an "ac" inside a merchant name does not hide the real account', () {
      final ParsedBankSms sms = read(
        'Rs 100 spent at AC SERVICE from HDFC Bank a/c *6459 on 19/09/26',
      );
      expect(sms.bankName, 'HDFC Bank');
      expect(sms.last4, '6459');
    });

    test('refuses to read a long number as masked digits', () {
      expect(read(airtelSmall).last4, isNull);
      expect(
        read('Rs 10 debited from a/c 123456789012 at SHOP').last4,
        isNull,
      );
    });
  });

  group('payee', () {
    test('reads a merchant and a person', () {
      expect(read(hdfcKeyMakers).counterparty, 'CHENNAI KEY MAKERS');
      expect(read(hdfcPerson).counterparty, 'Mrs Malathi Ramu');
    });

    test('reads an "at MERCHANT" message', () {
      expect(
        read('INR 1,250.50 spent at AMAZON RETAIL on 12-Mar-2026').counterparty,
        'AMAZON RETAIL',
      );
    });

    test('stops at the next field rather than swallowing it', () {
      expect(
        read('Rs 10 sent to BLUE DART Ref no 8891 Bal 200').counterparty,
        'BLUE DART',
      );
    });

    test('does not cut a merchant whose own name contains "on"', () {
      expect(
        read('Rs 10 sent to SALON ON WHEELS on 19/09/26').counterparty,
        'SALON ON WHEELS',
        reason: 'only "on" followed by a date ends the name',
      );
    });

    test('reports nothing when the message names nobody', () {
      expect(read(airtelSmall).counterparty, isNull);
    });
  });

  group('date', () {
    test('reads the common formats', () {
      const Map<String, String> cases = <String, String>{
        '19/09/26': '2026-09-19',
        '19-09-2026': '2026-09-19',
        '19-Sep-26': '2026-09-19',
        '19 Sep 2026': '2026-09-19',
        '2026-09-19': '2026-09-19',
        '19.09.26': '2026-09-19',
      };

      cases.forEach((String written, String expected) {
        final ParsedBankSms sms =
            read('Rs 10 sent to SHOP on $written');
        expect(
          sms.date?.toIso8601String().substring(0, 10),
          expected,
          reason: written,
        );
      });
    });

    test('a two-digit year that cannot be real is reported as no date', () {
      // "99" is 2099 read naively and 1999 rolled back. A bank alert is
      // neither, so the honest answer is that the date could not be read.
      expect(read('Rs 10 sent to SHOP on 19/09/99').date, isNull);
    });

    test('a two-digit year just ahead is still accepted', () {
      // Allowing next year absorbs a device clock that is behind, without
      // opening the door to 2099.
      expect(read('Rs 10 sent to SHOP on 19/09/27').date, DateTime(2027, 9, 19));
    });

    test('rejects a date that does not exist', () {
      expect(read('Rs 10 sent to SHOP on 31/02/26').date, isNull);
    });

    test('reports nothing rather than guessing at today', () {
      expect(read(airtelSmall).date, isNull);
    });
  });

  group('reference', () {
    test('reads the labels banks use', () {
      for (final String label in <String>[
        'Txn ID', 'txn id', 'Ref no', 'Reference No.', 'UTR', 'RRN',
      ]) {
        expect(
          read('Rs 10 debited from a/c $label 663129068661').reference,
          '663129068661',
          reason: label,
        );
      }
    });

    test('reports nothing when there is no id', () {
      expect(read(hdfcKeyMakers).reference, isNull);
    });
  });

  group('unreadable input', () {
    test('ordinary text is not a transaction', () {
      for (final String text in <String>[
        '',
        '   ',
        'hello mum how are you',
        'Your OTP is 123456. Do not share it.',
      ]) {
        expect(read(text).isUsable, isFalse, reason: text);
      }
    });

    test('capitalisation and spacing do not matter', () {
      final ParsedBankSms shouted =
          read('SENT   RS.2900.00\n\n\nFROM HDFC BANK A/C *6459\nTO CHENNAI '
              'KEY MAKERS\nON 19/09/26');
      expect(shouted.amount, 2900.0);
      expect(shouted.last4, '6459');
      expect(shouted.counterparty, 'CHENNAI KEY MAKERS');
      expect(shouted.date, DateTime(2026, 9, 19));
    });

    test('a very long paste is capped rather than rejected outright', () {
      final String padded = '$hdfcKeyMakers ${'x' * 5000}';
      expect(read(padded).amount, 2900.0);
    });
  });

  // ---------------------------------------------------------------------
  // Matching the user's own accounts
  // ---------------------------------------------------------------------
  group('bank account matching', () {
    test('matches on the last four digits', () {
      final SmsAccountMatch? match =
          matcher.match(sms: read(hdfcKeyMakers), accounts: testAccounts);

      expect(match, isNotNull);
      expect(match!.account.id, 'acc-hdfc');
      expect(match.strength, SmsMatchStrength.exact);
      expect(match.reason, contains('6459'));
    });

    test('does not match when the digits belong to no account', () {
      final ParsedBankSms sms =
          read('Rs 10 debited from HDFC Bank A/C *9999');
      expect(
        matcher.match(sms: sms, accounts: testAccounts),
        isNull,
        reason: 'a different HDFC account is a different account, not a near '
            'miss',
      );
    });

    test('falls back to the bank name when no digits were read', () {
      final ParsedBankSms sms = read('Rs 10 debited from HDFC Bank');
      final SmsAccountMatch? match =
          matcher.match(sms: sms, accounts: testAccounts);

      expect(match?.account.id, 'acc-hdfc');
      expect(match?.strength, SmsMatchStrength.likely);
    });

    test('refuses to guess between two accounts at the same bank', () {
      final List<BankAccount> twoHdfc = <BankAccount>[
        const BankAccount(
          id: 'a',
          userId: 'u1',
          bankName: 'HDFC Bank',
          nickname: 'One',
        ),
        const BankAccount(
          id: 'b',
          userId: 'u1',
          bankName: 'HDFC Bank',
          nickname: 'Two',
        ),
      ];
      expect(
        matcher.match(
          sms: read('Rs 10 debited from HDFC Bank'),
          accounts: twoHdfc,
        ),
        isNull,
      );
    });

    test('generic words alone never match', () {
      // Every account is "… Bank", so "Bank" must identify nothing.
      final ParsedBankSms sms = read('Rs 10 debited from Yes Bank');
      expect(matcher.match(sms: sms, accounts: testAccounts), isNull);
    });

    test('an unknown bank produces no match and no account', () {
      final ParsedBankSms sms = read(airtelSmall);
      expect(matcher.match(sms: sms, accounts: testAccounts), isNull);
      expect(draftFor(airtelSmall).accountMatched, isFalse);
    });

    test('ignores closed accounts', () {
      final List<BankAccount> closed = <BankAccount>[
        const BankAccount(
          id: 'old',
          userId: 'u1',
          bankName: 'HDFC Bank',
          nickname: 'Closed',
          last4: '6459',
          isActive: false,
        ),
      ];
      expect(
        matcher.match(sms: read(hdfcKeyMakers), accounts: closed),
        isNull,
      );
    });
  });

  // ---------------------------------------------------------------------
  // Draft building
  // ---------------------------------------------------------------------
  group('draft', () {
    test('carries the parsed values and the matched account', () {
      final SmsExpenseDraft draft = draftFor(hdfcKeyMakers);

      expect(draft.amount, 2900.0);
      expect(draft.merchant, 'CHENNAI KEY MAKERS');
      expect(draft.date, DateTime(2026, 9, 19));
      expect(draft.bankAccountId, 'acc-hdfc');
      expect(draft.reference, isNull);
    });

    test('falls back to today only when the message gave no date', () {
      expect(draftFor(airtelSmall).date, today);
      expect(draftFor(hdfcKeyMakers).date, DateTime(2026, 9, 19));
    });

    test('uses a keyword category when the payee is recognisable', () {
      final SmsExpenseDraft draft =
          draftFor('Rs 800 spent at INDIAN OIL PETROL PUMP');

      expect(draft.categoryId, 'transport');
      expect(draft.categorySource, SmsCategorySource.keyword);
      expect(draft.categoryReason, isNotNull);
    });

    test('falls back to Other when nothing is recognisable', () {
      final SmsExpenseDraft draft = draftFor(hdfcKeyMakers);

      expect(draft.categoryId, 'other');
      expect(draft.categorySource, SmsCategorySource.fallback);
      expect(draft.categoryReason, isNull,
          reason: 'there is no reason to show, because nothing matched');
    });

    test('accepts the other spellings of a catch-all', () {
      for (final String name in <String>[
        'Other', 'Others', 'Miscellaneous', 'Uncategorised',
      ]) {
        final List<ExpenseCategory> only = <ExpenseCategory>[
          ExpenseCategory(id: 'x', userId: 'u1', name: name),
        ];
        expect(
          SmsDraftBuilder.fallbackCategory(only)?.id,
          'x',
          reason: name,
        );
      }
    });

    test('leaves the category empty when the user has no catch-all', () {
      final List<ExpenseCategory> noCatchAll = <ExpenseCategory>[
        const ExpenseCategory(id: 'food', userId: 'u1', name: 'Food'),
      ];
      final SmsExpenseDraft draft =
          draftFor(hdfcKeyMakers, withCategories: noCatchAll);

      expect(draft.categoryId, isNull,
          reason: 'filing it under whatever came first would be a guess');
      expect(draft.categorySource, SmsCategorySource.none);
    });

    test('only the payee feeds the category, never the whole message', () {
      // "SCHOOL" appears in the bank clause, not the payee. If the whole
      // message were searched this would be filed under Education.
      final SmsExpenseDraft draft = draftFor(
        'Rs 500 debited from SCHOOL ROAD BRANCH Bank a/c XX1122 to BIG BAZAAR',
        withCategories: <ExpenseCategory>[
          ...testCategories,
          const ExpenseCategory(id: 'edu', userId: 'u1', name: 'Education'),
        ],
      );
      expect(draft.categoryId, isNot('edu'));
    });

    test('carries the reference so a repeat can be spotted', () {
      expect(draftFor(airtelSmall).reference, '663129068661');
    });
  });

  // ---------------------------------------------------------------------
  // The optional AI step
  // ---------------------------------------------------------------------
  group('assistant category suggestion', () {
    test('is not consulted when the keywords already matched', () {
      final _RecordingClassifier ai = _RecordingClassifier();
      final SmsExpenseDraft draft =
          draftFor('Rs 800 spent at INDIAN OIL PETROL PUMP');

      expect(
        SmsCategoryAssistant.shouldAsk(draft: draft, categories: testCategories),
        isFalse,
      );
      expect(ai.asked, isEmpty);
    });

    test('is not consulted when the message named no payee', () {
      expect(
        SmsCategoryAssistant.shouldAsk(
          draft: draftFor(airtelSmall),
          categories: testCategories,
        ),
        isFalse,
      );
    });

    test('sends only the payee, and applies a valid answer', () async {
      final _RecordingClassifier ai = _RecordingClassifier(answer: 'Food');
      final SmsExpenseDraft refined = await SmsCategoryAssistant(ai).refine(
        draft: draftFor(hdfcKeyMakers),
        categories: testCategories,
      );

      expect(ai.asked, <String>['CHENNAI KEY MAKERS']);
      expect(refined.categoryId, 'food');
      expect(refined.categorySource, SmsCategorySource.assistant);

      // Nothing else from the message reached the classifier.
      for (final String sent in ai.asked) {
        expect(sent, isNot(contains('2900')));
        expect(sent, isNot(contains('6459')));
        expect(sent, isNot(contains('HDFC')));
      }
    });

    test('discards an answer that is not one of the user\'s categories',
        () async {
      final _RecordingClassifier ai = _RecordingClassifier(answer: 'Locksmiths');
      final SmsExpenseDraft refined = await SmsCategoryAssistant(ai).refine(
        draft: draftFor(hdfcKeyMakers),
        categories: testCategories,
      );

      expect(refined.categoryId, 'other');
      expect(refined.categorySource, SmsCategorySource.fallback);
    });

    test('an unavailable classifier leaves the fallback in place', () async {
      final _RecordingClassifier ai = _RecordingClassifier(answer: null);
      final SmsExpenseDraft refined = await SmsCategoryAssistant(ai).refine(
        draft: draftFor(hdfcKeyMakers),
        categories: testCategories,
      );

      expect(refined.categoryId, 'other');
      expect(refined.categorySource, SmsCategorySource.fallback);
    });

    test('a throwing classifier never breaks the import', () async {
      final _RecordingClassifier ai = _RecordingClassifier(throws: true);
      final SmsExpenseDraft refined = await SmsCategoryAssistant(ai).refine(
        draft: draftFor(hdfcKeyMakers),
        categories: testCategories,
      );

      expect(refined.categoryId, 'other');
      expect(refined.categorySource, SmsCategorySource.fallback);
    });
  });

  // ---------------------------------------------------------------------
  // The review screen: nothing is written until it is confirmed
  // ---------------------------------------------------------------------
  group('review screen', () {
    testWidgets('shows the parsed values and writes nothing on open',
        (WidgetTester tester) async {
      final _Harness harness = await _pumpReview(tester, hdfcKeyMakers);

      expect(find.text('CHENNAI KEY MAKERS'), findsOneWidget);
      expect(find.text('2900'), findsOneWidget);
      // The matched account is named with its digits, which is how the
      // last-4 is both shown and corrected.
      expect(find.textContaining('6459'), findsWidgets);

      expect(harness.expenses.created, isEmpty,
          reason: 'opening a review must never write');
    });

    testWidgets('cancelling writes nothing', (WidgetTester tester) async {
      final _Harness harness = await _pumpReview(tester, hdfcKeyMakers);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(harness.expenses.created, isEmpty);
    });

    testWidgets('confirming saves one ordinary expense',
        (WidgetTester tester) async {
      final _Harness harness = await _pumpReview(tester, hdfcKeyMakers);

      await tester.tap(find.text('Add expense'));
      await tester.pumpAndSettle();

      expect(harness.expenses.created, hasLength(1));
      final Expense saved = harness.expenses.created.single;

      expect(saved.amount, 2900.0);
      expect(saved.merchant, 'CHENNAI KEY MAKERS');
      expect(saved.expenseDate, DateTime(2026, 9, 19));
      expect(saved.categoryId, 'other');
      expect(saved.bankAccountId, 'acc-hdfc');
    });

    testWidgets('edits made on the screen are what get saved',
        (WidgetTester tester) async {
      final _Harness harness = await _pumpReview(tester, hdfcKeyMakers);

      await tester.enterText(find.byType(TextField).first, '3100');
      // Amount, merchant, description — in that order down the screen.
      await tester.enterText(
        find.byType(TextField).at(1),
        'Chennai Key Makers Pvt Ltd',
      );
      // The category chips sit below the fold on a test-sized screen. The
      // scrollable is named explicitly because the chip rows are scrollables
      // of their own and an unqualified finder matches several.
      await tester.scrollUntilVisible(
        find.text('Food'),
        120,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ).first,
      );
      await tester.tap(find.text('Food'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add expense'));
      await tester.pumpAndSettle();

      final Expense saved = harness.expenses.created.single;
      expect(saved.amount, 3100.0);
      expect(saved.merchant, 'Chennai Key Makers Pvt Ltd');
      expect(saved.categoryId, 'food');
    });

    testWidgets('the reference is saved so the message can be recognised again',
        (WidgetTester tester) async {
      final _Harness harness = await _pumpReview(tester, airtelSmall);

      await tester.tap(find.text('Add expense'));
      await tester.pumpAndSettle();

      final Expense saved = harness.expenses.created.single;
      expect(saved.notes, contains('663129068661'));
      expect(saved.notes, SmsReferenceNote.forReference('663129068661'));
    });

    testWidgets('an unmatched account is stated, not guessed',
        (WidgetTester tester) async {
      await _pumpReview(tester, airtelSmall);

      expect(find.textContaining('not one of your accounts'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------
  // Duplicate protection
  // ---------------------------------------------------------------------
  group('duplicate protection', () {
    testWidgets('warns instead of saving on the first press',
        (WidgetTester tester) async {
      final _Harness harness = await _pumpReview(
        tester,
        airtelSmall,
        duplicate: _existingExpense(),
      );

      expect(find.textContaining('already been added'), findsOneWidget);

      await tester.tap(find.text('Add anyway'));
      await tester.pumpAndSettle();

      expect(harness.expenses.created, isEmpty,
          reason: 'the press that acknowledges a warning must not also save');

      // The second press is a deliberate decision, and goes through.
      await tester.tap(find.text('Add expense'));
      await tester.pumpAndSettle();
      expect(harness.expenses.created, hasLength(1));
    });

    testWidgets('looks the transaction up by its reference',
        (WidgetTester tester) async {
      final _Harness harness = await _pumpReview(
        tester,
        airtelSmall,
        duplicate: _existingExpense(),
      );

      expect(harness.expenses.lookups, isNotEmpty);
      expect(harness.expenses.lookups.first['reference'], '663129068661');
      expect(harness.expenses.lookups.first['amount'], 30.0);
    });

    testWidgets('a message with no reference is still checked by shape',
        (WidgetTester tester) async {
      final _Harness harness = await _pumpReview(
        tester,
        hdfcKeyMakers,
        duplicate: _existingExpense(amount: 2900),
      );

      expect(harness.expenses.lookups.first['reference'], isNull);
      expect(harness.expenses.lookups.first['bankAccountId'], 'acc-hdfc');
      expect(
        find.textContaining('same account'),
        findsOneWidget,
        reason: 'a resemblance is worded differently from a proven repeat',
      );
    });

    testWidgets('no warning when nothing matches', (WidgetTester tester) async {
      await _pumpReview(tester, hdfcKeyMakers);

      expect(find.textContaining('already been added'), findsNothing);
      expect(find.text('Add expense'), findsOneWidget);
    });

    test('the note format is the one the lookup searches for', () {
      // These two drifting apart would silently disable duplicate detection,
      // so they are pinned to each other rather than to a literal.
      expect(
        SmsReferenceNote.forReference('663129068661'),
        contains(SmsReferenceNote.searchTerm('663129068661')),
      );
    });
  });

  // ---------------------------------------------------------------------
  // The expense that results is an ordinary one
  // ---------------------------------------------------------------------
  group('ledger and balance behaviour', () {
    testWidgets('an imported expense is shaped exactly like a typed one',
        (WidgetTester tester) async {
      final _Harness harness = await _pumpReview(tester, hdfcKeyMakers);

      await tester.tap(find.text('Add expense'));
      await tester.pumpAndSettle();

      final Expense saved = harness.expenses.created.single;

      // A positive expense against a bank account: the repository turns this
      // into exactly one debit, the same as any other expense. Nothing here
      // is income and nothing is a transfer.
      expect(saved.amount, greaterThan(0));
      expect(saved.bankAccountId, isNotNull);
      expect(saved.id, isEmpty, reason: 'the database assigns the id');
      expect(saved.userId, 'u1');
      expect(harness.expenses.created, hasLength(1),
          reason: 'one confirmation writes one row');
    });

    testWidgets('an unmatched message records cash and moves no balance',
        (WidgetTester tester) async {
      final _Harness harness = await _pumpReview(tester, airtelSmall);

      await tester.tap(find.text('Add expense'));
      await tester.pumpAndSettle();

      expect(
        harness.expenses.created.single.bankAccountId,
        isNull,
        reason: 'cash is the safe default: no account, no ledger movement, '
            'no balance changed',
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

Expense _existingExpense({double amount = 30}) => Expense(
      id: 'existing-1',
      userId: 'u1',
      amount: amount,
      expenseDate: today,
      description: 'Already recorded',
    );

class _Harness {
  const _Harness(this.expenses);

  final _FakeExpenseProvider expenses;
}

/// Pumps the real review screen over fake providers.
Future<_Harness> _pumpReview(
  WidgetTester tester,
  String message, {
  Expense? duplicate,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final PreferencesService preferences = await PreferencesService.create();
  // The repositories under these fakes are never called, but constructing
  // them needs a client. Token auto-refresh is off because it schedules a
  // periodic timer that would outlive the widget tree.
  final SupabaseClient client = SupabaseClient(
    'http://localhost:54321',
    'test-anon-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );

  final _FakeExpenseProvider expenses =
      _FakeExpenseProvider(client, duplicate: duplicate);

  final ParsedBankSms sms = read(message);
  final SmsExpenseDraft draft = draftFor(message);

  await tester.pumpWidget(
    MultiProvider(
      providers: <ChangeNotifierProvider<dynamic>>[
        ChangeNotifierProvider<SettingsProvider>.value(
          value: SettingsProvider(
            repository: ProfileRepository(client),
            preferences: preferences,
          ),
        ),
        ChangeNotifierProvider<CategoryProvider>.value(
          value: _FakeCategoryProvider(client),
        ),
        ChangeNotifierProvider<BankAccountProvider>.value(
          value: _FakeBankAccountProvider(client),
        ),
        ChangeNotifierProvider<ExpenseProvider>.value(value: expenses),
        ChangeNotifierProvider<AuthProvider>.value(value: _FakeAuth()),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: SmsReviewScreen(sms: sms, draft: draft),
      ),
    ),
  );
  await tester.pumpAndSettle();

  return _Harness(expenses);
}

class _FakeExpenseProvider extends ExpenseProvider {
  _FakeExpenseProvider(SupabaseClient client, {this.duplicate})
      : super(ExpenseRepository(client));

  final Expense? duplicate;

  /// Everything the screen tried to write. Empty is the assertion that
  /// matters most in this file.
  final List<Expense> created = <Expense>[];

  /// Arguments of every duplicate lookup, so the checks can be asserted.
  final List<Map<String, Object?>> lookups = <Map<String, Object?>>[];

  @override
  Future<bool> create(Expense expense) async {
    created.add(expense);
    return true;
  }

  @override
  Future<Expense?> findPossibleDuplicate({
    required double amount,
    required DateTime date,
    String? reference,
    String? bankAccountId,
  }) async {
    lookups.add(<String, Object?>{
      'amount': amount,
      'date': date,
      'reference': reference,
      'bankAccountId': bankAccountId,
    });
    return duplicate;
  }
}

class _FakeCategoryProvider extends CategoryProvider {
  _FakeCategoryProvider(SupabaseClient client)
      : super(CategoryRepository(client));

  @override
  List<ExpenseCategory> get categories => testCategories;
}

class _FakeBankAccountProvider extends BankAccountProvider {
  _FakeBankAccountProvider(SupabaseClient client)
      : super(
          accounts: BankAccountRepository(client),
          ledger: LedgerRepository(client),
        );

  @override
  bool get available => true;

  @override
  List<BankAccount> get accounts => testAccounts;
}

class _FakeAuth extends AuthProvider {
  _FakeAuth() : super(AuthRepository(GoTrueClient(autoRefreshToken: false)));

  @override
  String? get userId => 'u1';
}

/// Records what the classifier was asked and answers on script.
class _RecordingClassifier implements AiChatService {
  _RecordingClassifier({this.answer, this.throws = false});

  final String? answer;
  final bool throws;
  final List<String> asked = <String>[];

  @override
  Future<String?> suggestCategory({required String merchant}) async {
    asked.add(merchant);
    if (throws) throw StateError('classifier unavailable');
    return answer;
  }

  @override
  Future<AiChatReply> send({
    required String message,
    required List<ChatHistoryTurn> history,
    required DateTime today,
  }) async =>
      throw UnimplementedError('SMS import never chats');

  @override
  Future<AiChatReply> confirm({
    required PendingAction action,
    required DateTime today,
  }) async =>
      throw UnimplementedError('SMS import never confirms a chat action');
}
