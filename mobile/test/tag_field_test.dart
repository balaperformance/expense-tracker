// Tags on the expense and income forms (migration 006): the naming rules
// ported from the web app's domain/tags.ts, and the shared tag field the
// forms and the statement import's row editor use. Every name is invented.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/models/tag.dart';
import 'package:expense_tracker/models/tag_rules.dart';
import 'package:expense_tracker/widgets/common/app_fields.dart';
import 'package:expense_tracker/widgets/tag_field.dart';

const List<Tag> known = <Tag>[
  Tag(id: 't1', name: 'CarSpending'),
  Tag(id: 't2', name: 'family'),
  Tag(id: 't3', name: 'office'),
  Tag(id: 't4', name: 'coffee'),
];

void main() {
  group('tag rules', () {
    test('a typed tag is stored without #, with single spaces', () {
      expect(TagRules.normalise('  ##Road   trip '), 'Road trip');
      expect(TagRules.key('#Road Trip'), 'road trip');
    });

    test('adding reuses a known spelling and ignores repeats and blanks', () {
      expect(TagRules.add(<String>[], 'carspending', known), <String>['CarSpending']);
      expect(TagRules.add(<String>['family'], '#FAMILY', known), <String>['family']);
      expect(TagRules.add(<String>['family'], '   ', known), <String>['family']);
      expect(TagRules.add(<String>[], 'x' * 50).single, hasLength(TagRules.maxLength));
      final List<String> full = <String>[for (int i = 0; i < 20; i++) 't$i'];
      expect(TagRules.add(full, 'one more'), full, reason: 'twenty is the limit');
    });

    test('removing ignores case', () {
      expect(TagRules.remove(<String>['family', 'office'], 'FAMILY'), <String>['office']);
    });

    test('commas finish tags; what follows is still being typed', () {
      final ({List<String> done, String rest}) split = TagRules.splitTyped('food, #office,, tri');
      expect(split.done, <String>['food', 'office']);
      expect(split.rest, ' tri');
    });

    test('suggestions narrow as you type, those starting with it first', () {
      expect(TagRules.suggestions(known, <String>['family'], '').map((Tag t) => t.name),
          <String>['CarSpending', 'coffee', 'office'],
          reason: 'everything not chosen when nothing is typed');
      expect(TagRules.suggestions(known, const <String>[], 'f').map((Tag t) => t.name),
          <String>['family', 'coffee', 'office']);
    });

    test('a brand-new tag is offered only when nothing matches', () {
      expect(TagRules.newTagFor(known, const <String>[], 'Road trip'), 'Road trip');
      expect(TagRules.newTagFor(known, const <String>[], 'FAMILY'), isNull);
      expect(TagRules.newTagFor(known, <String>['Road trip'], 'road trip'), isNull);
      expect(TagRules.newTagFor(known, const <String>[], ' # '), isNull);
    });

    test('a row\'s tag ids become names in their order', () {
      expect(TagRules.names(known, <String>['t3', 'gone', 't1']), <String>['office', 'CarSpending']);
    });

    test('a save counts what is typed but not confirmed', () {
      expect(TagField.withDraft(<String>['family'], 'office, carspending', known),
          <String>['family', 'office', 'CarSpending']);
      expect(TagField.withDraft(<String>['family'], ''), <String>['family']);
    });
  });

  group('tag field', () {
    Future<List<String>> pump(
      WidgetTester tester, {
      List<String> initial = const <String>[],
      List<Tag> knownTags = known,
      double width = 360,
    }) async {
      tester.view.physicalSize = Size(width * 2, 720 * 2);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      List<String> tags = List<String>.of(initial);
      final TextEditingController draft = TextEditingController();
      addTearDown(draft.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: StatefulBuilder(
            // Scrolls, as every form holding the field does.
            builder: (BuildContext context, StateSetter setState) =>
                SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: TagField(
                tags: tags,
                draft: draft,
                known: knownTags,
                onChanged: (List<String> next) => setState(() => tags = next),
              ),
            ),
          ),
        ),
      ));
      return tags;
    }

    List<String> chips(WidgetTester tester) => tester
        .widgetList<InputChip>(find.byType(InputChip))
        .map((InputChip c) => (c.label as Text).data!)
        .toList();

    testWidgets('a comma or Done adds the tag, in the known spelling',
        (WidgetTester tester) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'carspending,');
      await tester.pump();
      expect(chips(tester), <String>['#CarSpending']);
      expect(find.widgetWithText(TextField, 'carspending'), findsNothing,
          reason: 'the field is cleared for the next one');

      await tester.enterText(find.byType(TextField), 'Road trip');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(chips(tester), <String>['#CarSpending', '#Road trip']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('existing tags are offered and narrowed; a new one too',
        (WidgetTester tester) async {
      await pump(tester, initial: <String>['family']);
      expect(find.widgetWithText(AppChoiceChip, 'office'), findsOneWidget);
      expect(find.widgetWithText(AppChoiceChip, 'family'), findsNothing,
          reason: 'already chosen');

      await tester.enterText(find.byType(TextField), 'off');
      await tester.pump();
      expect(find.widgetWithText(AppChoiceChip, 'office'), findsOneWidget);
      expect(find.widgetWithText(AppChoiceChip, 'coffee'), findsOneWidget);
      expect(find.widgetWithText(AppChoiceChip, 'CarSpending'), findsNothing);
      expect(find.widgetWithText(AppChoiceChip, 'off'), findsOneWidget,
          reason: 'offered as a brand-new tag');

      await tester.tap(find.widgetWithText(AppChoiceChip, 'office'));
      await tester.pump();
      expect(chips(tester), <String>['#family', '#office']);
    });

    testWidgets('a chosen tag is removed from its chip',
        (WidgetTester tester) async {
      await pump(tester, initial: <String>['family', 'office']);
      await tester.tap(find.byTooltip('Remove tag family'));
      await tester.pump();
      expect(chips(tester), <String>['#office']);
    });

    testWidgets('twenty tags is the limit, and nothing overflows at 320 dp',
        (WidgetTester tester) async {
      await pump(
        tester,
        initial: <String>[for (int i = 0; i < 20; i++) 'a-rather-long-tag-$i'],
        width: 320,
      );
      expect(find.text('Tag limit reached'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(find.byType(AppChoiceChip), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
