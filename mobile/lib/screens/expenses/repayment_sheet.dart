import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/app_exception.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../models/bank_account.dart';
import '../../models/receivable.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/receivable_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';

/// Opens [RepaymentSheet] for [claim] and, once a repayment is saved, says
/// so and refreshes the balances it moved. True when one was saved.
Future<bool> recordRepayment(BuildContext context, ClaimSummary claim) async {
  final bool? saved = await showAppSheet<bool>(
    context: context,
    builder: (_) => RepaymentSheet(claim: claim),
  );
  if (saved != true || !context.mounted) return false;
  ClaimSummary? now;
  for (final ClaimSummary c in context.read<ReceivableProvider>().claims) {
    if (c.receivable.id == claim.receivable.id) now = c;
  }
  AppFeedback.success(
    context,
    now != null && !now.status.isOpen
        ? '${claim.receivable.person} has paid it all back'
        : 'Repayment recorded',
  );
  final String? userId = context.read<AuthProvider>().userId;
  final BankAccountProvider? accounts = context.read<BankAccountProvider?>();
  if (accounts != null && userId != null) {
    accounts.invalidate();
    await accounts.load(userId: userId, force: true);
  }
  if (context.mounted) context.read<DashboardProvider?>()?.invalidate();
  return true;
}

/// Active accounts, bank accounts first and the cash balance last — where
/// money paid back can arrive. [keepId] stays listed even when closed (the
/// account it was paid from).
List<BankAccountBalance> _accountChoices(BankAccountProvider accounts, String? keepId) {
  final List<BankAccountBalance> choices = accounts.balances
      .where((BankAccountBalance b) => b.account.isActive || b.account.id == keepId)
      .toList();
  return <BankAccountBalance>[
    ...choices.where((BankAccountBalance b) => !b.account.isCash),
    ...choices.where((BankAccountBalance b) => b.account.isCash),
  ];
}

double? _parseAmount(String text) {
  final double? value = double.tryParse(text.replaceAll(',', '').trim());
  return value == null || !value.isFinite ? null : value;
}

/// Money paid back for something paid for someone — a purchase or money
/// lent. Starts at what is still owed and never takes more, so the same
/// repayment cannot be recorded twice; paid in full, it shows as settled. One
/// credit on the account it arrived in: the balance goes up, and it is not
/// income. The web app's RepaymentSheet.
class RepaymentSheet extends StatefulWidget {
  const RepaymentSheet({super.key, required this.claim});

  final ClaimSummary claim;

  @override
  State<RepaymentSheet> createState() => _RepaymentSheetState();
}

class _RepaymentSheetState extends State<RepaymentSheet> {
  late final TextEditingController _amount =
      TextEditingController(text: Formatters.amountInput(amountLeft(widget.claim)));
  String? _accountId;
  DateTime _date = DateTime.now();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final String? sourceAccount = widget.claim.source?.accountId;
    final List<BankAccountBalance> choices =
        _accountChoices(context.read<BankAccountProvider>(), sourceAccount);
    _accountId = choices.any((BankAccountBalance b) => b.account.id == sourceAccount)
        ? sourceAccount
        : (choices.isEmpty ? null : choices.first.account.id);
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final ClaimSummary claim = widget.claim;
    final double? amount = _parseAmount(_amount.text);
    final String currency = context.read<SettingsProvider>().currency;
    final BankAccountBalance? balance = _accountId == null
        ? null
        : context.read<BankAccountProvider>().balanceFor(_accountId!);
    final RepaymentProblem? problem = repaymentProblem(claim, amount);
    final DateTime? paidOn = claim.source?.date;
    final String? error = problem != null
        ? repaymentProblemMessage(
            problem, Formatters.currency(amountLeft(claim), currencyCode: currency))
        : balance == null
            ? 'Choose the account it arrived in.'
            : paidOn != null && _date.isBefore(DateTime(paidOn.year, paidOn.month, paidOn.day))
                ? 'The repayment is dated before it was paid for them '
                    '(${Formatters.dayMonthYear(paidOn)}).'
                : null;
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<ReceivableProvider>().recordRepayment(
            claim: claim,
            account: balance!.account,
            amount: amount!,
            date: _date,
            currency: currency,
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = ErrorMapper.map(error).message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final String currency = settings.currency;
    final ClaimSummary claim = widget.claim;
    final List<BankAccountBalance> choices = _accountChoices(
      context.watch<BankAccountProvider>(),
      claim.source?.accountId,
    );
    final double? typed = _parseAmount(_amount.text);
    final double? after = typed != null && typed > 0 ? outstandingAfter(claim, typed) : null;
    final String money = Formatters.currency(amountLeft(claim), currencyCode: currency);

    return AppSheet(
      title: 'Repayment from ${claim.receivable.person}',
      subtitle: '$money left of '
          '${Formatters.currency(claim.principal, currencyCode: currency)} · not income',
      footer: AppButton.submit(
        label: 'Record repayment',
        busy: _busy,
        busyLabel: 'Saving…',
        onPressed: _busy || choices.isEmpty ? null : _save,
      ),
      children: <Widget>[
        AmountField(
          controller: _amount,
          symbol: settings.currencySymbol,
          enabled: !_busy,
          autofocus: false,
          tone: ToneColors.transfer(context),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          children: <Widget>[
            AppButton(
              label: 'All of it',
              size: AppButtonSize.small,
              variant: AppButtonVariant.tonal,
              onPressed: _busy
                  ? null
                  : () => setState(() => _amount.text = Formatters.amountInput(amountLeft(claim))),
            ),
            AppButton(
              label: 'Half',
              size: AppButtonSize.small,
              variant: AppButtonVariant.ghost,
              onPressed: _busy
                  ? null
                  : () => setState(() =>
                      _amount.text = Formatters.amountInput((amountLeft(claim) * 50).round() / 100)),
            ),
          ],
        ),
        if (after != null) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          Text(
            after < 0 && (-after * 100).round() <= (claim.allowance * 100).round()
                ? 'This settles it — ${Formatters.currency(-after, currencyCode: currency)} '
                    'over, within the rounding allowed on an EMI.'
                : after < 0
                ? 'That is more than the $money still owed.'
                : after == 0
                    ? 'This settles it.'
                    : '${Formatters.currency(after, currencyCode: currency)} will still be owed.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        if (choices.isEmpty)
          const AppNotice(
            message: 'Money paid back lands in one of your accounts, or your '
                'cash balance. Add one from Accounts first.',
          )
        else ...<Widget>[
          FieldLabel('Received in',
              isRequired: true, hint: _accountId == null ? 'Choose one' : null),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: choices
                .map((BankAccountBalance b) => AppChoiceChip(
                      label: '${b.account.displayLabel} · '
                          '${Formatters.currency(b.currentBalance, currencyCode: currency, compact: true)}',
                      icon: b.account.isCash
                          ? Icons.payments_outlined
                          : Icons.account_balance_outlined,
                      selected: b.account.id == _accountId,
                      enabled: !_busy,
                      onSelected: () => setState(() => _accountId = b.account.id),
                    ))
                .toList(),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('Date', isRequired: true),
        DateField(
          date: _date,
          enabled: !_busy,
          onChanged: (DateTime d) => setState(() => _date = d),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          InlineError(message: _error!),
        ],
      ],
    );
  }
}
