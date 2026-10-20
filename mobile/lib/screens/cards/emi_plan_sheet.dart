import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../models/credit_card.dart';
import '../../models/emi_plan.dart';
import '../../models/expense_category.dart';
import '../../providers/category_provider.dart';
import '../../providers/credit_card_provider.dart';
import '../../providers/receivable_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';
import '../../widgets/paid_for_field.dart';

enum _Payer { own, someone }

/// Add or edit an EMI plan: whose it is, what was bought, the monthly
/// figures. Nothing about what is owed is typed here — that comes from the
/// instalments billed on the card.
///
/// Saved mode pops true after writing. Draft mode ([draft] true, used by the
/// statement import for a group's new plan) pops the [EmiPlan] (id empty)
/// instead of saving: it is created with the rows that name it when the
/// import runs.
class EmiPlanSheet extends StatefulWidget {
  const EmiPlanSheet({
    super.key,
    required this.card,
    this.plan,
    this.initial,
    this.draft = false,
  });

  final CreditCard card;

  /// Editing: the plan. Null: a new one.
  final EmiPlan? plan;

  /// What a new plan starts from (an instalment's figures, a guessed title).
  final EmiPlan? initial;
  final bool draft;

  @override
  State<EmiPlanSheet> createState() => _EmiPlanSheetState();
}

class _EmiPlanSheetState extends State<EmiPlanSheet> {
  EmiPlan? get _seed => widget.plan ?? widget.initial;

  late final TextEditingController _title =
      TextEditingController(text: _seed?.title ?? '');
  late final TextEditingController _person =
      TextEditingController(text: _seed?.person ?? '');
  late final TextEditingController _purchase =
      TextEditingController(text: _money(_seed?.purchaseAmount));
  late final TextEditingController _monthly =
      TextEditingController(text: _money(_seed?.monthlyAmount));
  late final TextEditingController _tenure =
      TextEditingController(text: _seed?.tenureMonths?.toString() ?? '');
  late final TextEditingController _reference =
      TextEditingController(text: _seed?.reference ?? '');
  late final TextEditingController _notes =
      TextEditingController(text: widget.plan?.notes ?? '');

  late _Payer _payer = _seed?.person != null ? _Payer.someone : _Payer.own;
  late bool _includeCharges = _seed?.includeCharges ?? true;
  late DateTime? _startDate = _seed?.startDate;
  late String? _categoryId = _seed?.categoryId;
  late bool _closed = widget.plan?.isClosed ?? false;
  bool _submitted = false;
  bool _saving = false;
  String? _error;

  static String _money(double? value) =>
      value == null || value <= 0 ? '' : Formatters.amountInput(value);

  @override
  void dispose() {
    _title.dispose();
    _person.dispose();
    _purchase.dispose();
    _monthly.dispose();
    _tenure.dispose();
    _reference.dispose();
    _notes.dispose();
    super.dispose();
  }

  double? _amount(TextEditingController c) {
    final String text = c.text.trim();
    if (text.isEmpty) return null;
    return double.tryParse(text);
  }

  String? _amountError(TextEditingController c, String label) {
    final String text = c.text.trim();
    if (text.isEmpty) return null;
    final double? value = double.tryParse(text);
    if (value == null || value <= 0) return 'Enter a valid $label';
    if (value > 999999999) return 'Amount is too large';
    return null;
  }

  int? get _tenureValue =>
      _tenure.text.trim().isEmpty ? null : int.tryParse(_tenure.text.trim());

  String? get _tenureError {
    if (_tenure.text.trim().isEmpty) return null;
    final int? months = _tenureValue;
    return months == null || months < 1 || months > 120
        ? 'Enter the number of months (1–120)'
        : null;
  }

  EmiPlan _draft() => EmiPlan(
        id: widget.plan?.id ?? '',
        userId: widget.plan?.userId ?? '',
        cardId: widget.card.id,
        title: _title.text.trim(),
        reference: _reference.text.trim().isEmpty ? null : _reference.text.trim(),
        person: _payer == _Payer.someone && _person.text.trim().isNotEmpty
            ? _person.text.trim()
            : null,
        includeCharges: _payer == _Payer.someone ? _includeCharges : true,
        purchaseAmount: _amount(_purchase),
        monthlyAmount: _amount(_monthly),
        tenureMonths: _tenureValue,
        startDate: _startDate,
        categoryId: _categoryId,
        notes: _notes.text,
        isClosed: _closed,
        createdAt: widget.plan?.createdAt,
      );

