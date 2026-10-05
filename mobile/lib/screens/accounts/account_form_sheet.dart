import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/validators.dart';
import '../../models/bank_account.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/state_views.dart';

/// Create or edit a bank account — or, with [cash], the user's cash balance,
/// which needs only the cash on hand now: its name is always Cash.
///
/// Opening balance is editable after creation because people often add an
/// account before they know the figure. It is a starting point for the ledger,
/// not a running total, so changing it simply re-bases every derived balance.
class AccountFormSheet extends StatefulWidget {
  const AccountFormSheet({super.key, this.account, this.cash = false});

  final BankAccount? account;

  /// A new cash balance rather than a bank account.
  final bool cash;

  @override
  State<AccountFormSheet> createState() => _AccountFormSheetState();
}

class _AccountFormSheetState extends State<AccountFormSheet> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _bankName =
      TextEditingController(text: widget.account?.bankName ?? '');
  late final TextEditingController _nickname =
      TextEditingController(text: widget.account?.nickname ?? '');
  late final TextEditingController _last4 =
      TextEditingController(text: widget.account?.last4 ?? '');
  late final TextEditingController _opening = TextEditingController(
    text: widget.account == null ? '' : _trim(widget.account!.openingBalance),
  );

  bool _saving = false;
  String? _error;

  bool get _isEditing => widget.account != null;

  bool get _isCash => widget.account?.isCash ?? widget.cash;

  static String _trim(double value) {
    final String text = value.toStringAsFixed(2);
    return text.endsWith('.00') ? text.substring(0, text.length - 3) : text;
  }

  @override
  void dispose() {
    _bankName.dispose();
    _nickname.dispose();
    _last4.dispose();
    _opening.dispose();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SettingsProvider settings = context.watch<SettingsProvider>();

    return Form(
      key: _formKey,
      child: AppSheet(
        title: _isCash
            ? (_isEditing ? 'Edit cash balance' : 'Cash balance')
            : (_isEditing ? 'Edit account' : 'New bank account'),
        subtitle: _isCash
            ? 'The cash you have on hand'
            : (_isEditing ? widget.account!.bankName : 'Track its balance and statement'),
        // Delete lives in the header rather than as a second full-width
        // button, so the sheet keeps exactly one primary action.
        action: _isEditing
            ? IconButton(
                tooltip: 'Delete account',
                onPressed: _saving ? null : _delete,
                icon: const Icon(Icons.delete_outline_rounded),
                color: theme.colorScheme.error,
              )
            : null,
        footer: AppButton.submit(
          label: _isEditing
              ? 'Save changes'
              : (_isCash ? 'Add cash balance' : 'Add account'),
          busy: _saving,
          busyLabel: 'Saving…',
          onPressed: _saving ? null : _save,
        ),
        children: <Widget>[
          if (!_isCash) ...<Widget>[
            const FieldLabel('Bank', isRequired: true),
            TextFormField(
              controller: _bankName,
              autofocus: !_isEditing,
              enabled: !_saving,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              validator: (String? v) => Validators.required(v, 'Bank name'),
              decoration: const InputDecoration(
                hintText: 'HDFC, ICICI, SBI…',
                prefixIcon: Icon(
                  Icons.account_balance_outlined,
                  size: AppSpacing.iconMd,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            const FieldLabel('Nickname', isRequired: true),
            TextFormField(
              controller: _nickname,
              enabled: !_saving,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              validator: (String? v) => Validators.required(v, 'Nickname'),
              decoration: const InputDecoration(
                hintText: 'Salary account, Joint savings…',
                prefixIcon: Icon(Icons.badge_outlined, size: AppSpacing.iconMd),
              ),
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
              decoration: const InputDecoration(
                hintText: '4821',
                counterText: '',
                prefixIcon: Icon(Icons.tag_rounded, size: AppSpacing.iconMd),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
          ],

          FieldLabel(
            _isCash ? 'Cash on hand now' : 'Opening balance',
            isRequired: true,
          ),
          TextFormField(
            controller: _opening,
            autofocus: _isCash && !_isEditing,
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
              helperText: _isCash
                  ? 'Cash spending lowers it; ATM withdrawals and cash you '
                      'receive add to it.'
                  : 'The balance before any tracked transactions',
              helperMaxLines: 2,
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


  /// Unlike an expense amount, an opening balance may legitimately be zero or
  /// negative (an overdrawn account), so this is not [Validators.amount].
  String? _validateOpening(String? value) {
    final String input = (value ?? '').trim();
    if (input.isEmpty) return 'Opening balance is required';
    final double? parsed = double.tryParse(input);
    if (parsed == null) return 'Enter a valid number';
    if (parsed.abs() > 999999999) return 'Amount is too large';
    return null;
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    final BankAccountProvider provider = context.read<BankAccountProvider>();
    final double opening = double.parse(_opening.text.trim());

    // A cash balance is always called Cash and has no bank or card digits.
    final String bankName = _isCash ? BankAccount.cashName : _bankName.text;
    final String nickname = _isCash ? BankAccount.cashName : _nickname.text;
    final String last4 = _isCash ? '' : _last4.text;
    final bool ok = _isEditing
        ? await provider.update(
            widget.account!.copyWith(
              bankName: bankName,
              nickname: nickname,
              last4: last4,
              openingBalance: opening,
            ),
          )
        : await provider.create(
            bankName: bankName,
            nickname: nickname,
            last4: last4,
            openingBalance: opening,
            kind: _isCash ? AccountKind.cash : AccountKind.bank,
          );

    if (!mounted) return;

    if (ok) {
      AppFeedback.success(
        context,
        _isCash
            ? (_isEditing ? 'Cash balance updated' : 'Cash balance added')
            : (_isEditing ? 'Account updated' : 'Account added'),
      );
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = provider.errorMessage ?? 'Could not save the account.';
      });
    }
  }

  Future<void> _delete() async {
    final BankAccount account = widget.account!;
    final BankAccountProvider provider = context.read<BankAccountProvider>();
    final int movements = await provider.movementCount(account.id);
    final int cardPayments = await provider.cardPaymentCount(account.id);

    if (!mounted) return;
    // A bill payment is the same row on the card's statement, so it goes
    // from there too.
    final String cardNote = cardPayments == 0
        ? ''
        : ' That includes $cardPayments credit card bill '
            '${cardPayments == 1 ? 'payment' : 'payments'}, which will no '
            "longer reduce those cards' outstanding.";

    final bool confirmed = await AppFeedback.confirm(
      context,
      title: 'Delete "${account.nickname}"?',
      message: movements == 0
          ? 'This account has no transactions. This cannot be undone.'
          : 'Its $movements ${movements == 1 ? 'transaction' : 'transactions'} '
              'will be removed too.$cardNote Linked expenses and income are kept but '
              'revert to Cash / untracked. This cannot be undone.',
    );

    if (!confirmed || !mounted) return;

    setState(() => _saving = true);
    final bool ok = await provider.delete(account.id);

    if (!mounted) return;

    if (ok) {
      AppFeedback.success(context, 'Account deleted');
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = provider.errorMessage ?? 'Could not delete the account.';
      });
    }
  }
}
