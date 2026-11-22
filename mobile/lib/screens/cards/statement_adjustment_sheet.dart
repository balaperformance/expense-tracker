import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../models/card_statement.dart';
import '../../models/credit_card.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/surface_card.dart';
import '../accounts/balance_adjustment_sheets.dart' show parseSignedAmount, signedAmountInputFormatters;

/// The most a remark can say (the database refuses more).
const int statementAdjustmentRemarksMax = 200;

/// Opens the Adjust bill sheet for [card]'s statement of [statementEnd].
/// [balance]: the statement's balance as the app shows it now (the confirmed
/// bill when adjusted). Resolves true when something changed.
Future<bool?> showStatementAdjustmentSheet(
  BuildContext context, {
  required CreditCard card,
  required DateTime statementEnd,
  required double balance,
}) {
  final CreditCardProvider cards = context.read<CreditCardProvider>();
  final double calculated =
      calculatedStatementBalance(balance, cards.entriesFor(card.id), statementEnd);
  return showAppSheet<bool>(
    context: context,
    builder: (_) => StatementAdjustmentSheet(
      card: card,
      statementEnd: statementEnd,
      calculated: calculated,
      adjustment: cards.statementAdjustment(card.id, statementEnd),
    ),
  );
}

/// On a statement's bill: the "Adjusted" mark and the calculated figure when
/// the bill was confirmed from the bank's statement, and "Adjust bill".
/// Nothing before migration 023.
class StatementBillAdjustment extends StatelessWidget {
  const StatementBillAdjustment({
    super.key,
    required this.card,
    required this.statementEnd,
    required this.balance,
    required this.onChanged,
  });

  final CreditCard card;
  final DateTime statementEnd;

  /// The statement's balance as shown: the confirmed bill when adjusted.
  final double balance;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final CreditCardProvider cards = context.watch<CreditCardProvider>();
    if (!cards.canAdjustStatements) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final String currency = context.watch<SettingsProvider>().currency;
    String money(double v) => Formatters.currency(v, currencyCode: currency);
    final CardStatementAdjustment? adjustment = cards.statementAdjustment(card.id, statementEnd);
    final double calculated =
        calculatedStatementBalance(balance, cards.entriesFor(card.id), statementEnd);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (adjustment != null) ...<Widget>[
          const AppBadge(label: 'Adjusted'),
          const SizedBox(height: AppSpacing.xs),
          Text(
            <String>[
              billAdjustedLine(calculated, money),
              if (adjustment.remarks != null) adjustment.remarks!,
            ].join(' · '),
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: AppSpacing.xs),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () async {
              final bool? changed = await showStatementAdjustmentSheet(
                context,
                card: card,
                statementEnd: statementEnd,
                balance: balance,
              );
              if (changed == true) onChanged();
            },
            icon: const Icon(Icons.edit_note_rounded, size: 18),
            label: const Text('Adjust bill'),
          ),
        ),
      ],
    );
  }
}

/// Sets a statement's bill to the amount on the bank's statement, or goes
/// back to the calculated one. The database keeps one card row for the
/// difference: no expense is added and no other row changes.
class StatementAdjustmentSheet extends StatefulWidget {
  const StatementAdjustmentSheet({
    super.key,
    required this.card,
    required this.statementEnd,
    required this.calculated,
    this.adjustment,
  });

  final CreditCard card;
  final DateTime statementEnd;

  /// What the app's own rows put on the statement.
  final double calculated;
  final CardStatementAdjustment? adjustment;

  @override
  State<StatementAdjustmentSheet> createState() => _StatementAdjustmentSheetState();
}

