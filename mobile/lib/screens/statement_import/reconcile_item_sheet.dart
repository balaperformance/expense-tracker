import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../providers/reconciliation_provider.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/money_text.dart';

/// What the screen does once the sheet closes: 'add' the row through the
/// import review, 'open' a recorded transaction ([target]), or report a
/// decision that 'failed' to save. Null: nothing more to do.
class ReconSheetResult {
  const ReconSheetResult(this.action, [this.target]);

  final String action;
  final Map<String, Object?>? target;
}

/// One discrepancy (or match): the statement's row beside the app's record,
/// why it was flagged, and what can be done. The only things saved from here
/// are decisions; a transaction is fixed in its own screen.
class ReconcileItemSheet extends StatefulWidget {
  const ReconcileItemSheet({super.key, required this.item, required this.currency, required this.canAdd});

  final ReconItem item;
  final String currency;

  /// The row can be added through the import review (not a card's).
  final bool canAdd;

  @override
  State<ReconcileItemSheet> createState() => _ReconcileItemSheetState();
}

class _ReconcileItemSheetState extends State<ReconcileItemSheet> {
  bool _busy = false;
  bool _linking = false;
  String? _choice;

  ReconItem get item => widget.item;

  Future<void> _decide(String action, String? entryId, {String? itemKey, bool undo = false}) async {
    setState(() => _busy = true);
    final ReconciliationProvider recon = context.read<ReconciliationProvider>();
    final Map<String, Object?> decision = <String, Object?>{
      'scope': item.scope,
      'itemKey': itemKey ?? item.key,
      'action': action,
      'entryId': entryId,
    };
    final bool ok = undo ? await recon.undo(decision) : await recon.decide(decision);
    if (!mounted) return;
    Navigator.of(context).pop(ok ? null : const ReconSheetResult('failed'));
  }

  String _money(num amount) => Formatters.currency(amount, currencyCode: widget.currency);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ReconciliationProvider recon = context.watch<ReconciliationProvider>();
    final Map<String, Object?>? line = item.line;
    final Map<String, Object?>? movement = item.movement;
    final bool fromApp = line == null;
    final bool paired = line != null && movement != null;
    final Map<String, Object?>? elsewhere = item.elsewhere;
    final Map<String, Object?>? openTarget = movement != null
        ? (movement['open'] as Map<Object?, Object?>?)?.cast<String, Object?>()
        : elsewhere != null
            ? <String, Object?>{'type': elsewhere['kind'], 'id': elsewhere['entryId']}
            : null;

    // What it can be linked to: recorded transactions for a statement row, statement rows for a recorded one.
    final List<(String, String, String)> choices = fromApp
        ? item.lineCandidates
            .map((Map<String, Object?> l) => (
                  l['key']! as String,
                  ((l['counterparty'] as String?) ?? (l['description'] as String?) ?? '').trim(),
                  '${Formatters.dayMonth(AppDateUtils.parseDate(l['date']! as String))} · ${_money((l['amount'] as num?) ?? 0)}',
                ))
            .toList()
        : item.candidates
            .map((Map<String, Object?> m) => (
                  m['id']! as String,
                  (m['description'] as String?) ?? recon.kindLabel(m['kind']! as String),
                  '${Formatters.dayMonth(AppDateUtils.parseDate(m['date']! as String))} · ${_money((m['amount'] as num?) ?? 0)} · ${recon.kindLabel(m['kind']! as String)}',
                ))
            .toList();

