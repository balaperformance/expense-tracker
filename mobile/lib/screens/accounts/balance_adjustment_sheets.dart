import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../models/balance_adjustment.dart';
import '../../models/bank_account.dart';
import '../../providers/auth_provider.dart';
import '../../providers/balance_adjustment_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/statement_provider.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/surface_card.dart';

/// Everything that shows a balance is out of date once an adjustment is
/// added or removed: the database rewrote the account's adjustment rows.
void refreshAfterAdjustment(BuildContext context) {
  final String? userId = context.read<AuthProvider>().userId;
  final BankAccountProvider accounts = context.read<BankAccountProvider>()..invalidate();
  if (userId != null) accounts.load(userId: userId, force: true);
  context.read<StatementProvider>().load(force: true);
  context.read<DashboardProvider>().invalidate();
}

/// A signed amount as typed: digits with up to two decimals, and a leading
/// minus for an overdrawn account.
final List<TextInputFormatter> signedAmountInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d{0,2}')),
];

/// The figure typed into "Actual balance", or null when it is not a number.
double? parseSignedAmount(String text) {
  final String clean = text.trim().replaceAll(',', '');
  if (clean.isEmpty || clean == '-') return null;
  final double? value = double.tryParse(clean);
  if (value == null || value.abs() >= 1000000000000) return null;
  return value;
}

/// The balance and history of adjustments on an account's statement, with
/// the "Adjust balance" action next to the balance.
class AccountBalanceAdjustments extends StatelessWidget {
  const AccountBalanceAdjustments({super.key, required this.account});

  final BankAccount account;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String currency = context.watch<SettingsProvider>().currency;
    final double? balance =
        context.watch<BankAccountProvider>().balanceFor(account.id)?.currentBalance;
    final List<BalanceAdjustment> history =
        context.watch<BalanceAdjustmentProvider>().forAccount(account.id);
    String format(double v) => Formatters.currency(v, currencyCode: currency);

    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.sm, AppSpacing.md),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('Balance does not match the bank?', style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
                AppButton(
                  label: 'Adjust balance',
                  icon: Icons.tune_rounded,
                  size: AppButtonSize.small,
                  variant: AppButtonVariant.tonal,
                  onPressed: balance == null
                      ? null
                      : () => showAppSheet<bool>(
                            context: context,
                            builder: (_) => AdjustBalanceSheet(account: account, currentBalance: balance),
                          ),
                ),
              ],
            ),
          ),
          if (history.isNotEmpty) ...<Widget>[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Balance adjustments', style: theme.textTheme.titleSmall),
                  Text(
                    '${history.length} ${history.length == 1 ? 'adjustment' : 'adjustments'}',
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
            for (int i = 0; i < history.length; i++) ...<Widget>[
              if (i > 0) const Divider(height: 1, indent: AppSpacing.rowDividerIndent),
              AppListRow(
                leading: const AdjustmentAvatar(size: 30),
                title: 'Set to ${format(history[i].targetBalance)}',
                subtitle: adjustmentHistorySubtitle(
                  history[i],
                  format: format,
                  date: Formatters.dayMonthYear,
                ),
                showChevron: true,
                onTap: () => openBalanceAdjustment(context, account, history[i]),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Opens an adjustment's details, from its history row or its ledger row.
Future<void> openBalanceAdjustment(
  BuildContext context,
  BankAccount account,
  BalanceAdjustment adjustment,
) =>
    showAppSheet<bool>(
      context: context,
      builder: (_) => BalanceAdjustmentSheet(account: account, adjustment: adjustment),
    );

/// Sets an account's balance to what the bank shows. Nothing is changed or
/// deleted: the database records the difference as one adjustment row.
class AdjustBalanceSheet extends StatefulWidget {
  const AdjustBalanceSheet({super.key, required this.account, required this.currentBalance});

  final BankAccount account;

  /// The app's balance now: what the live line compares against.
  final double currentBalance;

  @override
  State<AdjustBalanceSheet> createState() => _AdjustBalanceSheetState();
}

class _AdjustBalanceSheetState extends State<AdjustBalanceSheet> {
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _remarks = TextEditingController();
  DateTime _date = AppDateUtils.today();
  bool _submitted = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _remarks.dispose();
    super.dispose();
  }

  double? get _target => parseSignedAmount(_amount.text);

  bool get _future => _date.isAfter(AppDateUtils.today());

  Future<void> _save() async {
    setState(() => _submitted = true);
    final double? target = _target;
    if (target == null || _future) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final BalanceAdjustmentProvider provider = context.read<BalanceAdjustmentProvider>();
    final bool ok = await provider.adjust(
      accountId: widget.account.id,
      balance: target,
      date: _date,
      remarks: _remarks.text,
    );
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _saving = false;
        _error = provider.errorMessage ?? 'Could not adjust the balance.';
      });
      return;
    }
    final String currency = context.read<SettingsProvider>().currency;
    refreshAfterAdjustment(context);
    AppFeedback.success(context, 'Balance set to ${Formatters.currency(target, currencyCode: currency)}');
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SettingsProvider settings = context.watch<SettingsProvider>();
    String format(double v) => Formatters.currency(v, currencyCode: settings.currency);
    final double? target = _target;
    final String? amountError =
        _submitted && target == null ? 'Enter the balance shown by your bank.' : null;
    final String? dateError = _submitted && _future ? 'The date cannot be in the future.' : null;
    final TextStyle? errorStyle = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error);

    return AppSheet(
      title: 'Adjust balance',
      subtitle: widget.account.displayLabel,
      footer: AppButton.submit(
        label: 'Save adjustment',
        busy: _saving,
        onPressed: _saving ? null : _save,
      ),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text('Balance in the app', style: theme.textTheme.bodySmall)),
            MoneyText(widget.currentBalance, currency: settings.currency, style: theme.textTheme.titleSmall),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('Actual balance', isRequired: true),
        TextField(
          key: const ValueKey<String>('adjust-balance-amount'),
          controller: _amount,
          enabled: !_saving,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          inputFormatters: signedAmountInputFormatters,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: '0',
            prefixText: '${settings.currencySymbol} ',
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        // Only against today's balance: for an earlier date the database
        // works out the balance at that point, which this screen does not have.
        if (amountError != null)
          Text(amountError, style: errorStyle)
        else if (target != null && _date == AppDateUtils.today())
          Text(
            adjustmentEffectText(
              (toCents(target) - toCents(widget.currentBalance)) / 100,
              format,
            ),
            style: theme.textTheme.labelSmall,
          ),
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('Date', isRequired: true),
        DateField(
          date: _date,
          enabled: !_saving,
          onChanged: (DateTime v) => setState(() => _date = v),
        ),
        const SizedBox(height: AppSpacing.xs),
        // Under the field: beside the label it does not fit at 360 dp.
        Text(
          dateError ?? 'The day the bank showed this balance',
          style: dateError != null ? errorStyle : theme.textTheme.labelSmall,
        ),
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('Remarks', hint: 'Optional'),
        TextField(
          controller: _remarks,
          enabled: !_saving,
          maxLength: balanceAdjustmentRemarksMax,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'e.g. Matched with the bank app'),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          Text(_error!, style: errorStyle),
        ],
        const SizedBox(height: AppSpacing.md),
        const AppNotice(
          message: 'Transactions after this date count from the new balance. '
              'No transaction is changed or deleted.',
        ),
      ],
    );
  }
}

