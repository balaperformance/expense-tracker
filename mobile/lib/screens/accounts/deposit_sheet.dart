import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/validators.dart';
import '../../models/bank_account.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';

/// Adds or removes money on an account directly, as a ledger credit or debit.
///
/// This is for movements that are not expenses or income — a refund, an ATM
/// withdrawal, a bank charge. Expenses and income write their own ledger rows
/// automatically, and transfers have their own sheet.
class DepositSheet extends StatefulWidget {
  const DepositSheet({
    super.key,
    required this.account,
    this.asWithdrawal = false,
  });

  final BankAccount account;
  final bool asWithdrawal;

  @override
  State<DepositSheet> createState() => _DepositSheetState();
}

class _DepositSheetState extends State<DepositSheet> {
  static const List<String> _creditPresets = <String>[
    'Deposit',
    'Refund',
    'Interest',
    'Cashback',
  ];
  static const List<String> _debitPresets = <String>[
    'Withdrawal',
    'Bank charge',
    'ATM',
    'Fee',
  ];

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _description = TextEditingController();

  late bool _isWithdrawal = widget.asWithdrawal;
  DateTime _date = AppDateUtils.today();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final List<String> presets =
        _isWithdrawal ? _debitPresets : _creditPresets;
    final Color tone = _isWithdrawal
        ? ToneColors.expense(context)
        : ToneColors.income(context);

    return Form(
      key: _formKey,
      child: AppSheet(
        title: _isWithdrawal ? 'Take money out' : 'Add money',
        subtitle: widget.account.displayLabel,
        footer: AppButton.submit(
          label: _isWithdrawal ? 'Record debit' : 'Add money',
          busy: _saving,
          busyLabel: 'Saving…',
          onPressed: _saving ? null : _save,
        ),
        children: <Widget>[
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(
                  value: false,
                  label: Text('Money in'),
                  icon: Icon(Icons.south_west_rounded, size: 15),
                ),
                ButtonSegment<bool>(
                  value: true,
                  label: Text('Money out'),
                  icon: Icon(Icons.north_east_rounded, size: 15),
                ),
              ],
              selected: <bool>{_isWithdrawal},
              showSelectedIcon: false,
              onSelectionChanged: _saving
                  ? null
                  : (Set<bool> value) =>
                      setState(() => _isWithdrawal = value.first),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          AmountField(
            controller: _amount,
            symbol: settings.currencySymbol,
            enabled: !_saving,
            tone: tone,
          ),
          const SizedBox(height: AppSpacing.lg),

          const FieldLabel('Date', isRequired: true),
          DateField(
            date: _date,
            enabled: !_saving,
            onChanged: (DateTime value) => setState(() => _date = value),
          ),
          const SizedBox(height: AppSpacing.lg),

          const FieldLabel('Description'),
          TextFormField(
            controller: _description,
            enabled: !_saving,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'What was this for?',
              prefixIcon: Icon(
                Icons.short_text_rounded,
                size: AppSpacing.iconMd,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _description,
            builder: (BuildContext context, TextEditingValue value, _) {
              return Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: presets.map((String preset) {
                  return AppChoiceChip(
                    label: preset,
                    selected: value.text.trim() == preset,
                    enabled: !_saving,
                    onSelected: () => _description.text = preset,
                  );
                }).toList(),
              );
            },
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

    final BankAccountProvider provider = context.read<BankAccountProvider>();
    final double amount = Validators.parseAmount(_amount.text)!;

    final bool ok = _isWithdrawal
        ? await provider.withdraw(
            accountId: widget.account.id,
            amount: amount,
            date: _date,
            description: _description.text,
          )
        : await provider.deposit(
            accountId: widget.account.id,
            amount: amount,
            date: _date,
            description: _description.text,
          );

    if (!mounted) return;

    if (ok) {
      AppFeedback.success(
        context,
        _isWithdrawal ? 'Debit recorded' : 'Money added',
      );
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = provider.errorMessage ?? 'Could not record the transaction.';
      });
    }
  }
}
