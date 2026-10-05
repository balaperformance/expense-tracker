// Assistant reply formatting.
//
// A port of the web app's ui/src/lib/markdown.test.ts, so a reply is read the
// same way on both, plus the edge cases the phone's renderer leans on.

import 'package:expense_tracker/core/utils/markdown.dart';
import 'package:flutter_test/flutter_test.dart';

T _as<T>(Object? value) {
  expect(value, isA<T>());
  return value as T;
}

void main() {
  group('assistant reply formatting (parity with the web)', () {
    test('keeps a plain answer a plain paragraph', () {
      expect(parseMarkdown('You spent ₹4,200 on food this month.'), <MdBlock>[
        const MdParagraph(<List<MdInline>>[
          <MdInline>[MdText('You spent ₹4,200 on food this month.')],
        ]),
      ]);
    });

    test('reads the list the assistant sends for recent expenses', () {
      final List<MdBlock> blocks = parseMarkdown(
        'Here are your recent expenses:\n\n'
        '- **₹8,500** for Food on 3 Oct (Savings Account)\n'
        '- **₹25,000** for Grocery on 3 Oct',
      );
      expect(blocks.map((MdBlock b) => b.runtimeType), <Type>[MdParagraph, MdList]);
      final MdList list = _as<MdList>(blocks[1]);
      expect(list.ordered, isFalse);
      expect(list.items, hasLength(2));
      expect(list.items[0].inlines[0], const MdStrong(<MdInline>[MdText('₹8,500')]));
    });

    test('numbers steps from where the reply starts them, and nests a sub-point', () {
      final List<MdBlock> blocks =
          parseMarkdown('3. Open Accounts\n4. Tap Transfer\n   - choose Cash');
      expect(blocks, hasLength(1));
      final MdList list = _as<MdList>(blocks[0]);
      expect(list.ordered, isTrue);
      expect(list.start, 3);
      expect(list.items.map((MdListItem i) => i.depth), <int>[0, 0, 1]);
    });

    test('reads headings and a table with aligned columns', () {
      final List<MdBlock> blocks = parseMarkdown(
        '### By month\n\n'
        '| Month | Spent |\n'
        '|---|---:|\n'
        '| Aug | ₹42,100 |\n'
        '| Sep | **₹57,300** |\n\n'
        'September was higher.',
      );
      expect(
        blocks.map((MdBlock b) => b.runtimeType),
        <Type>[MdHeading, MdTable, MdParagraph],
      );
      final MdTable table = _as<MdTable>(blocks[1]);
      expect(table.align, <MdAlign>[MdAlign.left, MdAlign.right]);
      expect(table.rows, hasLength(2));
      expect(table.rows[1][1], <MdInline>[
        const MdStrong(<MdInline>[MdText('₹57,300')]),
      ]);
    });

    test('leaves what it does not recognise as the text it was', () {
      expect(parseInline('snake_case_name and 2 * 3 * 4'),
          <MdInline>[const MdText('snake_case_name and 2 * 3 * 4')]);
      expect(parseInline('an **unclosed marker'),
          <MdInline>[const MdText('an **unclosed marker')]);
      expect(parseMarkdown('a | b without a separator'), <MdBlock>[
        const MdParagraph(<List<MdInline>>[
          <MdInline>[MdText('a | b without a separator')],
        ]),
      ]);
    });

    test('keeps line breaks inside a paragraph and splits paragraphs on blank lines', () {
      final List<MdBlock> blocks = parseMarkdown('First line\nsecond line\n\nNew paragraph');
      expect(blocks, hasLength(2));
      final MdParagraph first = _as<MdParagraph>(blocks[0]);
      expect(first.lines, hasLength(2));
    });
  });

  group('inline runs', () {
    test('bold, italics and code, in one line', () {
      expect(parseInline('Spent **₹500** on _food_ via `UPI` and *cash*'), <MdInline>[
        const MdText('Spent '),
        const MdStrong(<MdInline>[MdText('₹500')]),
        const MdText(' on '),
        const MdEm(<MdInline>[MdText('food')]),
        const MdText(' via '),
        const MdCode('UPI'),
        const MdText(' and '),
        const MdEm(<MdInline>[MdText('cash')]),
      ]);
    });

    test('bold may hold italics; underscores mark up only on word boundaries', () {
      expect(parseInline('**big _deal_**'), <MdInline>[
        const MdStrong(<MdInline>[MdText('big '), MdEm(<MdInline>[MdText('deal')])]),
      ]);
      expect(parseInline('__total__'), <MdInline>[
        const MdStrong(<MdInline>[MdText('total')]),
      ]);
      expect(parseInline('file_name_v2 and my__var'),
          <MdInline>[const MdText('file_name_v2 and my__var')]);
    });

    test('an empty or unclosed code span stays text', () {
      expect(parseInline('``'), <MdInline>[const MdText('``')]);
      expect(parseInline('an `open tick'), <MdInline>[const MdText('an `open tick')]);
    });

    test('plain text of a run drops the markers', () {
      final List<MdInline> line = parseInline('**₹1,200** for _Food_ `x`');
      expect(line.map((MdInline i) => i.plainText).join(), '₹1,200 for Food x');
    });
  });

  group('blocks', () {
    test('heading levels past three fold to three; a #tag is not a heading', () {
      final List<MdBlock> blocks = parseMarkdown('# One\n## Two ##\n#### Four\n#tag');
      expect(blocks.take(3).map((MdBlock b) => (b as MdHeading).level), <int>[1, 2, 3]);
      expect(_as<MdHeading>(blocks[1]).inlines, <MdInline>[const MdText('Two')]);
      expect(blocks[3], isA<MdParagraph>());
    });

    test('rules, CRLF line ends and centred columns', () {
      final List<MdBlock> blocks =
          parseMarkdown('Above\r\n---\r\n| A | B | C |\r\n|:--:|--|--:|\r\n| 1 | 2 | 3 |');
      expect(blocks.map((MdBlock b) => b.runtimeType), <Type>[MdParagraph, MdRule, MdTable]);
      expect(_as<MdTable>(blocks[2]).align, <MdAlign>[MdAlign.center, MdAlign.left, MdAlign.right]);
    });

    test('a short table row is padded to the header and a long one trimmed', () {
      final MdTable table = _as<MdTable>(
        parseMarkdown('| A | B |\n|---|---|\n| only |\n| 1 | 2 | 3 |').single,
      );
      expect(table.rows[0], <List<MdInline>>[
        <MdInline>[const MdText('only')],
        <MdInline>[],
      ]);
      expect(table.rows[1], hasLength(2));
    });

    test('an indented line continues the list item above it', () {
      final MdList list = _as<MdList>(parseMarkdown('- Food\n  and drinks').single);
      expect(list.items.single.inlines, <MdInline>[
        const MdText('Food'),
        const MdText(' '),
        const MdText('and drinks'),
      ]);
    });

    test('switching between bullets and numbers starts a new list', () {
      final List<MdBlock> blocks = parseMarkdown('- a\n- b\n1. one\n2. two');
      expect(blocks, hasLength(2));
      expect(_as<MdList>(blocks[0]).ordered, isFalse);
      expect(_as<MdList>(blocks[1]).ordered, isTrue);
      expect(_as<MdList>(blocks[1]).start, 1);
    });

    test('a paragraph line after a list closes it', () {
      final List<MdBlock> blocks = parseMarkdown('- a\nThat is all.');
      expect(blocks.map((MdBlock b) => b.runtimeType), <Type>[MdList, MdParagraph]);
    });

    test('nothing at all reads as no blocks', () {
      expect(parseMarkdown(''), isEmpty);
      expect(parseMarkdown('  \n\n '), isEmpty);
    });

    test('nothing that looks like HTML or a link is treated specially', () {
      final List<MdBlock> blocks =
          parseMarkdown('<b>hi</b> [click](https://example.com) <script>x</script>');
      expect(blocks, <MdBlock>[
        const MdParagraph(<List<MdInline>>[
          <MdInline>[MdText('<b>hi</b> [click](https://example.com) <script>x</script>')],
        ]),
      ]);
    });
  });
}
