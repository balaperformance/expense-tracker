/// A small Markdown reader for the assistant's replies: the subset a chat
/// answer needs and nothing more — headings, paragraphs, bulleted and
/// numbered lists (one level of nesting), tables, bold, italics and inline
/// code. It returns plain data; the screen lays it out as text spans, so no
/// reply is ever interpreted as HTML, and links are never made tappable.
///
/// Anything it does not recognise stays text, exactly as written.
///
/// This is a line-for-line port of the web app's `ui/src/lib/markdown.ts`,
/// so a reply reads the same on both. Keep the two in step.
library;

import 'package:flutter/foundation.dart';

// ---------------------------------------------------------------------------
// Inline nodes
// ---------------------------------------------------------------------------

/// A run of text inside a line.
@immutable
sealed class MdInline {
  const MdInline();

  /// The words without any formatting.
  String get plainText;
}

@immutable
final class MdText extends MdInline {
  const MdText(this.text);

  final String text;

  @override
  String get plainText => text;

  @override
  bool operator ==(Object other) => other is MdText && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'MdText(${_quote(text)})';
}

@immutable
final class MdStrong extends MdInline {
  const MdStrong(this.children);

  final List<MdInline> children;

  @override
  String get plainText => _plain(children);

  @override
  bool operator ==(Object other) =>
      other is MdStrong && listEquals(other.children, children);

  @override
  int get hashCode => Object.hash('strong', Object.hashAll(children));

  @override
  String toString() => 'MdStrong($children)';
}

@immutable
final class MdEm extends MdInline {
  const MdEm(this.children);

  final List<MdInline> children;

  @override
  String get plainText => _plain(children);

  @override
  bool operator ==(Object other) =>
      other is MdEm && listEquals(other.children, children);

  @override
  int get hashCode => Object.hash('em', Object.hashAll(children));

  @override
  String toString() => 'MdEm($children)';
}

@immutable
final class MdCode extends MdInline {
  const MdCode(this.text);

  final String text;

  @override
  String get plainText => text;

  @override
  bool operator ==(Object other) => other is MdCode && other.text == text;

  @override
  int get hashCode => Object.hash('code', text);

  @override
  String toString() => 'MdCode(${_quote(text)})';
}

// ---------------------------------------------------------------------------
// Block nodes
// ---------------------------------------------------------------------------

enum MdAlign { left, right, center }

/// One entry of a list. Depth 0 is a top-level point, 1 a sub-point.
@immutable
class MdListItem {
  const MdListItem({required this.inlines, required this.depth});

  final List<MdInline> inlines;
  final int depth;

  @override
  bool operator ==(Object other) =>
      other is MdListItem &&
      other.depth == depth &&
      listEquals(other.inlines, inlines);

  @override
  int get hashCode => Object.hash(depth, Object.hashAll(inlines));

  @override
  String toString() => 'MdListItem(depth: $depth, $inlines)';
}

@immutable
sealed class MdBlock {
  const MdBlock();
}

/// `#`, `##` and `###` and deeper, folded to three levels.
@immutable
final class MdHeading extends MdBlock {
  const MdHeading({required this.level, required this.inlines});

  /// 1, 2 or 3.
  final int level;
  final List<MdInline> inlines;

  @override
  bool operator ==(Object other) =>
      other is MdHeading &&
      other.level == level &&
      listEquals(other.inlines, inlines);

  @override
  int get hashCode => Object.hash(level, Object.hashAll(inlines));

  @override
  String toString() => 'MdHeading($level, $inlines)';
}

/// Consecutive lines; each keeps its own line break.
@immutable
final class MdParagraph extends MdBlock {
  const MdParagraph(this.lines);

  final List<List<MdInline>> lines;

  @override
  bool operator ==(Object other) =>
      other is MdParagraph && _deepEquals(other.lines, lines);

  @override
  int get hashCode => Object.hashAll(lines.map(Object.hashAll));

  @override
  String toString() => 'MdParagraph($lines)';
}

@immutable
final class MdList extends MdBlock {
  const MdList({
    required this.ordered,
    required this.start,
    required this.items,
  });

  final bool ordered;

  /// The number the first step carries; a reply may start counting at 3.
  final int start;
  final List<MdListItem> items;

  @override
  bool operator ==(Object other) =>
      other is MdList &&
      other.ordered == ordered &&
      other.start == start &&
      listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(ordered, start, Object.hashAll(items));

  @override
  String toString() => 'MdList(ordered: $ordered, start: $start, $items)';
}

