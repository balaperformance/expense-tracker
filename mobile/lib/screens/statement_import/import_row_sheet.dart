import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../models/bank_account.dart';
import '../../models/credit_card.dart';
import '../../models/expense_category.dart';
import '../../providers/category_provider.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/statement_import_provider.dart';
import '../../services/schema_capabilities.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import '../../widgets/tag_field.dart';

/// The other side of a transfer, as the review item stores it.
class _Target {
  const _Target.account(String this.accountId)
      : type = 'account',
        cardId = null;
  const _Target.card(String this.cardId)
      : type = 'card',
        accountId = null;
  const _Target.cash()
      : type = 'cash',
        accountId = null,
        cardId = null;

  final String type;
  final String? accountId;
  final String? cardId;

  static _Target? of(ImportRow row) => switch (row.transferTargetType) {
        'account' when row.transferAccountId != null =>
          _Target.account(row.transferAccountId!),
        'card' when row.transferCardId != null => _Target.card(row.transferCardId!),
        'cash' => const _Target.cash(),
        _ => null,
      };

  Map<String, Object?> toJson() => <String, Object?>{
        'type': type,
        if (accountId != null) 'accountId': accountId,
        if (cardId != null) 'cardId': cardId,
      };

  @override
  bool operator ==(Object other) =>
      other is _Target &&
      other.type == type &&
      other.accountId == accountId &&
      other.cardId == cardId;

  @override
  int get hashCode => Object.hash(type, accountId, cardId);
}

/// The answer to "is this a possible duplicate?", applied to the review list
/// straight away — the sheet's own edits still wait for Done.
class _DuplicateAnswer extends StatelessWidget {
  const _DuplicateAnswer({required this.row, required this.provider});

  final ImportRow row;
  final StatementImportProvider provider;

  @override
  Widget build(BuildContext context) {
    if (row.duplicateDecision != null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: AppButton(
          label: 'Change answer',
          icon: Icons.refresh_rounded,
          size: AppButtonSize.small,
          variant: AppButtonVariant.ghost,
          onPressed: () => provider.decideDuplicate(row.id, null),
        ),
      );
    }
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: <Widget>[
        AppButton(
          label: "Yes, it's a duplicate",
          icon: Icons.content_copy_rounded,
          size: AppButtonSize.small,
          variant: AppButtonVariant.secondary,
          onPressed: () => provider.decideDuplicate(row.id, 'duplicate'),
        ),
        AppButton(
          label: 'No, keep it',
          icon: Icons.check_rounded,
          size: AppButtonSize.small,
          variant: AppButtonVariant.tonal,
          onPressed: () => provider.decideDuplicate(row.id, 'notDuplicate'),
        ),
      ],
    );
  }
}

/// Edits one statement row before import. Nothing is saved from here — only
/// the review list changes. Pops 'saved' or 'removed'.
class ImportRowSheet extends StatefulWidget {
  const ImportRowSheet({super.key, required this.row});

  final ImportRow row;

  @override
  State<ImportRowSheet> createState() => _ImportRowSheetState();
}

class _ImportRowSheetState extends State<ImportRowSheet> {
  static const Map<String, String> _kindLabels = <String, String>{
    'expense': 'Expense',
    'income': 'Income',
    'refund': 'Refund',
    'transfer': 'Transfer',
  };

  late final TextEditingController _description =
      TextEditingController(text: widget.row.description);
  late final TextEditingController _amount =
      TextEditingController(text: _trim(widget.row.amount));
  late final TextEditingController _payee =
      TextEditingController(text: widget.row.counterparty ?? '');
  late final TextEditingController _source = TextEditingController(
    text: widget.row.kind == 'income' ? (widget.row.category ?? '') : '',
  );
  late final TextEditingController _notes =
      TextEditingController(text: widget.row.notes ?? '');
  final TextEditingController _tagDraft = TextEditingController();
  late DateTime _date = widget.row.date;
  late bool _debit = widget.row.isDebit;
  late String _kind = widget.row.kind;
  late String? _categoryId = widget.row.categoryId;
  late String _bankAccountId = widget.row.bankAccountId;
  late String? _time = _hhmm(widget.row.transactionTime);
  late List<String> _tags = List<String>.of(widget.row.tags);
  late _Target? _target = _Target.of(widget.row);
  List<String> _debitKinds = const <String>['expense', 'transfer'];
  List<String> _creditKinds = const <String>['income', 'refund', 'transfer'];
  String? _error;

  static String _trim(double value) {
    final String text = value.toStringAsFixed(2);
    return text.endsWith('.00') ? text.substring(0, text.length - 3) : text;
  }

