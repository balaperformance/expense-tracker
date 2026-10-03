import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/validators.dart';
import '../../models/expense_category.dart';
import '../../providers/category_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/statement_import_provider.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';

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
  late DateTime _date = widget.row.date;
  late bool _debit = widget.row.isDebit;
  late String _kind = widget.row.kind;
  late String? _categoryId = widget.row.categoryId;
  List<String> _debitKinds = const <String>['expense', 'transfer'];
  List<String> _creditKinds = const <String>['income', 'refund', 'transfer'];
  String? _error;

  static String _trim(double value) {
    final String text = value.toStringAsFixed(2);
    return text.endsWith('.00') ? text.substring(0, text.length - 3) : text;
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
    super.dispose();
  }

  List<String> get _kinds => _debit ? _debitKinds : _creditKinds;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final List<ExpenseCategory> categories =
        context.watch<CategoryProvider>().categories;
    final ImportRow row = widget.row;

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
        if (row.rawDescription.isNotEmpty &&
            row.rawDescription != row.description) ...<Widget>[
          Text('On the statement: ${row.rawDescription}',
              style: theme.textTheme.labelSmall),
          const SizedBox(height: AppSpacing.md),
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
            }),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        FieldLabel(
          'Record as',
          hint: _kind == 'refund' || _kind == 'transfer'
              ? 'Balance only — not income or spending'
              : null,
        ),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: _kinds
              .map((String k) => AppChoiceChip(
                    label: _kindLabels[k] ?? k,
                    selected: k == _kind,
                    onSelected: () => setState(() => _kind = k),
                  ))
              .toList(),
        ),
        const SizedBox(height: AppSpacing.lg),
        AmountField(
          controller: _amount,
          symbol: settings.currencySymbol,
          autofocus: false,
          tone: _debit ? ToneColors.expense(context) : ToneColors.income(context),
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
        const FieldLabel('Date', isRequired: true),
        DateField(
          date: _date,
          onChanged: (DateTime value) => setState(() => _date = value),
        ),
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
        if (_error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          InlineError(message: _error!),
        ],
      ],
    );
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
    if (_kind == 'expense' && _categoryId == null) {
      setState(() => _error = 'Choose a category for this expense.');
      return;
    }
    final String description = _description.text.trim();
    final String payee = _payee.text.trim();
    final String source = _source.text.trim();
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
    };
    if (patch.isNotEmpty) {
      await context.read<StatementImportProvider>().edit(row.id, patch);
    }
    if (mounted) Navigator.of(context).pop('saved');
  }
}