@immutable
final class MdTable extends MdBlock {
  const MdTable({
    required this.header,
    required this.align,
    required this.rows,
  });

  /// One inline run per column.
  final List<List<MdInline>> header;

  /// One entry per column.
  final List<MdAlign> align;

  /// Every row has exactly as many cells as [header].
  final List<List<List<MdInline>>> rows;

  int get columns => header.length;

  @override
  bool operator ==(Object other) =>
      other is MdTable &&
      _deepEquals(other.header, header) &&
      listEquals(other.align, align) &&
      other.rows.length == rows.length &&
      Iterable<int>.generate(rows.length)
          .every((int r) => _deepEquals(other.rows[r], rows[r]));

  @override
  int get hashCode => Object.hash(
        Object.hashAll(header.map(Object.hashAll)),
        Object.hashAll(align),
        rows.length,
      );

  @override
  String toString() => 'MdTable($header, $align, $rows)';
}

@immutable
final class MdRule extends MdBlock {
  const MdRule();

  @override
  bool operator ==(Object other) => other is MdRule;

  @override
  int get hashCode => (MdRule).hashCode;

  @override
  String toString() => 'MdRule()';
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

final RegExp _heading = RegExp(r'^(#{1,6})\s+(.+?)\s*#*\s*$');
final RegExp _bullet = RegExp(r'^(\s*)[-*+•]\s+(.*)$');
final RegExp _numbered = RegExp(r'^(\s*)(\d{1,3})[.)]\s+(.*)$');
final RegExp _rule = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');
final RegExp _tableSeparator =
    RegExp(r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$');
final RegExp _strong = RegExp(r'^(\*\*|__)(?=\S)([\s\S]*?\S)\1');
final RegExp _em = RegExp(r'^(\*|_)(?=\S)([^*_]*?\S)\1');
final RegExp _alnum = RegExp(r'[A-Za-z0-9]');
final RegExp _continuation = RegExp(r'^\s{2,}\S');
final RegExp _lineEnd = RegExp(r'\r\n?');

/// Bold, italics and code within a line. Unmatched markers stay as text.
List<MdInline> parseInline(String text) {
  final List<MdInline> out = <MdInline>[];
  final StringBuffer plain = StringBuffer();
  void flush() {
    if (plain.isNotEmpty) out.add(MdText(plain.toString()));
    plain.clear();
  }

  int i = 0;
  while (i < text.length) {
    final String rest = text.substring(i);
    if (rest.startsWith('`')) {
      final int end = text.indexOf('`', i + 1);
      if (end > i + 1) {
        flush();
        out.add(MdCode(text.substring(i + 1, end)));
        i = end + 1;
        continue;
      }
    }
    final RegExpMatch? strong = _strong.firstMatch(rest);
    if (strong != null &&
        (strong[1] == '**' || _boundary(text, i, i + strong[0]!.length))) {
      flush();
      out.add(MdStrong(parseInline(strong[2] ?? '')));
      i += strong[0]!.length;
      continue;
    }
    final RegExpMatch? em = _em.firstMatch(rest);
    // An underscore inside a word (snake_case, file_name) is not emphasis.
    if (em != null && (em[1] == '*' || _boundary(text, i, i + em[0]!.length))) {
      flush();
      out.add(MdEm(parseInline(em[2] ?? '')));
      i += em[0]!.length;
      continue;
    }
    plain.write(text[i]);
    i += 1;
  }
  flush();
  return out;
}

/// True when the marker run [start, end) is not glued to letters or digits
/// on either side.
bool _boundary(String text, int start, int end) {
  final String before = start - 1 >= 0 ? text[start - 1] : ' ';
  final String after = end < text.length ? text[end] : ' ';
  return !_alnum.hasMatch(before) && !_alnum.hasMatch(after);
}

List<String> _cells(String line) {
  String trimmed = line.trim();
  if (trimmed.startsWith('|')) trimmed = trimmed.substring(1);
  if (trimmed.endsWith('|')) trimmed = trimmed.substring(0, trimmed.length - 1);
  return trimmed.split('|').map((String c) => c.trim()).toList();
}

bool _isTableRow(String? line) =>
    line != null && line.contains('|') && line.trim().length > 1;

MdAlign _alignOf(String cell) {
  if (cell.startsWith(':') && cell.endsWith(':')) return MdAlign.center;
  if (cell.endsWith(':')) return MdAlign.right;
  return MdAlign.left;
}

/// Reads a whole reply into blocks.
List<MdBlock> parseMarkdown(String source) {
  final List<String> lines = source.replaceAll(_lineEnd, '\n').split('\n');
  final List<MdBlock> blocks = <MdBlock>[];
  List<List<MdInline>> paragraph = <List<MdInline>>[];
  _OpenList? list;

  void endParagraph() {
    if (paragraph.isNotEmpty) blocks.add(MdParagraph(paragraph));
    paragraph = <List<MdInline>>[];
  }

  void endList() {
    if (list != null) blocks.add(list!.close());
    list = null;
  }

  String? at(int index) =>
      index >= 0 && index < lines.length ? lines[index] : null;

  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i];
    if (line.trim().isEmpty) {
      endParagraph();
      endList();
      continue;
    }

    // A table: a row of cells, then a separator row.
    if (_isTableRow(line) && _tableSeparator.hasMatch(at(i + 1) ?? '')) {
      endParagraph();
      endList();
      final List<String> header = _cells(line);
      final List<MdAlign> align = _cells(at(i + 1) ?? '').map(_alignOf).toList();
      final List<List<List<MdInline>>> rows = <List<List<MdInline>>>[];
      i += 2;
      while (i < lines.length && _isTableRow(lines[i])) {
        final List<String> row = _cells(lines[i]);
        rows.add(<List<MdInline>>[
          for (int c = 0; c < header.length; c++)
            parseInline(c < row.length ? row[c] : ''),
        ]);
        i += 1;
      }
      i -= 1;
      blocks.add(MdTable(
        header: header.map(parseInline).toList(),
        align: <MdAlign>[
          for (int c = 0; c < header.length; c++)
            c < align.length ? align[c] : MdAlign.left,
        ],
        rows: rows,
      ));
      continue;
    }

    final RegExpMatch? heading = _heading.firstMatch(line);
    if (heading != null) {
      endParagraph();
      endList();
      final int level = (heading[1] ?? '#').length.clamp(1, 3);
      blocks.add(MdHeading(level: level, inlines: parseInline(heading[2] ?? '')));
      continue;
    }

    if (_rule.hasMatch(line)) {
      endParagraph();
      endList();
      blocks.add(const MdRule());
      continue;
    }

    final RegExpMatch? bullet = _bullet.firstMatch(line);
    final RegExpMatch? numbered = bullet != null ? null : _numbered.firstMatch(line);
    if (bullet != null || numbered != null) {
      endParagraph();
      final bool ordered = numbered != null;
      final int indent =
          (bullet?[1] ?? numbered?[1] ?? '').replaceAll('\t', '    ').length;
      final String text = bullet != null ? (bullet[2] ?? '') : (numbered?[3] ?? '');
      final int depth = indent >= 2 && list != null ? 1 : 0;
      if (list == null || (depth == 0 && list!.ordered != ordered)) {
        endList();
        list = _OpenList(
          ordered: ordered,
          start: numbered != null ? int.parse(numbered[2]!) : 1,
        );
      }
      list!.items.add(_OpenItem(parseInline(text), depth));
      continue;
    }

    // An indented line under a list item continues it.
    if (list != null && _continuation.hasMatch(line)) {
      final _OpenItem? last = list!.items.isEmpty ? null : list!.items.last;
      if (last != null) {
        last.inlines
          ..add(const MdText(' '))
          ..addAll(parseInline(line.trim()));
      }
      continue;
    }

    endList();
    paragraph.add(parseInline(line.trim()));
  }
  endParagraph();
  endList();
  return blocks;
}

/// The list being read; items stay growable until it is closed.
class _OpenList {
  _OpenList({required this.ordered, required this.start});

  final bool ordered;
  final int start;
  final List<_OpenItem> items = <_OpenItem>[];

  MdList close() => MdList(
        ordered: ordered,
        start: start,
        items: <MdListItem>[
          for (final _OpenItem item in items)
            MdListItem(inlines: List<MdInline>.unmodifiable(item.inlines), depth: item.depth),
        ],
      );
}

class _OpenItem {
  _OpenItem(this.inlines, this.depth);

  final List<MdInline> inlines;
  final int depth;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _plain(List<MdInline> inlines) =>
    inlines.map((MdInline i) => i.plainText).join();

String _quote(String text) => "'${text.replaceAll("'", r"\'")}'";

bool _deepEquals<T>(List<List<T>> a, List<List<T>> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (!listEquals(a[i], b[i])) return false;
  }
  return true;
}
