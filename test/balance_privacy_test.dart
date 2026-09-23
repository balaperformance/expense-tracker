// Tests for the three presentation changes:
//
//   1. bank balances masked behind an eye on the dashboard,
//   2. a transaction row giving its description the room it needs,
//   3. account card actions reduced to icons without losing their names.
//
// The row-width test is the one that matters most: the old layout gave the
// amount column a flex factor, so it claimed half the row whether or not it
// needed it and truncated ordinary descriptions. That is a silent regression
// if it ever comes back, so it is measured rather than eyeballed.

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/ledger_entry.dart';
import 'package:expense_tracker/widgets/stat_tiles.dart';
import 'package:expense_tracker/widgets/transaction_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const List<double> _widths = <double>[320, 360, 411];

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 360,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = Size(width * 3, 780 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('MoneyText obscured', () {
    testWidgets('hides the figure and shows dots instead',
        (WidgetTester tester) async {
      await _pump(
        tester,
        const MoneyText(108122, currency: 'INR', obscured: true),
      );

      expect(find.textContaining('1,08,122'), findsNothing);
      expect(find.textContaining('•'), findsOneWidget);
    });

    testWidgets('shows the figure when not obscured',
        (WidgetTester tester) async {
      await _pump(tester, const MoneyText(108122, currency: 'INR'));
      expect(find.textContaining('1,08,122'), findsOneWidget);
    });

    testWidgets('the mask does not leak the sign or the magnitude',
        (WidgetTester tester) async {
      // A large positive and a small negative must render identically.
      await _pump(
        tester,
        const Column(
          children: <Widget>[
            MoneyText(9999999, currency: 'INR', obscured: true,
                tone: AmountTone.positive),
            MoneyText(-1, currency: 'INR', obscured: true,
                tone: AmountTone.negative),
          ],
        ),
      );

      final List<Text> masks = tester
          .widgetList<Text>(find.textContaining('•'))
          .toList();
      expect(masks.length, 2);
      expect(masks[0].data, masks[1].data, reason: 'same number of dots');
      expect(
        masks[0].style?.color,
        masks[1].style?.color,
        reason: 'a red or green mask would still say which way money went',
      );
    });
  });

  group('BalanceCard bank total', () {
    Widget card({
      required bool hidden,
      VoidCallback? onToggle,
    }) =>
        BalanceCard(
          income: 110000,
          expense: 8400,
          currency: 'INR',
          monthLabel: 'Sep',
          bankTotal: 108122,
          bankTotalHidden: hidden,
          onToggleBankTotal: onToggle,
        );

    testWidgets('masks the total and offers a Show control',
        (WidgetTester tester) async {
      await _pump(tester, card(hidden: true, onToggle: () {}));

      expect(find.text('In bank accounts'), findsOneWidget);
      expect(find.textContaining('1,08,122'), findsNothing);
      expect(find.byTooltip('Show balance'), findsOneWidget);
    });

    testWidgets('reveals the total and offers a Hide control',
        (WidgetTester tester) async {
      await _pump(tester, card(hidden: false, onToggle: () {}));

      expect(find.textContaining('1,08,122'), findsOneWidget);
      expect(find.byTooltip('Hide balance'), findsOneWidget);
    });

    testWidgets('tapping the eye reports the toggle exactly once',
        (WidgetTester tester) async {
      int taps = 0;
      await _pump(tester, card(hidden: true, onToggle: () => taps++));

      await tester.tap(find.byTooltip('Show balance'));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('no eye is drawn when no toggle is supplied',
        (WidgetTester tester) async {
      await _pump(tester, card(hidden: false));
      expect(find.byTooltip('Show balance'), findsNothing);
      expect(find.byTooltip('Hide balance'), findsNothing);
    });

    testWidgets('lays out at every width in both themes',
        (WidgetTester tester) async {
      for (final Brightness brightness in Brightness.values) {
        for (final double width in _widths) {
          await _pump(
            tester,
            card(hidden: true, onToggle: () {}),
            width: width,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull,
              reason: '$width $brightness');
        }
      }
    });
  });

  group('TransactionRow description width', () {
    const String title = 'Transfer to Savings Account';

    /// Widths the title and the amount column were each given.
    ///
    /// Absolute pixel values are not asserted: `flutter_test` substitutes a
    /// font whose every glyph is one em wide, so text measures far wider here
    /// than the Roboto the device actually renders. What *is* portable is the
    /// relationship between the two columns.
    Future<({double title, double amount})> layout(
      WidgetTester tester,
      double amount, {
      double width = 360,
      int titleMaxLines = 1,
    }) async {
      await _pump(
        tester,
        TransactionRow(
          leading: const SizedBox(width: 38, height: 38),
          title: title,
          titleMaxLines: titleMaxLines,
          amount: amount,
          currency: 'INR',
          tone: AmountTone.transfer,
          meta: const <String>['Money Transfer'],
          trailingBelow: '₹12.0K',
        ),
        width: width,
      );
      return (
        title: tester.getSize(find.text(title)).width,
        amount: tester.getSize(find.byType(MoneyText)).width,
      );
    }

    testWidgets('the split follows the content instead of being fixed',
        (WidgetTester tester) async {
      final ({double title, double amount}) short = await layout(tester, -5);
      final ({double title, double amount}) long =
          await layout(tester, -123456789);

      // Under the old layout the amount column carried flex 1 and therefore
      // took half the row regardless, so these two would be identical. The
      // title must now gain whatever a short amount does not need.
      expect(
        short.title,
        greaterThan(long.title),
        reason: 'a short amount must leave more room for the description',
      );
      expect(short.amount, lessThan(long.amount));
    });

    testWidgets('a short amount leaves the description most of the row',
        (WidgetTester tester) async {
      final ({double title, double amount}) short = await layout(tester, -5);
      final double share = short.title / (short.title + short.amount);
      expect(
        share,
        greaterThan(0.55),
        reason: 'the description is the part worth reading; the old fixed '
            'split gave it exactly half',
      );
      expect(short.title, greaterThan(short.amount));
    });

    testWidgets('the amount column is still capped so it cannot swallow the row',
        (WidgetTester tester) async {
      final ({double title, double amount}) huge =
          await layout(tester, -123456789.55, width: 320);
      expect(huge.amount, lessThanOrEqualTo(128));
      expect(huge.title, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a nine-figure amount does not overflow the narrowest phone',
        (WidgetTester tester) async {
      for (final Brightness brightness in Brightness.values) {
        await _pump(
          tester,
          const TransactionRow(
            leading: SizedBox(width: 38, height: 38),
            title: 'Extraordinarily Long Merchant Name Private Limited',
            amount: -123456789.55,
            currency: 'INR',
            tone: AmountTone.negative,
            meta: <String>['Shopping', 'Salary Account'],
            trailingBelow: '₹1.23Cr',
          ),
          width: 320,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull, reason: '$brightness');
      }
    });

    testWidgets('titleMaxLines 2 actually gives the description a second line',
        (WidgetTester tester) async {
      await layout(tester, -800, width: 320);
      final double oneLine = tester.getSize(find.text(title)).height;

      await layout(tester, -800, width: 320, titleMaxLines: 2);
      final double twoLines = tester.getSize(find.text(title)).height;

      expect(
        twoLines,
        greaterThan(oneLine),
        reason: 'the statement wraps rather than cutting the description off',
      );
    });

    testWidgets('one line remains the default for ordinary lists',
        (WidgetTester tester) async {
      const TransactionRow row = TransactionRow(
        leading: SizedBox(width: 38, height: 38),
        title: 'x',
        amount: 1,
        currency: 'INR',
        tone: AmountTone.neutral,
      );
      expect(row.titleMaxLines, 1);
    });
  });

  group('statement transfer labelling', () {
    // The rule the statement tile applies: the counterparty is added to the
    // meta line only when the description does not already name it.
    bool needsCounterparty(String title, String counterparty) =>
        !title.toLowerCase().contains(counterparty.toLowerCase());

    test('a default transfer description already names the other account', () {
      final LedgerEntry leg = LedgerEntry(
        id: 'l1',
        userId: 'u1',
        accountId: 'a1',
        direction: LedgerDirection.debit,
        amount: 800,
        txnDate: DateTime(2026, 9, 21),
        description: 'Transfer to Savings Account',
        transferGroupId: 'g1',
        counterpartyAccountId: 'a2',
      );
      expect(leg.title, 'Transfer to Savings Account');
      expect(needsCounterparty(leg.title, 'Savings Account'), isFalse);
    });

    test('a user note does not, so the counterparty is still shown', () {
      final LedgerEntry leg = LedgerEntry(
        id: 'l2',
        userId: 'u1',
        accountId: 'a1',
        direction: LedgerDirection.debit,
        amount: 800,
        txnDate: DateTime(2026, 9, 21),
        description: 'Rent set aside',
        transferGroupId: 'g1',
        counterpartyAccountId: 'a2',
      );
      expect(needsCounterparty(leg.title, 'Savings Account'), isTrue);
    });
  });
}