class _StatementAdjustmentSheetState extends State<StatementAdjustmentSheet> {
  late final TextEditingController _amount = TextEditingController(
    text: widget.adjustment == null ? '' : Formatters.amountInput(widget.adjustment!.targetBalance),
  );
  late final TextEditingController _remarks =
      TextEditingController(text: widget.adjustment?.remarks ?? '');
  bool _submitted = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _remarks.dispose();
    super.dispose();
  }

  void _refresh() {
    context.read<DashboardProvider>().invalidate();
  }

  Future<void> _save() async {
    setState(() => _submitted = true);
    final double? target = parseSignedAmount(_amount.text);
    if (target == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final CreditCardProvider cards = context.read<CreditCardProvider>();
    final bool ok = await cards.adjustStatement(
      cardId: widget.card.id,
      statementDate: widget.statementEnd,
      balance: target,
      remarks: _remarks.text,
    );
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _saving = false;
        _error = cards.errorMessage ?? 'Could not adjust the bill.';
      });
      return;
    }
    _refresh();
    final String currency = context.read<SettingsProvider>().currency;
    AppFeedback.success(context, 'Bill set to ${Formatters.currency(target, currencyCode: currency)}');
    Navigator.of(context).pop(true);
  }

  Future<void> _useCalculated() async {
    final CardStatementAdjustment? adjustment = widget.adjustment;
    if (adjustment == null) return;
    final String currency = context.read<SettingsProvider>().currency;
    final bool confirmed = await AppFeedback.confirm(
      context,
      title: 'Use the calculated bill?',
      message: 'The statement goes back to '
          "${Formatters.currency(widget.calculated, currencyCode: currency)}, what the app's rows add up to.",
      confirmLabel: 'Use calculated',
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final CreditCardProvider cards = context.read<CreditCardProvider>();
    final bool ok = await cards.resetStatement(adjustment);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _saving = false;
        _error = cards.errorMessage ?? 'Could not reset the bill.';
      });
      return;
    }
    _refresh();
    AppFeedback.success(context, 'Bill reset to the calculated amount');
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SettingsProvider settings = context.watch<SettingsProvider>();
    String money(double v) => Formatters.currency(v, currencyCode: settings.currency);
    final double? target = parseSignedAmount(_amount.text);
    final String? amountError =
        _submitted && target == null ? 'Enter the amount printed on your statement.' : null;
    final TextStyle? errorStyle = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error);

    return AppSheet(
      title: 'Adjust bill',
      subtitle: 'Statement of ${Formatters.dayMonthYear(widget.statementEnd)}',
      footer: AppButton.submit(
        label: 'Save bill',
        busy: _saving,
        onPressed: _saving ? null : _save,
      ),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text('Calculated by the app', style: theme.textTheme.bodySmall)),
            MoneyText(widget.calculated, currency: settings.currency, style: theme.textTheme.titleSmall),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('Amount on your statement', isRequired: true),
        TextField(
          key: const ValueKey<String>('adjust-bill-amount'),
          controller: _amount,
          enabled: !_saving,
          autofocus: widget.adjustment == null,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          inputFormatters: signedAmountInputFormatters,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(hintText: '0', prefixText: '${settings.currencySymbol} '),
        ),
        const SizedBox(height: AppSpacing.xs),
        if (amountError != null)
          Text(amountError, style: errorStyle)
        else if (target != null)
          Text(
            billAdjustmentLine(widget.calculated, target, money),
            key: const ValueKey<String>('adjust-bill-line'),
            style: theme.textTheme.labelSmall,
          ),
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('Remarks', hint: 'Optional'),
        TextField(
          controller: _remarks,
          enabled: !_saving,
          maxLength: statementAdjustmentRemarksMax,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'e.g. As per HDFC statement'),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          Text(_error!, style: errorStyle),
        ],
        const SizedBox(height: AppSpacing.md),
        const AppNotice(
          message: 'The bill, what is still to pay and the outstanding use this amount. '
              'No expense is added and nothing else changes.',
        ),
        if (widget.adjustment != null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _saving ? null : _useCalculated,
              child: const Text('Use calculated amount'),
            ),
          ),
        ],
      ],
    );
  }
}
