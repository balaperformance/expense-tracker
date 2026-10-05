import 'package:flutter/material.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/markdown.dart';

/// An assistant reply, laid out from its Markdown: headings, bulleted points,
/// numbered steps, bold amounts and tables. A plain sentence stays a plain
/// sentence.
///
/// Everything is drawn as text spans — nothing in a reply is interpreted as
/// HTML or turned into a link. Wide tables scroll sideways inside their own
/// box, so the bubble and the page never overflow on a narrow phone.
///
/// The reply is selectable as one piece (long-press, then Copy), the way the
/// plain [SelectableText] it replaces was.
class RichReply extends StatefulWidget {
  const RichReply({
    super.key,
    required this.text,
    this.style,
    this.selectable = true,
  });

  final String text;

  /// Body style. Defaults to the theme's `bodyMedium`.
  final TextStyle? style;

  /// Wraps the reply in a [SelectionArea].
  final bool selectable;

  @override
  State<RichReply> createState() => _RichReplyState();
}

class _RichReplyState extends State<RichReply> {
  late List<MdBlock> _blocks = parseMarkdown(widget.text);

  @override
  void didUpdateWidget(RichReply oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _blocks = parseMarkdown(widget.text);
  }

  @override
  Widget build(BuildContext context) {
    final _ReplyStyles styles = _ReplyStyles.of(context, widget.style);

    final Widget body = _blocks.isEmpty
        ? Text(widget.text, style: styles.body)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int i = 0; i < _blocks.length; i++)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : _gapBefore(_blocks[i])),
                  child: _block(_blocks[i], styles),
                ),
            ],
          );

    return widget.selectable ? SelectionArea(child: body) : body;
  }

  /// A heading after other content gets a little air above it.
  static double _gapBefore(MdBlock block) =>
      block is MdHeading ? AppSpacing.sm + AppSpacing.xs : AppSpacing.sm;

  Widget _block(MdBlock block, _ReplyStyles styles) {
    return switch (block) {
      MdHeading(:final int level, :final List<MdInline> inlines) => Semantics(
          // Its own node, so only the heading is announced as one.
          container: true,
          header: true,
          child: Text.rich(
            _spans(inlines, styles),
            style: level == 1 ? styles.h1 : styles.h2,
          ),
        ),
      MdParagraph(:final List<List<MdInline>> lines) => Text.rich(
          TextSpan(children: <InlineSpan>[
            for (int i = 0; i < lines.length; i++) ...<InlineSpan>[
              if (i > 0) const TextSpan(text: '\n'),
              ..._children(lines[i], styles),
            ],
          ]),
          style: styles.body,
        ),
      final MdList list => _ReplyList(list: list, styles: styles, spans: _spans),
      final MdTable table => _ReplyTable(table: table, styles: styles, spans: _spans),
      MdRule() => Divider(height: 1, thickness: 0.75, color: styles.border),
    };
  }

  static TextSpan _spans(List<MdInline> inlines, _ReplyStyles styles) =>
      TextSpan(children: _children(inlines, styles));

  static List<InlineSpan> _children(List<MdInline> inlines, _ReplyStyles styles) {
    return <InlineSpan>[
      for (final MdInline item in inlines)
        switch (item) {
          MdText(:final String text) => TextSpan(text: text),
          MdStrong(:final List<MdInline> children) =>
            TextSpan(style: styles.strong, children: _children(children, styles)),
          MdEm(:final List<MdInline> children) =>
            TextSpan(style: styles.em, children: _children(children, styles)),
          MdCode(:final String text) => TextSpan(text: text, style: styles.code),
        },
    ];
  }
}

typedef _SpanBuilder = TextSpan Function(List<MdInline> inlines, _ReplyStyles styles);

/// Bulleted points or numbered steps, one level of sub-points.
class _ReplyList extends StatelessWidget {
  const _ReplyList({required this.list, required this.styles, required this.spans});

  final MdList list;
  final _ReplyStyles styles;
  final _SpanBuilder spans;

