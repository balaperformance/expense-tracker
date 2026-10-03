import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../models/expense_category.dart';
import '../../models/frequent_expense.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_fields.dart';

/// "Coffee", or the category's name when the habit has neither merchant nor
/// description.
String quickAddName(
  FrequentExpense suggestion,
  List<ExpenseCategory> categories,
) {
  final String? title = suggestion.title;
  if (title != null) return title;
  for (final ExpenseCategory category in categories) {
    if (category.id == suggestion.categoryId) return category.name;
  }
  return 'Expense';
}

/// A long merchant is shortened on its chip, so the amount after it always
/// shows.
String _chipName(String name) =>
    name.length > 22 ? '${name.substring(0, 21).trimRight()}…' : name;

/// Quick add: one chip per frequent expense, "Coffee · ₹120.00", or just
/// "Groceries" when its amount varies. Tapping one fills the form; it never
/// saves.
class QuickAddChips extends StatelessWidget {
  const QuickAddChips({
    super.key,
    required this.suggestions,
    required this.categories,
    required this.currency,
    required this.selectedKey,
    required this.onPicked,
    this.enabled = true,
  });

  final List<FrequentExpense> suggestions;
  final List<ExpenseCategory> categories;

  /// The user's currency code.
  final String currency;

  /// The suggestion last applied, shown selected.
  final String? selectedKey;

  final ValueChanged<FrequentExpense> onPicked;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final Brightness brightness = Theme.of(context).brightness;
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: suggestions.map((FrequentExpense suggestion) {
        ExpenseCategory? category;
        for (final ExpenseCategory c in categories) {
          if (c.id == suggestion.categoryId) category = c;
        }
        final String name = _chipName(quickAddName(suggestion, categories));
        final double? amount = suggestion.amount;
        return AppChoiceChip(
          label: amount == null
              ? name
              : '$name · ${Formatters.currency(amount, currencyCode: currency)}',
          selected: suggestion.key == selectedKey,
          enabled: enabled,
          tone: category == null
              ? null
              : AppColors.readableOn(
                  AppColors.fromHex(category.color),
                  brightness,
                ),
          avatar: category == null
              ? null
              : CategoryAvatar(
                  icon: category.icon,
                  color: category.color,
                  size: 20,
                ),
          onSelected: () => onPicked(suggestion),
        );
      }).toList(),
    );
  }
}