    final List<Widget> actions = <Widget>[];
    void add(Widget button) => actions.add(button);
    if (item.resolved) {
      add(AppButton(
        label: 'Undo — not accepted',
        icon: Icons.undo_rounded,
        variant: AppButtonVariant.secondary,
        busy: _busy,
        onPressed: () => _decide('dismiss', null, undo: true),
      ));
    } else if (item.issue == 'accountUnknown') {
      if (widget.canAdd) {
        add(AppButton(
          label: 'Choose its account',
          icon: Icons.account_balance_outlined,
          onPressed: () => Navigator.of(context).pop(const ReconSheetResult('add')),
        ));
      }
    } else {
      if (item.issue == 'possibleMatch' && movement != null) {
        add(AppButton(
          label: 'Same transaction',
          icon: Icons.check_rounded,
          busy: _busy,
          onPressed: () => _decide('link', movement['id']! as String),
        ));
      }
      if ((item.issue == 'notInApp' || item.issue == 'unreadable') && widget.canAdd) {
        add(AppButton(
          label: 'Add to app',
          icon: Icons.add_rounded,
          onPressed: () => Navigator.of(context).pop(const ReconSheetResult('add')),
        ));
      }
      if (choices.isNotEmpty && !paired) {
        add(AppButton(
          label: fromApp ? 'Link to a statement row' : 'Link to a recorded one',
          icon: Icons.link_rounded,
          variant: AppButtonVariant.secondary,
          onPressed: () => setState(() => _linking = !_linking),
        ));
      }
      if (openTarget != null) {
        add(AppButton(
          label: item.issue == 'appDuplicate' ? 'Open to delete the extra one' : 'Open in app',
          icon: Icons.edit_outlined,
          variant: AppButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(ReconSheetResult('open', openTarget)),
        ));
      }
      if (paired && item.decision == 'link') {
        add(AppButton(
          label: 'Remove link',
          icon: Icons.link_off_rounded,
          variant: AppButtonVariant.ghost,
          busy: _busy,
          onPressed: () => _decide('link', movement['id']! as String, undo: true),
        ));
      } else if (paired && item.issue != 'notOnBankStatement') {
        add(AppButton(
          label: 'Not the same',
          icon: Icons.close_rounded,
          variant: AppButtonVariant.ghost,
          busy: _busy,
          onPressed: () => _decide('separate', movement['id']! as String),
        ));
      }
      if (item.status != 'matched') {
        add(AppButton(
          label: item.issue == 'appDuplicate' ? 'Not a duplicate' : 'Accept as it is',
          icon: Icons.check_circle_outline_rounded,
          variant: AppButtonVariant.ghost,
          busy: _busy,
          onPressed: () => _decide('dismiss', null),
        ));
      }
    }

