import 'package:flutter/material.dart';

import '../core/theme/app_spacing.dart';
import 'common/app_fields.dart';

/// "Whose money?" on an income or expense (migration 019): the user's own, or
/// someone else's — a friend's money received, or spent on their behalf.
/// Someone else's is kept in the lists but left out of every personal figure.
/// The web app's personal toggle.
class PersonalField extends StatelessWidget {
  const PersonalField({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  /// True: "Mine".
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  static const String helper = 'Kept in your lists, but left out of your '
      'income, spending, balance, budgets and reports.';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const FieldLabel('Whose money?'),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<bool>(
            segments: const <ButtonSegment<bool>>[
              ButtonSegment<bool>(value: true, label: Text('Mine')),
              ButtonSegment<bool>(value: false, label: Text('For someone else')),
            ],
            selected: <bool>{value},
            showSelectedIcon: false,
            onSelectionChanged:
                enabled ? (Set<bool> v) => onChanged(v.first) : null,
          ),
        ),
        if (!value) ...<Widget>[
          const SizedBox(height: AppSpacing.xs),
          Text(helper, style: Theme.of(context).textTheme.labelSmall),
        ],
      ],
    );
  }
}