  bool get _valid =>
      _title.text.trim().isNotEmpty &&
      (_payer == _Payer.own || _person.text.trim().isNotEmpty) &&
      _amountError(_purchase, 'x') == null &&
      _amountError(_monthly, 'x') == null &&
      _tenureError == null;

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() => _submitted = true);
    if (!_valid) return;
    if (widget.draft) {
      Navigator.of(context).pop(_draft());
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final CreditCardProvider provider = context.read<CreditCardProvider>();
    final String? id = await provider.savePlan(_draft());
    if (!mounted) return;
    if (id != null) {
      context.read<ReceivableProvider?>()?.invalidate();
      AppFeedback.success(
          context, widget.plan == null ? 'EMI plan added' : 'EMI plan updated');
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = provider.errorMessage ?? 'Could not save the EMI plan.';
      });
    }
  }

  Future<void> _delete() async {
    final EmiPlan? plan = widget.plan;
    if (plan == null) return;
    final CreditCardProvider provider = context.read<CreditCardProvider>();
    final ({int components, int repayments})? activity =
        await provider.planActivity(plan.id);
    if (!mounted) return;
    final String detail = activity == null
        ? ' Its instalment rows stay on the card as ordinary purchases and charges.'
        : ' Its ${activity.components} instalment '
            '${activity.components == 1 ? 'row stays' : 'rows stay'} on the card '
            'as ordinary purchases and charges.'
            '${activity.repayments > 0 ? ' ${activity.repayments} ${activity.repayments == 1 ? 'repayment stays' : 'repayments stay'} as plain money in.' : ''}';
    final bool ok = await AppFeedback.confirm(
      context,
      title: 'Delete EMI plan?',
      message: '${plan.title} will no longer be tracked as an EMI'
          '${plan.person != null ? ' owed by ${plan.person}' : ''}.$detail',
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    final bool done = await provider.deletePlan(plan.id);
    if (!mounted) return;
    if (done) {
      context.read<ReceivableProvider?>()?.invalidate();
      AppFeedback.success(context, 'EMI plan deleted');
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = provider.errorMessage ?? 'Could not delete the EMI plan.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final List<ExpenseCategory> categories =
        context.watch<CategoryProvider>().categories;
    final List<String> people =
        context.watch<ReceivableProvider?>()?.people ?? const <String>[];
    final bool editing = widget.plan != null;
    final String? titleError = _submitted && _title.text.trim().isEmpty
        ? 'What was bought is required'
        : null;
    final bool personMissing = _submitted &&
        _payer == _Payer.someone &&
        _person.text.trim().isEmpty;

    return AppSheet(
      title: editing ? 'Edit EMI plan' : 'EMI plan',
      subtitle: widget.card.displayLabel,
      action: editing && !widget.draft
          ? IconButton(
              tooltip: 'Delete EMI plan',
              onPressed: _saving ? null : _delete,
              icon: const Icon(Icons.delete_outline_rounded),
              color: theme.colorScheme.error,
            )
          : null,
      footer: Row(
        children: <Widget>[
          const Spacer(),
          AppButton(
            label: widget.draft
                ? 'Use this plan'
                : editing
                    ? 'Save'
                    : 'Add plan',
            busy: _saving,
            busyLabel: 'Saving…',
            onPressed: _saving ? null : _submit,
          ),
        ],
      ),
      children: <Widget>[
        FieldLabel('What was bought', isRequired: true, hint: titleError),
        TextField(
          controller: _title,
          enabled: !_saving,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Laptop, phone, sofa…',
            prefixIcon: Icon(Icons.storefront_outlined, size: AppSpacing.iconMd),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: AppSpacing.lg),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<_Payer>(
            segments: const <ButtonSegment<_Payer>>[
              ButtonSegment<_Payer>(value: _Payer.own, label: Text('My own EMI')),
              ButtonSegment<_Payer>(
                  value: _Payer.someone, label: Text('Someone else pays')),
            ],
            selected: <_Payer>{_payer},
            showSelectedIcon: false,
            onSelectionChanged: _saving
                ? null
                : (Set<_Payer> v) => setState(() => _payer = v.first),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (_payer == _Payer.someone) ...<Widget>[
          _PersonInput(
            controller: _person,
            people: people,
            missing: personMissing,
            enabled: !_saving,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.md),
          const FieldLabel('They pay back'),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(
                    value: true, label: Text('Principal, interest & GST')),
                ButtonSegment<bool>(value: false, label: Text('Principal only')),
              ],
              selected: <bool>{_includeCharges},
              showSelectedIcon: false,
              onSelectionChanged: _saving
                  ? null
                  : (Set<bool> v) => setState(() => _includeCharges = v.first),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          const AppNotice(
            icon: Icons.handshake_outlined,
            message: "Each month's instalment is added to what they owe as the "
                'card bills it. The principal stays out of your spending, and '
                'what they send you is a repayment — never income.',
          ),
        ] else
          const AppNotice(
            message: 'The principal counts as your spending month by month; '
                'the interest and GST are card charges.',
          ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: _AmountInput(
                label: 'Purchase amount',
                controller: _purchase,
                symbol: settings.currencySymbol,
                enabled: !_saving,
                error: _submitted ? _amountError(_purchase, 'purchase amount') : null,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _AmountInput(
                label: 'Monthly EMI',
                controller: _monthly,
                symbol: settings.currencySymbol,
                enabled: !_saving,
                error: _submitted ? _amountError(_monthly, 'monthly amount') : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  FieldLabel('Tenure (months)',
                      hint: _submitted ? _tenureError : null),
                  TextField(
                    controller: _tenure,
                    enabled: !_saving,
                    keyboardType: TextInputType.number,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(3),
                    ],
                    decoration: const InputDecoration(hintText: '12'),
                    onChanged: (_) => setState(() {}),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const FieldLabel('First instalment'),
                  SelectField(
                    value: _startDate == null
                        ? null
                        : Formatters.dayMonthYear(_startDate!),
                    placeholder: 'Month it started',
                    icon: Icons.calendar_today_rounded,
                    enabled: !_saving,
                    onTap: _pickStart,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('Category for the principal',
            hint: 'Each month’s principal is filed here'),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: categories
              .map((ExpenseCategory c) => AppChoiceChip(
                    label: c.name,
                    selected: c.id == _categoryId,
                    enabled: !_saving,
                    avatar: CategoryAvatar(icon: c.icon, color: c.color, size: 22),
                    onSelected: () => setState(
                        () => _categoryId = c.id == _categoryId ? null : c.id),
                  ))
              .toList(),
        ),
        const SizedBox(height: AppSpacing.lg),
        const FieldLabel('EMI reference',
            hint: 'From the card statement, if printed'),
        TextField(
          controller: _reference,
          enabled: !_saving,
          decoration: const InputDecoration(hintText: 'Loan or EMI number'),
        ),
        if (!widget.draft) ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          const FieldLabel('Notes'),
          TextField(
            controller: _notes,
            enabled: !_saving,
            maxLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration:
                const InputDecoration(hintText: 'Anything worth remembering'),
          ),
          if (editing) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _closed,
              onChanged: _saving ? null : (bool v) => setState(() => _closed = v),
              title: Text('Closed', style: theme.textTheme.titleSmall),
              subtitle: Text(
                'Fully paid off; not offered for new instalments',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ],
        if (_error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          InlineError(message: _error!),
        ],
      ],
    );
  }

  Future<void> _pickStart() async {
    final DateTime now = AppDateUtils.today();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? now,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 10, 12, 31),
    );
    if (picked != null && mounted) {
      setState(() => _startDate = DateTime(picked.year, picked.month, picked.day));
    }
  }
}

/// A name with the people the user has a claim with offered underneath.
class _PersonInput extends StatelessWidget {
  const _PersonInput({
    required this.controller,
    required this.people,
    required this.missing,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController controller;
  final List<String> people;
  final bool missing;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (BuildContext context, TextEditingValue typed, _) {
        final List<String> offered =
            PaidForField.suggestionsFor(people, typed.text);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            FieldLabel('Who pays it back',
                isRequired: true, hint: missing ? 'Add a name' : null),
            TextField(
              controller: controller,
              enabled: enabled,
              textCapitalization: TextCapitalization.words,
              autocorrect: false,
              inputFormatters: <TextInputFormatter>[
                LengthLimitingTextInputFormatter(80),
              ],
              decoration: const InputDecoration(
                hintText: 'Name',
                prefixIcon:
                    Icon(Icons.person_outline_rounded, size: AppSpacing.iconMd),
              ),
              onChanged: (_) => onChanged(),
            ),
            if (offered.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: <Widget>[
                  for (final String name in offered)
                    AppChoiceChip(
                      label: name,
                      icon: Icons.person_outline_rounded,
                      selected: false,
                      enabled: enabled,
                      onSelected: () {
                        controller.value = TextEditingValue(
                          text: name,
                          selection: TextSelection.collapsed(offset: name.length),
                        );
                        onChanged();
                      },
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _AmountInput extends StatelessWidget {
  const _AmountInput({
    required this.label,
    required this.controller,
    required this.symbol,
    required this.enabled,
    required this.error,
  });

  final String label;
  final TextEditingController controller;
  final String symbol;
  final bool enabled;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        FieldLabel(label, hint: error),
        TextField(
          controller: controller,
          enabled: enabled,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: amountInputFormatters,
          decoration: InputDecoration(hintText: '0', prefixText: '$symbol '),
        ),
      ],
    );
  }
}
