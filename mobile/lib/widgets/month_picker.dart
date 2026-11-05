import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme/app_spacing.dart';
import '../core/utils/date_utils.dart';
import '../core/utils/formatters.dart';
import 'common/app_buttons.dart';
import 'common/app_sheet.dart';

/// "‹  October 2026 ▾  ›" — the dashboard's month control.
///
/// The arrows step one month; the label opens [showMonthPickerSheet], a year
/// stepper over a grid of twelve months, so reaching a month years back is
/// two or three taps however long the history grows. Nothing after the
/// current month can be chosen.
class MonthSwitcher extends StatelessWidget {
  const MonthSwitcher({
    super.key,
    required this.month,
    required this.onChanged,
    this.earliest,
  });

  /// First day of the month shown.
  final DateTime month;
  final ValueChanged<DateTime> onChanged;

  /// Read when the picker opens: the first month with any data, so the grid
  /// never offers years with nothing in them. Null or failing: five years back.
  final Future<DateTime?> Function()? earliest;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DateTime current = AppDateUtils.firstDayOf(DateTime.now());
    final bool atCurrent = !month.isBefore(current);

    return Row(
      children: <Widget>[
        IconButton(
          onPressed: () => onChanged(AppDateUtils.addMonths(month, -1)),
          icon: const Icon(Icons.chevron_left_rounded),
          tooltip: 'Previous month',
          visualDensity: VisualDensity.compact,
        ),
        Expanded(
          child: Center(
            child: InkWell(
              onTap: () => _pick(context),
              borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
              child: Semantics(
                button: true,
                label: 'Choose month, ${Formatters.monthYear(month)}',
                excludeSemantics: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs + 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          Formatters.monthYear(month),
                          style: theme.textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xxs),
                      Icon(
                        Icons.arrow_drop_down_rounded,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (!atCurrent)
          TextButton(
            onPressed: () => onChanged(current),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('Today'),
          ),
        IconButton(
          onPressed:
              atCurrent ? null : () => onChanged(AppDateUtils.addMonths(month, 1)),
          icon: const Icon(Icons.chevron_right_rounded),
          tooltip: 'Next month',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  Future<void> _pick(BuildContext context) async {
    DateTime? first;
    try {
      first = await earliest?.call();
    } catch (_) {
      first = null;
    }
    if (!context.mounted) return;
    final DateTime? picked = await showMonthPickerSheet(
      context: context,
      selected: month,
      earliest: first,
    );
    if (picked != null && picked != month) onChanged(picked);
  }
}

/// Years back the picker offers when the first month with data is unknown.
const int _fallbackYears = 5;

/// A month, chosen from a year at a time: `‹ 2026 ›` over Jan–Dec. Returns
/// the first day of the month picked, or null when dismissed.
Future<DateTime?> showMonthPickerSheet({
  required BuildContext context,
  required DateTime selected,
  DateTime? earliest,
}) {
  return showAppSheet<DateTime>(
    context: context,
    builder: (_) => MonthPickerSheet(selected: selected, earliest: earliest),
  );
}

class MonthPickerSheet extends StatefulWidget {
  const MonthPickerSheet({super.key, required this.selected, this.earliest});

  final DateTime selected;
  final DateTime? earliest;

  @override
  State<MonthPickerSheet> createState() => _MonthPickerSheetState();
}

class _MonthPickerSheetState extends State<MonthPickerSheet> {
  late final DateTime _current = AppDateUtils.firstDayOf(DateTime.now());
  late int _year = widget.selected.year;

  /// Never later than the selected month, so the selection is always reachable.
  int get _firstYear {
    final int fromData = widget.earliest?.year ?? _current.year - _fallbackYears;
    return fromData < widget.selected.year ? fromData : widget.selected.year;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DateFormat short = DateFormat.MMM();

    return AppSheet(
      title: 'Choose month',
      subtitle: Formatters.monthYear(widget.selected),
      footer: AppButton.submit(
        label: 'This month',
        variant: AppButtonVariant.secondary,
        onPressed: () => Navigator.of(context).pop(_current),
      ),
      children: <Widget>[
        Row(
          children: <Widget>[
            IconButton(
              onPressed: _year > _firstYear ? () => setState(() => _year--) : null,
              icon: const Icon(Icons.chevron_left_rounded),
              tooltip: 'Previous year',
            ),
            Expanded(
              child: Text(
                '$_year',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
            ),
            IconButton(
              onPressed: _year < _current.year ? () => setState(() => _year++) : null,
              icon: const Icon(Icons.chevron_right_rounded),
              tooltip: 'Next year',
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: AppSpacing.sm,
          crossAxisSpacing: AppSpacing.sm,
          childAspectRatio: 2.1,
          children: <Widget>[
            for (int m = 1; m <= 12; m++) _monthCell(DateTime(_year, m), short, theme),
          ],
        ),
      ],
    );
  }

  Widget _monthCell(DateTime month, DateFormat short, ThemeData theme) {
    final ColorScheme scheme = theme.colorScheme;
    final bool future = month.isAfter(_current);
    final DateTime? earliest = widget.earliest;
    final bool beforeData = earliest != null &&
        month.isBefore(AppDateUtils.firstDayOf(earliest)) &&
        month != widget.selected;
    final bool enabled = !future && !beforeData;
    final bool selected = month == widget.selected;
    final bool isCurrent = month == _current;

    return Material(
      color: selected ? scheme.primary : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        side: BorderSide(
          color: selected
              ? scheme.primary
              : isCurrent
                  ? scheme.primary.withOpacity(0.6)
                  : scheme.outlineVariant,
        ),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: enabled ? () => Navigator.of(context).pop(month) : null,
        child: Center(
          child: Text(
            short.format(month),
            semanticsLabel: Formatters.monthYear(month),
            style: theme.textTheme.labelLarge?.copyWith(
              color: selected
                  ? scheme.onPrimary
                  : enabled
                      ? scheme.onSurface
                      : scheme.onSurface.withOpacity(0.32),
            ),
          ),
        ),
      ),
    );
  }
}
