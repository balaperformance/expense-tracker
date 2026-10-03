import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../models/card_statement.dart';
import '../../models/credit_card.dart';
import '../../models/ledger_entry.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';

/// Refund, cashback, fee, interest or adjustment on a card. Bill payments
/// have their own sheet; purchases are expenses. Pops true when saved.
class CardTransactionSheet extends StatefulWidget {
  const CardTransactionSheet({
    super.key,
    required this.card,
    required this.purchases,
    this.refundOf,
  });

  final CreditCard card;

  /// This card's purchases, newest first, offered as what a refund reverses.
  final List<CardEntry> purchases;

  /// Opens as a refund of this purchase.
  final CardEntry? refundOf;

  @override
  State<CardTransactionSheet> createState() => _CardTransactionSheetState();
}

class _KindOption {
  const _KindOption(this.kind, this.label, this.hint);

  final CardTransactionKind kind;
  final String label;
  final String hint;
}

class _CardTransactionSheetState extends State<CardTransactionSheet> {
  static const List<_KindOption> _kinds = <_KindOption>[
    _KindOption(CardTransactionKind.refund, 'Refund', 'Money returned for a purchase'),
    _KindOption(CardTransactionKind.cashback, 'Cashback', 'Rewards or cashback credited to the card'),
    _KindOption(CardTransactionKind.fee, 'Fee', 'Annual fee, late fee, GST on charges'),
    _KindOption(CardTransactionKind.interest, 'Interest', 'Finance charges on a carried balance'),
    _KindOption(CardTransactionKind.adjustment, 'Adjustment', 'Correct the outstanding either way'),
  ];

  static const Map<CardTransactionKind, List<String>> _presets =
      <CardTransactionKind, List<String>>{
    CardTransactionKind.cashback: <String>['Cashback', 'Reward points redeemed'],
    CardTransactionKind.fee: <String>['Annual fee', 'Late payment fee', 'GST on charges'],
    CardTransactionKind.interest: <String>['Finance charges'],
  };

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount = TextEditingController(
    text: widget.refundOf == null ? '' : _trim(widget.refundOf!.amount),
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.refundOf == null ? '' : 'Refund: ${widget.refundOf!.title}',
  );
  final TextEditingController _reference = TextEditingController();

  CardTransactionKind _kind = CardTransactionKind.refund;
  LedgerDirection _adjustment = LedgerDirection.credit;
  late String? _originalId = widget.refundOf?.id;
  DateTime _date = AppDateUtils.today();
  bool _saving = false;
  String? _error;

  static String _trim(double value) {
    final String text = value.toStringAsFixed(2);
    return text.endsWith('.00') ? text.substring(0, text.length - 3) : text;
  }

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    _reference.dispose();
    super.dispose();
  }

  LedgerDirection get _direction =>
      directionForKind(_kind, adjustment: _adjustment);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final _KindOption option =
        _kinds.firstWhere((_KindOption o) => o.kind == _kind);
    final bool raises = _direction == LedgerDirection.debit;
    final List<String> presets = _presets[_kind] ?? const <String>[];

    return Form(
      key: _formKey,
      child: AppSheet(
        title: 'Card transaction',
        subtitle: widget.card.displayLabel,
        footer: AppButton.submit(
          label: 'Record ${option.label.toLowerCase()}',
          busy: _saving,
          busyLabel: 'Saving…',
          onPressed: _saving ? null : _save,
        ),
        children: <Widget>[
          const FieldLabel('Type', isRequired: true),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: _kinds
                .map((_KindOption o) => AppChoiceChip(
                      label: o.label,
                      selected: o.kind == _kind,
                      enabled: !_saving,
                      onSelected: () => setState(() => _kind = o.kind),
                    ))
                .toList(),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${option.hint}. ${raises ? 'Adds to' : 'Lowers'} the outstanding'
            '${_kind == CardTransactionKind.refund || _kind == CardTransactionKind.cashback ? '; not counted as income' : ''}'
            '${_kind == CardTransactionKind.fee || _kind == CardTransactionKind.interest ? '; not counted as an expense' : ''}.',
            style: theme.textTheme.labelSmall,
          ),
          if (_kind == CardTransactionKind.adjustment) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<LedgerDirection>(
                segments: const <ButtonSegment<LedgerDirection>>[
                  ButtonSegment<LedgerDirection>(
                    value: LedgerDirection.credit,
                    label: Text('Lower owed'),
                  ),
                  ButtonSegment<LedgerDirection>(
                    value: LedgerDirection.debit,
                    label: Text('Raise owed'),
                  ),
                ],
                selected: <LedgerDirection>{_adjustment},
                showSelectedIcon: false,
                onSelectionChanged: _saving
                    ? null
                    : (Set<LedgerDirection> v) =>
                        setState(() => _adjustment = v.first),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          AmountField(
            controller: _amount,
            symbol: settings.currencySymbol,
            enabled: !_saving,
            autofocus: widget.refundOf == null,
            tone: raises ? ToneColors.expense(context) : ToneColors.income(context),
          ),
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Date', isRequired: true),
          DateField(
            date: _date,
            enabled: !_saving,
            onChanged: (DateTime value) => setState(() => _date = value),
          ),
          if (_kind == CardTransactionKind.refund &&
              widget.purchases.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            const FieldLabel('For purchase', hint: 'Optional'),
            DropdownButtonFormField<String?>(
              value: widget.purchases.any((CardEntry p) => p.id == _originalId)
                  ? _originalId
                  : null,
              isExpanded: true,
              items: <DropdownMenuItem<String?>>[
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Not linked to a purchase'),
                ),
                ...widget.purchases.take(60).map((CardEntry p) =>
                    DropdownMenuItem<String?>(
                      value: p.id,
                      child: Text(
                        '${Formatters.dayMonth(p.date)} · ${p.title} · '
                        '${Formatters.currency(p.amount, currencyCode: settings.currency)}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    )),
              ],
              onChanged: _saving
                  ? null
                  : (String? v) => setState(() => _originalId = v),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Description', hint: 'Optional'),
          TextFormField(
            controller: _description,
            enabled: !_saving,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'What was this?'),
          ),
          if (presets.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _description,
              builder: (BuildContext context, TextEditingValue value, _) =>
                  Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: presets
                    .map((String preset) => AppChoiceChip(
                          label: preset,
                          selected: value.text.trim() == preset,
                          enabled: !_saving,
                          onSelected: () => _description.text = preset,
                        ))
                    .toList(),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Reference', hint: 'Optional'),
          TextFormField(
            controller: _reference,
            enabled: !_saving,
            decoration: const InputDecoration(
              hintText: 'Transaction ID on the card statement',
            ),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            InlineError(message: _error!),
          ],
        ],
      ),
    );
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final CreditCardProvider provider = context.read<CreditCardProvider>();
    final String label =
        _kinds.firstWhere((_KindOption o) => o.kind == _kind).label;
    final bool ok = await provider.recordTransaction(
      cardId: widget.card.id,
      kind: _kind,
      direction: _direction,
      amount: Validators.parseAmount(_amount.text)!,
      date: _date,
      description: _description.text,
      reference: _reference.text,
      originalExpenseId:
          _kind == CardTransactionKind.refund ? _originalId : null,
    );
    if (!mounted) return;
    if (ok) {
      AppFeedback.success(context, '$label recorded');
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = provider.errorMessage ?? 'Could not record the transaction.';
      });
    }
  }
}
