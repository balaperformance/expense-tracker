import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';

/// Label above a field. Kept outside the input itself because a floating
/// Material label moves, and a form of moving labels is hard to scan.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key, this.isRequired = false, this.hint});

  final String text;
  final bool isRequired;

  /// Quiet text on the right of the label row.
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(
        bottom: AppSpacing.sm,
        left: AppSpacing.xxs,
      ),
      child: Row(
        children: <Widget>[
          Text(text, style: theme.textTheme.labelMedium),
          if (isRequired)
            Text(
              ' *',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          const Spacer(),
          if (hint != null)
            Text(hint!, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

/// Only digits and at most two decimal places, matching `numeric(14,2)`.
///
/// Filtering at the keyboard means the user cannot type a value the database
/// would reject, so they never see a validation error for it.
final List<TextInputFormatter> amountInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
];

/// The oversized amount input at the top of a form.
///
/// The amount is the one field every entry needs, so it gets display-scale
/// type, autofocus and the decimal keypad. Everything below it is a refinement
/// of a value the user has usually already typed.
class AmountField extends StatelessWidget {
  const AmountField({
    super.key,
    required this.controller,
    required this.symbol,
    this.enabled = true,
    this.autofocus = true,
    this.tone,
    this.onChanged,
  });

  final TextEditingController controller;
  final String symbol;
  final bool enabled;
  final bool autofocus;

  /// Colours the typed figure — expense red, income green.
  final Color? tone;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurfaceVariant;

    final TextStyle figure = AppTypography.money(
      theme.textTheme.displayMedium?.copyWith(color: tone),
    );

    return TextFormField(
      controller: controller,
      enabled: enabled,
      autofocus: autofocus,
      onChanged: onChanged,
      validator: Validators.amount,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: amountInputFormatters,
      textAlign: TextAlign.center,
      style: figure,
      cursorHeight: 30,
      decoration: InputDecoration(
        hintText: '0',
        hintStyle: figure.copyWith(color: muted.withOpacity(0.38)),
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: AppSpacing.lg),
          child: Center(
            widthFactor: 0,
            child: Text(
              symbol,
              style: theme.textTheme.headlineMedium?.copyWith(color: muted),
            ),
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
      ),
    );
  }
}

/// A field-shaped button that opens a picker.
///
/// Matches the height, fill and radius of a real input so a row of "fields"
/// stays visually even whether each one is typed into or selected from.
class SelectField extends StatelessWidget {
  const SelectField({
    super.key,
    required this.value,
    required this.onTap,
    this.icon,
    this.placeholder,
    this.enabled = true,
    this.trailing,
  });

  final String? value;
  final VoidCallback onTap;
  final IconData? icon;
  final String? placeholder;
  final bool enabled;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool hasValue = value != null && value!.isNotEmpty;

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: Container(
          height: AppSpacing.fieldHeight,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Row(
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(
                  icon,
                  size: AppSpacing.iconMd,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.md),
              ],
              Expanded(
                child: Text(
                  hasValue ? value! : (placeholder ?? ''),
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: hasValue
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              trailing ??
                  Icon(
                    Icons.expand_more_rounded,
                    size: AppSpacing.iconMd,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Date field with Today / Yesterday shortcuts.
///
/// Most entries are same-day or next-day, so the two presets remove a
/// date-picker round trip from the common case while the field itself still
/// opens the full calendar.
class DateField extends StatelessWidget {
  const DateField({
    super.key,
    required this.date,
    required this.onChanged,
    this.enabled = true,
    this.showQuickPicks = true,
  });

  final DateTime date;
  final ValueChanged<DateTime> onChanged;
  final bool enabled;
  final bool showQuickPicks;

  @override
  Widget build(BuildContext context) {
    final DateTime today = AppDateUtils.today();
    final DateTime yesterday = today.subtract(const Duration(days: 1));

    final Widget field = SelectField(
      value: Formatters.dayMonthYear(date),
      icon: Icons.calendar_today_rounded,
      enabled: enabled,
      onTap: () => _pick(context),
      trailing: const SizedBox.shrink(),
    );

    if (!showQuickPicks) return field;

    return Row(
      children: <Widget>[
        Expanded(child: field),
        const SizedBox(width: AppSpacing.sm),
        _QuickDate(
          label: 'Today',
          selected: date == today,
          enabled: enabled,
          onTap: () => onChanged(today),
        ),
        const SizedBox(width: AppSpacing.xs),
        _QuickDate(
          label: 'Yest',
          selected: date == yesterday,
          enabled: enabled,
          onTap: () => onChanged(yesterday),
        ),
      ],
    );
  }

  Future<void> _pick(BuildContext context) async {
    final DateTime now = DateTime.now();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: date,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (picked != null) {
      onChanged(DateTime(picked.year, picked.month, picked.day));
    }
  }
}

class _QuickDate extends StatelessWidget {
  const _QuickDate({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.enabled,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color tone =
        selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;

    return Material(
      color: selected
          ? theme.colorScheme.primary.withOpacity(0.12)
          : theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: Container(
          height: AppSpacing.fieldHeight,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          alignment: Alignment.center,
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(color: tone),
          ),
        ),
      ),
    );
  }
}

/// Search input used in the Expenses and Income headers.
class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.hintText,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (BuildContext context, TextEditingValue value, Widget? _) {
        return TextField(
          controller: controller,
          onChanged: onChanged,
          textInputAction: TextInputAction.search,
          style: Theme.of(context).textTheme.bodyMedium,
          decoration: InputDecoration(
            hintText: hintText,
            prefixIcon: const Icon(Icons.search_rounded, size: AppSpacing.iconMd),
            suffixIcon: value.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
          ),
        );
      },
    );
  }
}

/// Selectable pill. The single chip used everywhere the user picks from a
/// short set — category, payment source, budget scope, date preset.
class AppChoiceChip extends StatelessWidget {
  const AppChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.avatar,
    this.icon,
    this.enabled = true,
    this.tone,
  });

  final String label;
  final bool selected;
  final VoidCallback? onSelected;
  final Widget? avatar;
  final IconData? icon;
  final bool enabled;

  /// Overrides the selected colour, so a category chip can carry its own hue.
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color accent = tone ?? theme.colorScheme.primary;

    return ChoiceChip(
      selected: selected,
      onSelected: enabled && onSelected != null ? (_) => onSelected!() : null,
      showCheckmark: false,
      avatar: avatar ??
          (icon == null
              ? null
              : Icon(
                  icon,
                  size: AppSpacing.iconSm,
                  color: selected ? accent : theme.colorScheme.onSurfaceVariant,
                )),
      label: Text(label),
      selectedColor: accent.withOpacity(
        theme.brightness == Brightness.dark ? 0.24 : 0.12,
      ),
      side: BorderSide(
        color: selected ? accent.withOpacity(0.5) : theme.colorScheme.outline,
      ),
      labelStyle: theme.textTheme.labelLarge?.copyWith(
        color: selected ? accent : theme.colorScheme.onSurface,
      ),
    );
  }
}
