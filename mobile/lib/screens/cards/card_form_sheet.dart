import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../models/bank_account.dart';
import '../../models/card_statement.dart';
import '../../models/credit_card.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/state_views.dart';

/// Add or edit a credit card. Pops true when something was written.
class CardFormSheet extends StatefulWidget {
  const CardFormSheet({super.key, this.card});

  final CreditCard? card;

  @override
  State<CardFormSheet> createState() => _CardFormSheetState();
}

class _CardFormSheetState extends State<CardFormSheet> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _name =
      TextEditingController(text: widget.card?.cardName ?? '');
  late final TextEditingController _issuer =
      TextEditingController(text: widget.card?.issuer ?? '');
  late final TextEditingController _last4 =
      TextEditingController(text: widget.card?.last4 ?? '');
  late final TextEditingController _limit = TextEditingController(
    text: widget.card == null ? '' : _trim(widget.card!.creditLimit),
  );
  late final TextEditingController _opening = TextEditingController(
    text: widget.card == null || widget.card!.openingOutstanding == 0
        ? ''
        : _trim(widget.card!.openingOutstanding),
  );
  late final TextEditingController _notes =
      TextEditingController(text: widget.card?.notes ?? '');

  late CardNetwork? _network = widget.card?.network;
  late int? _statementDay = widget.card?.statementDay;
  late int? _dueDay = widget.card?.paymentDueDay;
  late String? _paymentAccountId = widget.card?.paymentAccountId;
  late bool _active = widget.card?.isActive ?? true;
  bool _submitted = false;
  bool _saving = false;
  String? _error;

  bool get _isEditing => widget.card != null;

  static String _trim(double value) {
    final String text = value.toStringAsFixed(2);
    return text.endsWith('.00') ? text.substring(0, text.length - 3) : text;
  }

  @override
  void dispose() {
    _name.dispose();
    _issuer.dispose();
    _last4.dispose();
    _limit.dispose();
    _opening.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final List<BankAccount> accounts =
        context.watch<BankAccountProvider>().accounts;
    final BillingCycle? cycle = _statementDay != null && _dueDay != null
        ? cycleContaining(AppDateUtils.today(), _statementDay!, _dueDay!)
        : null;

    return Form(
      key: _formKey,
      child: AppSheet(
        title: _isEditing ? 'Edit card' : 'New credit card',
        subtitle: _isEditing
            ? widget.card!.issuer
            : 'Track its outstanding, bills and statement',
        action: _isEditing
            ? IconButton(
                tooltip: 'Delete card',
                onPressed: _saving ? null : _delete,
                icon: const Icon(Icons.delete_outline_rounded),
                color: theme.colorScheme.error,
              )
            : null,
        footer: AppButton.submit(
          label: _isEditing ? 'Save changes' : 'Add card',
          busy: _saving,
          busyLabel: 'Saving…',
          onPressed: _saving ? null : _save,
        ),
        children: <Widget>[
          const FieldLabel('Card name', isRequired: true),
          TextFormField(
            controller: _name,
            autofocus: !_isEditing,
            enabled: !_saving,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            validator: (String? v) => Validators.required(v, 'Card name'),
            decoration: const InputDecoration(
              hintText: 'Regalia, Millennia, Amazon Pay…',
              prefixIcon:
                  Icon(Icons.credit_card_rounded, size: AppSpacing.iconMd),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Bank or issuer', isRequired: true),
          TextFormField(
            controller: _issuer,
            enabled: !_saving,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            validator: (String? v) => Validators.required(v, 'Bank or issuer'),
            decoration: const InputDecoration(
              hintText: 'HDFC Bank, SBI Card, ICICI Bank…',
              prefixIcon: Icon(
                Icons.account_balance_outlined,
                size: AppSpacing.iconMd,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Network', hint: 'Optional'),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: CardNetwork.values
                .map((CardNetwork n) => AppChoiceChip(
                      label: n.label,
                      selected: _network == n,
                      enabled: !_saving,
                      onSelected: () =>
                          setState(() => _network = _network == n ? null : n),
                    ))
                .toList(),
          ),
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Last 4 digits', hint: 'Optional'),
          TextFormField(
            controller: _last4,
            enabled: !_saving,
            keyboardType: TextInputType.number,
            maxLength: 4,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
            validator: (String? v) => (v ?? '').isNotEmpty && v!.length != 4
                ? 'Enter all 4 digits'
                : null,
            decoration: const InputDecoration(
              hintText: '4821',
              counterText: '',
              helperText: 'Lets a bank SMS for this card pick it '
                  'automatically. Never enter the full card number.',
              helperMaxLines: 2,
              prefixIcon: Icon(Icons.tag_rounded, size: AppSpacing.iconMd),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Credit limit', isRequired: true),
          TextFormField(
            controller: _limit,
            enabled: !_saving,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: amountInputFormatters,
            validator: _validateLimit,
            decoration: InputDecoration(
              prefixText: '${settings.currencySymbol} ',
              hintText: '0',
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Opening outstanding', hint: 'Optional'),
          TextFormField(
            controller: _opening,
            enabled: !_saving,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d{0,2}')),
            ],
            validator: _validateOpening,
            decoration: InputDecoration(
              prefixText: '${settings.currencySymbol} ',
              hintText: '0',
              helperText: 'What you owed before the transactions you track '
                  'here. Negative for a credit balance.',
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Billing cycle', isRequired: true),
          Row(
            children: <Widget>[
              Expanded(
                child: _DayPicker(
                  label: 'Statement day',
                  value: _statementDay,
                  enabled: !_saving,
                  missing: _submitted && _statementDay == null,
                  onChanged: (int? v) => setState(() => _statementDay = v),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _DayPicker(
                  label: 'Due day',
                  value: _dueDay,
                  enabled: !_saving,
                  missing: _submitted && _dueDay == null,
                  onChanged: (int? v) => setState(() => _dueDay = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            cycle != null
                ? 'Next statement ${Formatters.dayMonthYear(cycle.end)}, due '
                    '${Formatters.dayMonthYear(cycle.dueDate)}.'
                : 'The day the statement is generated, and the day the bill '
                    'is due after it.',
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Usually paid from', hint: 'Optional'),
          DropdownButtonFormField<String?>(
            value: accounts.any((BankAccount a) => a.id == _paymentAccountId)
                ? _paymentAccountId
                : null,
            isExpanded: true,
            decoration: const InputDecoration(
              prefixIcon: Icon(
                Icons.account_balance_outlined,
                size: AppSpacing.iconMd,
              ),
            ),
            items: <DropdownMenuItem<String?>>[
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('No account set'),
              ),
              ...accounts.map((BankAccount a) => DropdownMenuItem<String?>(
                    value: a.id,
                    child: Text(a.displayLabel, overflow: TextOverflow.ellipsis),
                  )),
            ],
            onChanged: _saving
                ? null
                : (String? v) => setState(() => _paymentAccountId = v),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Pre-selected when you pay the bill. Purchases on the card never '
            'touch this account.',
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Notes', hint: 'Optional'),
          TextFormField(
            controller: _notes,
            enabled: !_saving,
            maxLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'Annual fee waiver, reward rules…',
            ),
          ),
          if (_isEditing) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            const FieldLabel('Status'),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<bool>(
                segments: const <ButtonSegment<bool>>[
                  ButtonSegment<bool>(value: true, label: Text('Active')),
                  ButtonSegment<bool>(value: false, label: Text('Inactive')),
                ],
                selected: <bool>{_active},
                showSelectedIcon: false,
                onSelectionChanged: _saving
                    ? null
                    : (Set<bool> v) => setState(() => _active = v.first),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'An inactive card keeps its statement and can still be paid '
              'off, but is not offered for new purchases.',
              style: theme.textTheme.labelSmall,
            ),
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            InlineError(message: _error!),
          ],
        ],
      ),
    );
  }

  String? _validateLimit(String? value) {
    final String input = (value ?? '').trim();
    if (input.isEmpty) return 'Credit limit is required';
    final double? parsed = double.tryParse(input);
    if (parsed == null) return 'Enter a valid number';
    if (parsed <= 0) return "Enter the card's credit limit";
    if (parsed > 999999999) return 'Amount is too large';
    return null;
  }

  String? _validateOpening(String? value) {
    final String input = (value ?? '').trim();
    if (input.isEmpty) return null;
    final double? parsed = double.tryParse(input);
    if (parsed == null) return 'Enter a valid number';
    if (parsed.abs() > 999999999) return 'Amount is too large';
    return null;
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    setState(() => _submitted = true);
    final bool valid = _formKey.currentState!.validate();
    if (!valid || _statementDay == null || _dueDay == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    final CreditCardProvider provider = context.read<CreditCardProvider>();
    final bool ok = await provider.save(CreditCard(
      id: widget.card?.id ?? '',
      userId: widget.card?.userId ?? '',
      cardName: _name.text,
      issuer: _issuer.text,
      network: _network,
      last4: _last4.text,
      creditLimit: double.parse(_limit.text.trim()),
      openingOutstanding: double.tryParse(_opening.text.trim()) ?? 0,
      statementDay: _statementDay!,
      paymentDueDay: _dueDay!,
      paymentAccountId: _paymentAccountId,
      isActive: _active,
      notes: _notes.text,
    ));
    if (!mounted) return;
    if (ok) {
      AppFeedback.success(context, _isEditing ? 'Card updated' : 'Card added');
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = provider.errorMessage ?? 'Could not save the card.';
      });
    }
  }

  Future<void> _delete() async {
    final CreditCard card = widget.card!;
    final CreditCardProvider provider = context.read<CreditCardProvider>();
    final ({int purchases, int payments, int others})? activity =
        await provider.activity(card.id);
    if (!mounted) return;

    String plural(int n, String one, String many) => n == 1 ? one : many;
    final List<String> parts = activity == null
        ? <String>[
            'Its purchases stay as expenses (recorded as Cash), its bill '
                'payments stay on their bank accounts as plain debits, and its '
                'other card transactions are deleted.',
          ]
        : <String>[
            if (activity.purchases > 0)
              '${activity.purchases} ${plural(activity.purchases, 'purchase stays as an expense but is', 'purchases stay as expenses but are')} '
                  'recorded as Cash.',
            if (activity.payments > 0)
              '${activity.payments} bill ${plural(activity.payments, 'payment stays on its', 'payments stay on their')} '
                  'bank ${plural(activity.payments, 'account', 'accounts')} as a plain debit.',
            if (activity.others > 0)
              '${activity.others} other card ${plural(activity.others, 'transaction is', 'transactions are')} deleted.',
          ];
    final bool confirmed = await AppFeedback.confirm(
      context,
      title: 'Delete "${card.cardName}"?',
      message: '${parts.isEmpty ? 'This card has no transactions.' : parts.join(' ')} '
          'To keep its history, mark it inactive instead. This cannot be '
          'undone.',
    );
    if (!confirmed || !mounted) return;

    setState(() => _saving = true);
    final bool ok = await provider.delete(card.id);
    if (!mounted) return;
    if (ok) {
      AppFeedback.success(context, 'Card deleted');
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = provider.errorMessage ?? 'Could not delete the card.';
      });
    }
  }
}

/// Day of the month, 1st–31st.
class _DayPicker extends StatelessWidget {
  const _DayPicker({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.enabled,
    required this.missing,
  });

  final String label;
  final int? value;
  final ValueChanged<int?> onChanged;
  final bool enabled;
  final bool missing;

  static String ordinal(int n) {
    final int tens = n % 100;
    if (tens >= 11 && tens <= 13) return '${n}th';
    return switch (n % 10) {
      1 => '${n}st',
      2 => '${n}nd',
      3 => '${n}rd',
      _ => '${n}th',
    };
  }

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<int>(
      value: value,
      isExpanded: true,
      menuMaxHeight: 320,
      decoration: InputDecoration(
        labelText: label,
        errorText: missing ? 'Pick a day' : null,
      ),
      items: List<DropdownMenuItem<int>>.generate(
        31,
        (int i) => DropdownMenuItem<int>(
          value: i + 1,
          child: Text(ordinal(i + 1)),
        ),
      ),
      onChanged: enabled ? onChanged : null,
    );
  }
}
