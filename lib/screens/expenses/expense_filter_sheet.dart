import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../models/expense_category.dart';
import '../../models/expense_filter.dart';
import '../../models/payment_method.dart';
import '../../providers/category_provider.dart';
import '../../providers/payment_method_provider.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/surface_card.dart';

/// Filter editor.
///
/// Edits a local copy and returns it on Apply, so backing out leaves the list
/// untouched. The Apply button counts what will be applied, which makes the
/// effect of the sheet clear before it closes.
class ExpenseFilterSheet extends StatefulWidget {
  const ExpenseFilterSheet({super.key, required this.initial});

  final ExpenseFilter initial;

  @override
  State<ExpenseFilterSheet> createState() => _ExpenseFilterSheetState();
}

class _ExpenseFilterSheetState extends State<ExpenseFilterSheet> {
  late Set<String> _categoryIds = <String>{...widget.initial.categoryIds};
  late Set<String> _paymentIds = <String>{...widget.initial.paymentMethodIds};
  late DateTime? _from = widget.initial.from;
  late DateTime? _to = widget.initial.to;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<ExpenseCategory> categories =
        context.watch<CategoryProvider>().categories;
    final List<PaymentMethod> methods =
        context.watch<PaymentMethodProvider>().methods;

    return AppSheet(
      title: 'Filters',
      subtitle: _hasAny ? '$_count active' : 'Narrow down the list',
      action: TextButton(
        onPressed: _hasAny ? _clearAll : null,
        child: const Text('Clear all'),
      ),
      footer: AppButton.submit(
        label: _hasAny ? 'Apply $_count filters' : 'Apply',
        onPressed: _apply,
      ),
      children: <Widget>[
        const FieldLabel('Date range'),
        Row(
          children: <Widget>[
            Expanded(
              child: _DateButton(
                label: 'From',
                value: _from,
                onPick: (DateTime? d) => setState(() => _from = d),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _DateButton(
                label: 'To',
                value: _to,
                onPick: (DateTime? d) => setState(() => _to = d),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            AppChoiceChip(
              label: 'This month',
              selected: _matchesRange(AppDateUtils.currentMonth()),
              onSelected: () => _applyRange(AppDateUtils.currentMonth()),
            ),
            AppChoiceChip(
              label: 'Last month',
              selected: _matchesRange(_lastMonth),
              onSelected: () => _applyRange(_lastMonth),
            ),
            AppChoiceChip(
              label: 'Last 30 days',
              selected: _matchesLast30,
              onSelected: () => setState(() {
                _to = AppDateUtils.today();
                _from = _to!.subtract(const Duration(days: 30));
              }),
            ),
          ],
        ),

        const SizedBox(height: AppSpacing.xl),
        FieldLabel(
          'Categories',
          hint: _categoryIds.isEmpty ? null : '${_categoryIds.length} selected',
        ),
        if (categories.isEmpty)
          const AppNotice(message: 'No categories yet.')
        else
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: categories.map((ExpenseCategory category) {
              final bool selected = _categoryIds.contains(category.id);
              return AppChoiceChip(
                label: category.name,
                selected: selected,
                tone: AppColors.readableOn(
                  AppColors.fromHex(category.color),
                  theme.brightness,
                ),
                avatar: CategoryAvatar(
                  icon: category.icon,
                  color: category.color,
                  size: 20,
                ),
                onSelected: () => setState(() {
                  if (selected) {
                    _categoryIds.remove(category.id);
                  } else {
                    _categoryIds.add(category.id);
                  }
                }),
              );
            }).toList(),
          ),

        const SizedBox(height: AppSpacing.xl),
        FieldLabel(
          'Payment methods',
          hint: _paymentIds.isEmpty ? null : '${_paymentIds.length} selected',
        ),
        if (methods.isEmpty)
          const AppNotice(message: 'No payment methods yet.')
        else
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: methods.map((PaymentMethod method) {
              final bool selected = _paymentIds.contains(method.id);
              return AppChoiceChip(
                label: method.name,
                selected: selected,
                onSelected: () => setState(() {
                  if (selected) {
                    _paymentIds.remove(method.id);
                  } else {
                    _paymentIds.add(method.id);
                  }
                }),
              );
            }).toList(),
          ),
      ],
    );
  }

  MonthRange get _lastMonth => AppDateUtils.monthRange(
        AppDateUtils.addMonths(DateTime.now(), -1),
      );

  bool _matchesRange(MonthRange range) =>
      _from == range.start && _to == range.endInclusive;

  bool get _matchesLast30 {
    if (_from == null || _to == null) return false;
    return _to == AppDateUtils.today() &&
        _from == _to!.subtract(const Duration(days: 30));
  }

  int get _count =>
      _categoryIds.length +
      _paymentIds.length +
      (_from != null ? 1 : 0) +
      (_to != null ? 1 : 0);

  bool get _hasAny => _count > 0;

  void _apply() {
    Navigator.of(context).pop(
      widget.initial.copyWith(
        categoryIds: _categoryIds,
        paymentMethodIds: _paymentIds,
        from: _from,
        to: _to,
        clearFrom: _from == null,
        clearTo: _to == null,
      ),
    );
  }

  void _applyRange(MonthRange range) {
    setState(() {
      _from = range.start;
      _to = range.endInclusive;
    });
  }

  void _clearAll() {
    setState(() {
      _categoryIds = <String>{};
      _paymentIds = <String>{};
      _from = null;
      _to = null;
    });
  }
}

/// Field-shaped date button that clears itself when a value is set.
class _DateButton extends StatelessWidget {
  const _DateButton({
    required this.label,
    required this.value,
    required this.onPick,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onPick;

  @override
  Widget build(BuildContext context) {
    return SelectField(
      value: value == null ? null : Formatters.dayMonthYear(value!),
      placeholder: label,
      icon: Icons.calendar_today_rounded,
      onTap: () => _pick(context),
      trailing: value == null
          ? null
          : IconButton(
              tooltip: 'Clear $label',
              onPressed: () => onPick(null),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.close_rounded, size: 17),
            ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final DateTime now = DateTime.now();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: value ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (picked != null) {
      onPick(DateTime(picked.year, picked.month, picked.day));
    }
  }
}
