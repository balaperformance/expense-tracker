import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/validators.dart';
import '../../models/bank_account.dart';
import '../../models/money_transfer.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';

/// Moves money between two accounts the user owns.
///
/// Presented as a From → To route rather than as two unrelated dropdowns,
/// because a transfer is one movement with two ends. Slate accents throughout
/// — never income green — so nothing here can be mistaken for earning money.
class TransferSheet extends StatefulWidget {
  const TransferSheet({super.key, this.fromAccount});

  /// Pre-selects the sender when opened from a specific account.
  final BankAccount? fromAccount;

  @override
  State<TransferSheet> createState() => _TransferSheetState();
}

class _TransferSheetState extends State<TransferSheet> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _note = TextEditingController();

  String? _fromId;
  String? _toId;
  DateTime _date = AppDateUtils.today();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final List<BankAccount> accounts =
        context.read<BankAccountProvider>().accounts;

    _fromId = widget.fromAccount?.id ??
        (accounts.isNotEmpty ? accounts.first.id : null);

    // Default the destination to the first account that is not the sender, so
    // the sheet opens in a state that is already valid.
    for (final BankAccount account in accounts) {
      if (account.id != _fromId) {
        _toId = account.id;
        break;
      }
    }

    _amount.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final BankAccountProvider provider = context.watch<BankAccountProvider>();
    final SettingsProvider settings = context.watch<SettingsProvider>();

    final BankAccountBalance? source =
        _fromId == null ? null : provider.balanceFor(_fromId!);
    final BankAccountBalance? destination =
        _toId == null ? null : provider.balanceFor(_toId!);
    final double? typed = Validators.parseAmount(_amount.text);
    final String currency = settings.currency;

    return Form(
      key: _formKey,
      child: AppSheet(
        title: 'Transfer money',
        subtitle: 'Between your own accounts · not income or spending',
        footer: AppButton.submit(
          label: 'Transfer',
          icon: Icons.swap_horiz_rounded,
          busy: _saving,
          busyLabel: 'Transferring…',
          onPressed: _saving ? null : _save,
        ),
        children: <Widget>[
          AmountField(
            controller: _amount,
            symbol: settings.currencySymbol,
            enabled: !_saving,
            tone: ToneColors.transfer(context),
          ),
          const SizedBox(height: AppSpacing.lg),

          // The route. Two rows joined by a swap control, so the direction of
          // the money is legible before any figure is read.
          _RouteCard(
            accounts: provider.accounts,
            provider: provider,
            fromId: _fromId,
            toId: _toId,
            currency: currency,
            enabled: !_saving,
            onFromChanged: (String? id) => setState(() {
              _fromId = id;
              if (_toId == _fromId) _toId = null;
            }),
            onToChanged: (String? id) => setState(() => _toId = id),
            onSwap: _toId == null || _saving ? null : _swap,
          ),

          if (source != null && typed != null && typed > 0) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            _BalancePreview(
              source: source,
              destination: destination,
              amount: typed,
              currency: currency,
            ),
          ],

          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Date', isRequired: true),
          DateField(
            date: _date,
            enabled: !_saving,
            onChanged: (DateTime value) => setState(() => _date = value),
          ),
          const SizedBox(height: AppSpacing.lg),

          const FieldLabel('Note', hint: 'Optional'),
          TextFormField(
            controller: _note,
            enabled: !_saving,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'Rent set aside, savings top-up…',
              prefixIcon: Icon(
                Icons.short_text_rounded,
                size: AppSpacing.iconMd,
              ),
            ),
          ),

          if (_error != null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            InlineError(message: _error!),
          ],

          const SizedBox(height: AppSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                Icons.info_outline_rounded,
                size: AppSpacing.iconSm,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.xs + 1),
              Flexible(
                child: Text(
                  'Shows as $moneyTransferLabel on both statements.',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _swap() {
    setState(() {
      final String? previousFrom = _fromId;
      _fromId = _toId;
      _toId = previousFrom;
    });
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    final BankAccountProvider provider = context.read<BankAccountProvider>();
    final SettingsProvider settings = context.read<SettingsProvider>();

    // Every rule is re-checked inside the provider against a freshly derived
    // balance, so what is shown here is a courtesy, not the guard.
    final bool ok = await provider.transfer(
      fromAccountId: _fromId,
      toAccountId: _toId,
      amount: Validators.parseAmount(_amount.text),
      date: _date,
      note: _note.text,
      currencyCode: settings.currency,
    );

    if (!mounted) return;

    if (ok) {
      AppFeedback.success(context, 'Transfer complete');
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = provider.errorMessage ?? 'Could not complete the transfer.';
      });
    }
  }
}

