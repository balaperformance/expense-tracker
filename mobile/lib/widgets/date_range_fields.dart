import 'package:flutter/material.dart';

import '../core/theme/app_spacing.dart';
import '../core/utils/date_utils.dart';
import '../core/utils/formatters.dart';
import 'common/app_fields.dart';

/// "Date range": From and To, each clearable, with This month, Last month and
/// Last 30 days one tap away. Shared by the Expenses and Income filters, so
/// both lists narrow by date the same way.
class DateRangeFields extends StatelessWidget {
  const DateRangeFields({
    super.key,
    required this.from,
    required this.to,
    required this.onChanged,
  });

  final DateTime? from;
  final DateTime? to;

  /// Both ends at once; either may be null (open-ended).
  final void Function(DateTime? from, DateTime? to) onChanged;

  @override
  Widget build(BuildContext context) {
    final MonthRange thisMonth = AppDateUtils.currentMonth();
    final MonthRange lastMonth = AppDateUtils.monthRange(
      AppDateUtils.addMonths(DateTime.now(), -1),
    );
    final DateTime today = AppDateUtils.today();
    final DateTime monthAgo = today.subtract(const Duration(days: 30));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const FieldLabel('Date range'),
        Row(
          children: <Widget>[
            Expanded(
              child: _DateButton(
                label: 'From',
                value: from,
                onPick: (DateTime? d) => onChanged(d, to),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _DateButton(
                label: 'To',
                value: to,
                onPick: (DateTime? d) => onChanged(from, d),
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
              selected: from == thisMonth.start && to == thisMonth.endInclusive,
              onSelected: () => onChanged(thisMonth.start, thisMonth.endInclusive),
            ),
            AppChoiceChip(
              label: 'Last month',
              selected: from == lastMonth.start && to == lastMonth.endInclusive,
              onSelected: () => onChanged(lastMonth.start, lastMonth.endInclusive),
            ),
            AppChoiceChip(
              label: 'Last 30 days',
              selected: from == monthAgo && to == today,
              onSelected: () => onChanged(monthAgo, today),
            ),
          ],
        ),
      ],
    );
  }
}

/// "1 Oct – 31 Oct 2026", "From 1 Oct 2026", "Until 31 Oct 2026"; null when
/// neither end is set.
String? dateRangeLabel(DateTime? from, DateTime? to) {
  if (from != null && to != null) {
    final String start = from.year == to.year
        ? Formatters.dayMonth(from)
        : Formatters.dayMonthYear(from);
    return '$start – ${Formatters.dayMonthYear(to)}';
  }
  if (from != null) return 'From ${Formatters.dayMonthYear(from)}';
  if (to != null) return 'Until ${Formatters.dayMonthYear(to)}';
  return null;
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