    final double effect = item.balanceEffect;
    return AppSheet(
      title: item.title,
      subtitle: '${recon.statusLabel(item.status)}${item.resolved ? ' · accepted by you' : ''}',
      children: <Widget>[
        Text(item.explanation, style: theme.textTheme.bodyMedium),
        const SizedBox(height: AppSpacing.md),
        _Side(
          heading: 'On the statement',
          empty: line == null ? 'Not on the statement' : null,
          amount: line == null ? null : _signed(line),
          lines: line == null
              ? const <String>[]
              : <String>[
                  '${Formatters.dayMonthYear(AppDateUtils.parseDate(line['date']! as String))}'
                      '${line['time'] != null ? ' · ${Formatters.clockTime(line['time']! as String)}' : ''}',
                  (line['rawDescription'] as String?) ?? '',
                ],
          details: line == null
              ? const <String>[]
              : <String>[
                  if (line['reference'] != null) 'Ref ${line['reference']}',
                  if (line['upiId'] != null) 'UPI ${line['upiId']}',
                  ((line['statementIds'] as List<Object?>?) ?? const <Object?>[])
                      .whereType<String>()
                      .map((String id) => recon.statementLabels[id] ?? 'Statement')
                      .join(' · '),
                ],
          currency: widget.currency,
        ),
        const SizedBox(height: AppSpacing.sm),
        if (movement != null)
          _movementSide('In the app', movement, recon)
        else if (elsewhere != null)
          _Side(
            heading: 'In the app, elsewhere',
            amount: elsewhere['kind'] == 'income'
                ? ((elsewhere['amount'] as num?) ?? 0).toDouble()
                : -((elsewhere['amount'] as num?) ?? 0).toDouble(),
            lines: <String>[
              Formatters.dayMonthYear(AppDateUtils.parseDate(elsewhere['date']! as String)),
              (elsewhere['label'] as String?) ?? '',
            ],
            details: <String>[
              if (elsewhere['cardId'] != null)
                'On a credit card'
              else if (elsewhere['accountId'] != null)
                'On another account'
              else
                'No account (cash or untracked)',
            ],
            currency: widget.currency,
          )
        else
          const _Side(heading: 'In the app', empty: 'Not recorded', currency: ''),
        if (item.duplicateOf != null) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          _movementSide('The copy the statement matches', item.duplicateOf!, recon),
        ],
        if (item.reasons.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: item.reasons
                .map((String r) => Chip(label: Text(r), visualDensity: VisualDensity.compact))
                .toList(),
          ),
        ],
        if (effect != 0) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          Text(
            "Puts the app's ${item.scope.startsWith('card:') ? 'outstanding' : 'balance'} "
            "${_money(effect.abs())} ${effect > 0 ? 'below' : 'above'} the statement's for this period.",
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (_linking) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          Text(fromApp ? 'Which statement row is it?' : 'Which recorded transaction is it?', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          for (final (String key, String label, String detail) in choices)
            RadioListTile<String>(
              value: key,
              groupValue: _choice,
              onChanged: (String? v) => setState(() => _choice = v),
              title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(detail),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
          AppButton(
            label: 'Link',
            icon: Icons.link_rounded,
            busy: _busy,
            onPressed: _choice == null
                ? null
                : () => fromApp && movement != null
                    ? _decide('link', movement['id']! as String, itemKey: _choice)
                    : _decide('link', _choice),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Linking only records that the two are the same transaction. Nothing is changed or deleted.',
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (actions.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: actions),
        ],
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }

  static double _signed(Map<String, Object?> side) {
    final double amount = ((side['amount'] as num?) ?? 0).toDouble();
    return side['direction'] == 'debit' ? -amount : amount;
  }

  Widget _movementSide(String heading, Map<String, Object?> m, ReconciliationProvider recon) => _Side(
        heading: heading,
        amount: _signed(m),
        lines: <String>[
          Formatters.dayMonthYear(AppDateUtils.parseDate(m['date']! as String)),
          (m['description'] as String?) ?? 'No description',
        ],
        details: <String>[
          <String>[
            recon.kindLabel(m['kind']! as String),
            if (m['person'] != null) m['person']! as String,
            if (m['category'] != null) m['category']! as String,
          ].join(' · '),
          if (m['reference'] != null) 'Ref ${m['reference']}',
        ],
        currency: widget.currency,
      );
}

/// One side of the comparison: what the statement printed, or what the app recorded.
class _Side extends StatelessWidget {
  const _Side({
    required this.heading,
    required this.currency,
    this.amount,
    this.lines = const <String>[],
    this.details = const <String>[],
    this.empty,
  });

  final String heading;
  final String currency;
  final double? amount;
  final List<String> lines;
  final List<String> details;

  /// Shown instead of the figures when this side has nothing.
  final String? empty;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(empty == null ? 0.6 : 0.25),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: theme.colorScheme.outlineVariant, width: 0.75),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(heading.toUpperCase(), style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 0.4)),
          const SizedBox(height: AppSpacing.xs),
          if (empty != null)
            Text(empty!, style: theme.textTheme.bodyMedium)
          else ...<Widget>[
            if (amount != null)
              MoneyText(
                amount!,
                currency: currency,
                signed: true,
                tone: amount! < 0 ? AmountTone.neutral : AmountTone.positive,
                style: theme.textTheme.titleLarge,
              ),
            for (final String line in lines)
              if (line.isNotEmpty) Text(line, style: theme.textTheme.bodyMedium),
            for (final String detail in details)
              if (detail.isNotEmpty) Text(detail, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
