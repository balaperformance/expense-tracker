import 'package:flutter/material.dart';

import '../core/theme/app_spacing.dart';
import '../models/payment_method.dart';
import 'common/app_fields.dart';

/// The user's payment methods as chips. Tapping the chosen one clears it,
/// since a payment method is optional.
class PaymentMethodChips extends StatelessWidget {
  const PaymentMethodChips({
    super.key,
    required this.methods,
    required this.selectedId,
    required this.onSelected,
    this.enabled = true,
  });

  final List<PaymentMethod> methods;
  final String? selectedId;
  final ValueChanged<String?> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: methods.map((PaymentMethod method) {
        final bool selected = method.id == selectedId;
        return AppChoiceChip(
          label: method.name,
          selected: selected,
          enabled: enabled,
          onSelected: () => onSelected(selected ? null : method.id),
        );
      }).toList(),
    );
  }
}