/// One adjustment: what was set, against what, and removing it.
class BalanceAdjustmentSheet extends StatefulWidget {
  const BalanceAdjustmentSheet({super.key, required this.account, required this.adjustment});

  final BankAccount account;
  final BalanceAdjustment adjustment;

  @override
  State<BalanceAdjustmentSheet> createState() => _BalanceAdjustmentSheetState();
}

class _BalanceAdjustmentSheetState extends State<BalanceAdjustmentSheet> {
  bool _removing = false;

  Future<void> _remove() async {
    final bool confirmed = await AppFeedback.confirm(
      context,
      title: 'Remove adjustment?',
      message: 'The balance goes back to what the recorded transactions add up to. '
          'No transaction is changed.',
      confirmLabel: 'Remove',
    );
    if (!confirmed || !mounted) return;
    setState(() => _removing = true);
    final BalanceAdjustmentProvider provider = context.read<BalanceAdjustmentProvider>();
    final bool ok = await provider.remove(widget.adjustment);
    if (!mounted) return;
    if (!ok) {
      setState(() => _removing = false);
      AppFeedback.error(context, provider.errorMessage ?? 'Could not remove the adjustment.');
      return;
    }
    refreshAfterAdjustment(context);
    AppFeedback.success(context, 'Adjustment removed');
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final String currency = context.watch<SettingsProvider>().currency;
    String format(double v) => Formatters.currency(v, currencyCode: currency);
    final BalanceAdjustment a = widget.adjustment;

    return AppSheet(
      title: 'Balance adjustment',
      subtitle: widget.account.displayLabel,
      footer: AppButton.submit(
        label: 'Remove',
        variant: AppButtonVariant.danger,
        busy: _removing,
        onPressed: _removing ? null : _remove,
      ),
      children: <Widget>[
        _Fact(label: 'Date', value: Formatters.dayMonthYear(a.adjustedOn)),
        _Fact(label: 'Balance set to', value: format(a.targetBalance)),
        _Fact(label: 'App balance then', value: format(a.previousBalance)),
        _Fact(label: 'Difference', value: signedDifference(a.difference, format)),
        if (a.remarks != null) _Fact(label: 'Remarks', value: a.remarks!),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
          const SizedBox(width: AppSpacing.md),
          Flexible(
            child: Text(value, style: theme.textTheme.titleSmall, textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }
}