  @override
  Widget build(BuildContext context) {
    // Steps are numbered from where the reply starts them; sub-points are
    // not counted, so "3, 4, ◦, 5" reads the way it was written.
    final int topLevel = list.items.where((MdListItem i) => i.depth == 0).length;
    final int last = list.start + (topLevel == 0 ? 0 : topLevel - 1);
    final double numberWidth = 8.0 * '$last.'.length + AppSpacing.xs;

    int number = list.start;
    final List<Widget> rows = <Widget>[];
    for (final MdListItem item in list.items) {
      final bool nested = item.depth > 0;
      final String marker;
      if (nested) {
        marker = '◦';
      } else if (list.ordered) {
        marker = '${number++}.';
      } else {
        marker = '•';
      }
      final double markerWidth = list.ordered && !nested ? numberWidth : 16;

      rows.add(Padding(
        padding: EdgeInsets.only(
          top: rows.isEmpty ? 0 : AppSpacing.xs,
          left: nested ? (list.ordered ? numberWidth : 16) + AppSpacing.xs : 0,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            SizedBox(
              width: markerWidth,
              child: Text(
                marker,
                style: styles.marker,
                textAlign: list.ordered && !nested ? TextAlign.right : TextAlign.left,
                maxLines: 1,
                softWrap: false,
              ),
            ),
            const SizedBox(width: AppSpacing.xs + 2),
            Flexible(child: Text.rich(spans(item.inlines, styles), style: styles.body)),
          ],
        ),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }
}

/// A table in its own bordered box. Cells never wrap; a table wider than the
/// bubble scrolls sideways inside the box instead of pushing the page.
class _ReplyTable extends StatelessWidget {
  const _ReplyTable({required this.table, required this.styles, required this.spans});

  final MdTable table;
  final _ReplyStyles styles;
  final _SpanBuilder spans;

  static const double _borderWidth = 0.75;
  static const EdgeInsets _cellPadding =
      EdgeInsets.symmetric(horizontal: 10, vertical: 6);

  static TextAlign _textAlign(MdAlign align) => switch (align) {
        MdAlign.left => TextAlign.left,
        MdAlign.right => TextAlign.right,
        MdAlign.center => TextAlign.center,
      };

  Widget _cell(List<MdInline> inlines, MdAlign align, TextStyle style) {
    return Padding(
      padding: _cellPadding,
      child: Text.rich(
        spans(inlines, styles),
        style: style,
        textAlign: _textAlign(align),
        softWrap: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (table.columns == 0) return const SizedBox.shrink();
    final BorderSide line = BorderSide(color: styles.border, width: _borderWidth);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // A narrow table still fills the bubble, as on the web; a wide one
        // keeps its natural width and scrolls.
        final double fill = constraints.hasBoundedWidth
            ? (constraints.maxWidth - _borderWidth * 2).clamp(0.0, double.infinity)
            : 0.0;

        return Semantics(
          container: true,
          label: 'Table',
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.fromBorderSide(line),
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm - _borderWidth),
              child: Padding(
                padding: const EdgeInsets.all(_borderWidth),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: fill),
                    child: Table(
                      defaultColumnWidth: const IntrinsicColumnWidth(),
                      border: TableBorder(horizontalInside: line),
                      children: <TableRow>[
                        TableRow(
                          decoration: BoxDecoration(color: styles.sunken),
                          children: <Widget>[
                            for (int c = 0; c < table.columns; c++)
                              _cell(table.header[c], table.align[c], styles.tableHead),
                          ],
                        ),
                        for (final List<List<MdInline>> row in table.rows)
                          TableRow(
                            children: <Widget>[
                              for (int c = 0; c < table.columns; c++)
                                _cell(row[c], table.align[c], styles.tableCell),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The reply's text styles, all derived from the app's type scale and the
/// active colour scheme, so every palette and both brightnesses follow.
class _ReplyStyles {
  const _ReplyStyles({
    required this.body,
    required this.h1,
    required this.h2,
    required this.strong,
    required this.em,
    required this.code,
    required this.marker,
    required this.tableHead,
    required this.tableCell,
    required this.border,
    required this.sunken,
  });

  factory _ReplyStyles.of(BuildContext context, TextStyle? base) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextTheme text = theme.textTheme;
    final TextStyle body = base ?? text.bodyMedium ?? const TextStyle(fontSize: 13.5);
    final TextStyle heading = (text.titleMedium ?? body).copyWith(
      fontWeight: FontWeight.w600,
      height: 1.3,
      color: scheme.onSurface,
    );
    final Color sunken = scheme.surfaceContainerHighest;
    final double bodySize = body.fontSize ?? 13.5;

    return _ReplyStyles(
      body: body,
      h1: heading.copyWith(fontSize: bodySize + 2),
      h2: heading.copyWith(fontSize: bodySize + 1),
      // Amounts are what a reply bolds, so bold runs get tabular figures.
      strong: TextStyle(
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
        fontFeatures: AppTypography.tabular,
      ),
      em: const TextStyle(fontStyle: FontStyle.italic),
      code: TextStyle(
        fontFamily: 'monospace',
        fontFamilyFallback: const <String>['RobotoMono', 'Menlo', 'Courier'],
        fontSize: bodySize - 1,
        backgroundColor: sunken,
      ),
      marker: body.copyWith(
        color: scheme.onSurfaceVariant,
        fontFeatures: AppTypography.tabular,
      ),
      tableHead: AppTypography.money(body.copyWith(
        fontSize: bodySize - 0.5,
        fontWeight: FontWeight.w600,
        color: scheme.onSurfaceVariant,
        height: 1.3,
      )),
      tableCell: AppTypography.money(body.copyWith(
        fontSize: bodySize - 0.5,
        height: 1.3,
      )),
      border: theme.dividerTheme.color ?? scheme.outline,
      sunken: sunken,
    );
  }

  final TextStyle body;
  final TextStyle h1;
  final TextStyle h2;
  final TextStyle strong;
  final TextStyle em;
  final TextStyle code;
  final TextStyle marker;
  final TextStyle tableHead;
  final TextStyle tableCell;
  final Color border;
  final Color sunken;
}