/// From → To, with a swap control on the join.
class _RouteCard extends StatelessWidget {
  const _RouteCard({
    required this.accounts,
    required this.provider,
    required this.fromId,
    required this.toId,
    required this.currency,
    required this.enabled,
    required this.onFromChanged,
    required this.onToChanged,
    required this.onSwap,
  });

  final List<BankAccount> accounts;
  final BankAccountProvider provider;
  final String? fromId;
  final String? toId;
  final String currency;
  final bool enabled;
  final ValueChanged<String?> onFromChanged;
  final ValueChanged<String?> onToChanged;
  final VoidCallback? onSwap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        children: <Widget>[
          _AccountPickerRow(
            label: 'From',
            icon: Icons.north_east_rounded,
            tone: ToneColors.expense(context),
            accounts: accounts,
            provider: provider,
            selectedId: fromId,
            currency: currency,
            enabled: enabled,
            onChanged: onFromChanged,
          ),
          Row(
            children: <Widget>[
              const SizedBox(width: AppSpacing.avatarSm / 2),
              // Vertical connector, so the two rows read as one route.
              Container(
                width: 1,
                height: 28,
                color: theme.colorScheme.outline,
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Swap accounts',
                onPressed: onSwap,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.swap_vert_rounded),
              ),
            ],
          ),
          _AccountPickerRow(
            label: 'To',
            icon: Icons.south_west_rounded,
            tone: ToneColors.income(context),
            // Excluding the sender makes a same-account transfer unpickable,
            // rather than only rejected after the fact.
            accounts:
                accounts.where((BankAccount a) => a.id != fromId).toList(),
            provider: provider,
            selectedId: toId,
            currency: currency,
            enabled: enabled,
            onChanged: onToChanged,
          ),
        ],
      ),
    );
  }
}

/// One end of the route: label, account picker, and that account's balance.
class _AccountPickerRow extends StatelessWidget {
  const _AccountPickerRow({
    required this.label,
    required this.icon,
    required this.tone,
    required this.accounts,
    required this.provider,
    required this.selectedId,
    required this.currency,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final Color tone;
  final List<BankAccount> accounts;
  final BankAccountProvider provider;
  final String? selectedId;
  final String currency;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isValid = accounts.any((BankAccount a) => a.id == selectedId);
    final BankAccountBalance? balance =
        isValid ? provider.balanceFor(selectedId!) : null;

    return Row(
      children: <Widget>[
        IconWell(icon: icon, tone: tone, size: AppSpacing.avatarSm),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(label, style: theme.textTheme.labelSmall),
              const SizedBox(height: AppSpacing.xxs),
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: isValid ? selectedId : null,
                  isExpanded: true,
                  isDense: true,
                  hint: Text(
                    'Select an account',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  icon: const Icon(Icons.expand_more_rounded, size: 18),
                  style: theme.textTheme.titleMedium,
                  items: accounts.map((BankAccount account) {
                    return DropdownMenuItem<String>(
                      value: account.id,
                      child: Text(
                        account.displayLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                    );
                  }).toList(),
                  onChanged: enabled ? onChanged : null,
                ),
              ),
            ],
          ),
        ),
        if (balance != null) ...<Widget>[
          const SizedBox(width: AppSpacing.sm),
          MoneyText(
            balance.currentBalance,
            currency: currency,
            compact: true,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

/// What both balances become if this transfer goes through.
class _BalancePreview extends StatelessWidget {
  const _BalancePreview({
    required this.source,
    required this.destination,
    required this.amount,
    required this.currency,
  });

  final BankAccountBalance source;
  final BankAccountBalance? destination;
  final double amount;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double after = source.currentBalance - amount;
    final bool short = after < 0;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: short
            ? Border.all(color: ToneColors.expense(context).withOpacity(0.4))
            : null,
      ),
      child: Column(
        children: <Widget>[
          Text(
            'After this transfer',
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: AppSpacing.sm),
          _row(
            context,
            source.account.nickname,
            after,
            tone: short ? AmountTone.negative : AmountTone.neutral,
          ),
          if (destination != null) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            _row(
              context,
              destination!.account.nickname,
              destination!.currentBalance + amount,
            ),
          ],
          if (short) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'That is more than ${source.account.nickname} holds.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: ToneColors.expense(context),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    double value, {
    AmountTone tone = AmountTone.neutral,
  }) {
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        MoneyText(
          value,
          currency: currency,
          tone: tone,
          style: theme.textTheme.titleSmall,
        ),
      ],
    );
  }
}