  /// "13:05:00" or "13:05" → "13:05"; anything else → null.
  static String? _hhmm(String? value) {
    final RegExpMatch? match =
        RegExp(r'^(\d{2}):(\d{2})').firstMatch(value?.trim() ?? '');
    return match == null ? null : '${match.group(1)}:${match.group(2)}';
  }

  @override
  void initState() {
    super.initState();
    // The valid kinds per direction are the engine's rule, not a copy.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final StatementImportProvider provider =
          context.read<StatementImportProvider>();
      try {
        final List<String> debit = await provider.kindsFor(true);
        final List<String> credit = await provider.kindsFor(false);
        if (!mounted) return;
        setState(() {
          if (debit.isNotEmpty) _debitKinds = debit;
          if (credit.isNotEmpty) _creditKinds = credit;
        });
      } catch (_) {
        // Keep the defaults, which match the engine today.
      }
    });
  }

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    _payee.dispose();
    _source.dispose();
    _notes.dispose();
    _tagDraft.dispose();
    super.dispose();
  }

  List<String> get _kinds => _debit ? _debitKinds : _creditKinds;

  bool get _taggable =>
      SchemaCapabilities.tags && (_kind == 'expense' || _kind == 'income');

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final StatementImportProvider provider =
        context.watch<StatementImportProvider>();
    final List<ExpenseCategory> categories =
        context.watch<CategoryProvider>().categories;
    final List<CreditCard> cards = context.watch<CreditCardProvider>().cards;
    // The row as it is now: a duplicate answered from here changes it while
    // the sheet is open.
    final ImportRow row = provider.rows.firstWhere(
      (ImportRow r) => r.id == widget.row.id,
      orElse: () => widget.row,
    );
    // A multi-account statement's row can move to another account; any other
    // row stays on the statement's.
    final List<BankAccount> accounts = provider.accounts
        .where((BankAccount a) => a.isActive || a.id == _bankAccountId)
        .toList();

    return AppSheet(
      title: 'Edit transaction',
      subtitle: 'Changes apply to this import only.',
      action: IconButton(
        tooltip: 'Remove from import',
        onPressed: () => Navigator.of(context).pop('removed'),
        icon: const Icon(Icons.delete_outline_rounded),
        color: theme.colorScheme.error,
      ),
      footer: AppButton.submit(label: 'Done', onPressed: _save),
      children: <Widget>[
        if (row.duplicateText != null) ...<Widget>[
          AppNotice(
            icon: Icons.content_copy_rounded,
            tone: ToneColors.warning(context),
            message: row.duplicateText!,
          ),
          if (row.possibleDuplicate) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            _DuplicateAnswer(row: row, provider: provider),
          ],
          const SizedBox(height: AppSpacing.md),
        ],
        if (row.issues.isNotEmpty) ...<Widget>[
          AppNotice(
            icon: Icons.fact_check_outlined,
            tone: ToneColors.warning(context),
            message: '${row.issues.join('. ')}.',
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (row.movable) ...<Widget>[
          FieldLabel(
            _debit ? 'Paid from' : 'Received in',
            isRequired: true,
            hint: _bankAccountId.isEmpty
                ? 'Choose one'
                : (row.accountStatus == 'matched' &&
                        _bankAccountId == row.bankAccountId
                    ? 'Matched'
                    : null),
          ),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: accounts
                .map((BankAccount a) => AppChoiceChip(
                      label: a.displayLabel,
                      icon: Icons.account_balance_outlined,
                      selected: a.id == _bankAccountId,
                      onSelected: () => setState(() {
                        _bankAccountId = a.id;
                        // A transfer cannot go to the account it is on.
                        if (_target?.accountId == a.id) _target = null;
                      }),
                    ))
                .toList(),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text('The statement says: ${row.sourceAccount?.isNotEmpty == true ? row.sourceAccount : 'no account'}',
              style: theme.textTheme.labelSmall),
          const SizedBox(height: AppSpacing.lg),
        ],
        const FieldLabel('Direction'),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<bool>(
            segments: const <ButtonSegment<bool>>[
              ButtonSegment<bool>(value: true, label: Text('Money out')),
              ButtonSegment<bool>(value: false, label: Text('Money in')),
            ],
            selected: <bool>{_debit},
            showSelectedIcon: false,
            onSelectionChanged: (Set<bool> v) => setState(() {
              _debit = v.first;
              if (!_kinds.contains(_kind)) _kind = _debit ? 'expense' : 'income';
              // Only money out can pay a card bill.
              if (!_debit && _target?.type == 'card') _target = null;
            }),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('Record as'),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: _kinds
              .map((String k) => AppChoiceChip(
                    label: _kindLabels[k] ?? k,
                    selected: k == _kind,
                    onSelected: () => setState(() {
                      _kind = k;
                      _error = null;
                    }),
                  ))
              .toList(),
        ),
        // On its own line: beside the label it does not fit a phone's width.
        if (_kind == 'refund' || _kind == 'transfer') ...<Widget>[
          const SizedBox(height: AppSpacing.xs),
          Text('Balance only — not income or spending',
              style: theme.textTheme.labelSmall),
        ],
        if (_kind == 'transfer') ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          ..._transferTarget(theme, accounts, cards),
        ],
        const SizedBox(height: AppSpacing.lg),
        AmountField(
          controller: _amount,
          symbol: settings.currencySymbol,
          autofocus: false,
          tone: _kind == 'transfer'
              ? ToneColors.transfer(context)
              : (_debit ? ToneColors.expense(context) : ToneColors.income(context)),
        ),
        if (_kind == 'expense' || _kind == 'income') ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          FieldLabel(_kind == 'expense' ? 'Paid to' : 'Received from',
              hint: 'Optional'),
          TextField(
            controller: _payee,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(hintText: 'Payee or payer'),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('Description', isRequired: true),
        TextField(controller: _description),
        const SizedBox(height: AppSpacing.lg),
        FieldLabel(row.hasTime ? 'Date & time' : 'Date', isRequired: true),
        DateField(
          date: _date,
          onChanged: (DateTime value) => setState(() => _date = value),
        ),
        if (row.hasTime) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          SelectField(
            value: _time == null ? null : Formatters.clockTime(_time!),
            placeholder: 'No time on the statement',
            icon: Icons.schedule_rounded,
            onTap: _pickTime,
            trailing: _time == null
                ? null
                : IconButton(
                    tooltip: 'Clear time',
                    icon: const Icon(Icons.close_rounded, size: AppSpacing.iconSm),
                    onPressed: () => setState(() => _time = null),
                  ),
          ),
        ],
        if (_kind == 'expense') ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Category', isRequired: true),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: categories
                .map((ExpenseCategory c) => AppChoiceChip(
                      label: c.name,
                      selected: c.id == _categoryId,
                      tone: AppColors.readableOn(
                        AppColors.fromHex(c.color),
                        theme.brightness,
                      ),
                      avatar: CategoryAvatar(icon: c.icon, color: c.color, size: 20),
                      onSelected: () => setState(() => _categoryId = c.id),
                    ))
                .toList(),
          ),
        ],
        if (_kind == 'income') ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Source', hint: 'Optional'),
          TextField(
            controller: _source,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(hintText: 'Salary, Interest…'),
          ),
        ],
        if (row.hasNotes && (_kind == 'expense' || _kind == 'income')) ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Notes', hint: 'Optional'),
          TextField(
            controller: _notes,
            minLines: 1,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Notes'),
          ),
        ],
        if (_taggable) ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Tags', hint: 'Optional'),
          TagField(
            tags: _tags,
            draft: _tagDraft,
            onChanged: (List<String> next) => setState(() => _tags = next),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        _asPrinted(theme, row),
        if (_error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          InlineError(message: _error!),
        ],
      ],
    );
  }

  /// Where a transfer went (money out) or came from (money in): another of
  /// the user's accounts, a credit card (its bill), or cash.
  List<Widget> _transferTarget(
    ThemeData theme,
    List<BankAccount> accounts,
    List<CreditCard> cards,
  ) {
    // Both legs of a transfer to an account need migration 003.
    final List<BankAccount> others = SchemaCapabilities.transfers
        ? accounts
            .where((BankAccount a) => a.isActive && a.id != _bankAccountId)
            .toList()
        : const <BankAccount>[];
    final List<CreditCard> payable = _debit && SchemaCapabilities.creditCards
        ? cards.where((CreditCard c) => c.isActive).toList()
        : const <CreditCard>[];
    return <Widget>[
      FieldLabel(_debit ? 'Transfer to' : 'Transfer from', isRequired: true),
      Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: <Widget>[
          for (final BankAccount a in others)
            AppChoiceChip(
              label: a.displayLabel,
              icon: a.isCash
                  ? Icons.payments_outlined
                  : Icons.account_balance_outlined,
              selected: _target == _Target.account(a.id),
              onSelected: () => setState(() {
                _target = _Target.account(a.id);
                _error = null;
              }),
            ),
          for (final CreditCard c in payable)
            AppChoiceChip(
              label: '${c.cardName} bill',
              icon: Icons.credit_card_rounded,
              selected: _target == _Target.card(c.id),
              onSelected: () => setState(() {
                _target = _Target.card(c.id);
                _error = null;
              }),
            ),
          AppChoiceChip(
            // With a cash balance kept, cash is one of the accounts above.
            label: BankAccount.cashOf(accounts) != null
                ? 'An account not tracked here'
                : 'Cash or other',
            icon: BankAccount.cashOf(accounts) != null
                ? Icons.account_balance_wallet_outlined
                : Icons.payments_outlined,
            selected: _target == const _Target.cash(),
            onSelected: () => setState(() {
              _target = const _Target.cash();
              _error = null;
            }),
          ),
        ],
      ),
      const SizedBox(height: AppSpacing.xs),
      Text(
        _target?.type == 'account'
            ? 'Both accounts are updated; neither side counts as income or spending.'
            : _target?.type == 'card'
                ? "Recorded as this card's bill payment — never an expense."
                : 'Only this balance changes.',
        style: theme.textTheme.labelSmall,
      ),
    ];
  }

  /// What the statement printed, unchanged, to check the row against.
  Widget _asPrinted(ThemeData theme, ImportRow row) {
    final List<String> lines = <String>[
      row.rawDescription.isNotEmpty ? row.rawDescription : '—',
      if (row.upiId != null) 'UPI ID: ${row.upiId}',
      if (row.upiId != null && row.reference != null)
        'UPI Ref No: ${row.reference}',
    ];
    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('As printed on the statement', style: theme.textTheme.labelSmall),
          const SizedBox(height: AppSpacing.xs),
          for (final String line in lines)
            Text(line, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Future<void> _pickTime() async {
    final List<String> parts = (_time ?? '12:00').split(':');
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.tryParse(parts.first) ?? 12,
        minute: int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _time =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}');
  }

  Future<void> _save() async {
    final ImportRow row = widget.row;
    final double? value = Validators.parseAmount(_amount.text);
    if (value == null || value <= 0 || value > 999999999) {
      setState(() => _error = 'Enter the amount shown on the statement.');
      return;
    }
    if (_description.text.trim().isEmpty) {
      setState(() => _error = 'Add a description.');
      return;
    }
    if (row.movable && _bankAccountId.isEmpty) {
      setState(() => _error = _debit
          ? 'Choose the account it was paid from.'
          : 'Choose the account it was received in.');
      return;
    }
    if (_kind == 'expense' && _categoryId == null) {
      setState(() => _error = 'Choose a category for this expense.');
      return;
    }
    if (_kind == 'transfer' && _target == null) {
      setState(() => _error = _debit
          ? 'Choose where the money went.'
          : 'Choose where the money came from.');
      return;
    }
    final String description = _description.text.trim();
    final String payee = _payee.text.trim();
    final String source = _source.text.trim();
    final String notes = _notes.text.trim();
    // A tag typed but not confirmed counts too, cleaned as the database
    // cleans it.
    final List<String> tags = TagField.withDraft(_tags, _tagDraft.text);
    final _Target? before = _Target.of(row);
    final Map<String, Object?> patch = <String, Object?>{
      if (description != row.description) 'description': description,
      if ((value * 100).round() != (row.amount * 100).round()) 'amount': value,
      if (!AppDateUtils.toDateString(_date).startsWith(row.isoDate))
        'transactionDate': AppDateUtils.toDateString(_date),
      if (_debit != row.isDebit) 'transactionType': _debit ? 'debit' : 'credit',
      if (_kind != row.kind) 'kind': _kind,
      if (_kind == 'expense' && _categoryId != row.categoryId)
        'categoryId': _categoryId,
      if (_kind == 'income' && source != (row.category ?? ''))
        'category': source.isEmpty ? null : source,
      if (payee != (row.counterparty ?? ''))
        'counterparty': payee.isEmpty ? null : payee,
      if (row.movable && _bankAccountId != row.bankAccountId)
        'bankAccountId': _bankAccountId,
      if (_kind == 'transfer' && _target != before)
        'transferTarget': _target?.toJson(),
      if (row.hasTime && _time != _hhmm(row.transactionTime))
        'transactionTime': _time,
      if (row.hasNotes &&
          (_kind == 'expense' || _kind == 'income') &&
          (notes.isEmpty ? null : notes) != row.notes)
        'notes': notes.isEmpty ? null : notes,
      if (_taggable && tags.join('\n') != row.tags.join('\n')) 'tags': tags,
    };
    if (patch.isNotEmpty) {
      await context.read<StatementImportProvider>().edit(row.id, patch);
    }
    if (mounted) Navigator.of(context).pop('saved');
  }
}
