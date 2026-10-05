import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/app_spacing.dart';
import '../models/receivable.dart';
import 'common/app_fields.dart';

/// "Paid for someone else" on an expense: the purchase is owed back, so it
/// leaves the user's own spending (migration 005). The web app's
/// `PaidForToggle`, with its person field.
class PaidForField extends StatelessWidget {
  const PaidForField({
    super.key,
    required this.value,
    required this.onChanged,
    required this.person,
    this.people = const <String>[],
    this.submitted = false,
    this.enabled = true,
    this.progress,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  /// Who it was paid for.
  final TextEditingController person;

  /// Everyone the user already has a claim with, most recent first.
  final List<String> people;

  /// Set once a save was tried, so a blank name is pointed out then rather
  /// than before the user has typed anything.
  final bool submitted;
  final bool enabled;

  /// "₹2,000.00 of ₹3,000.00 paid back · Partly repaid" — for a purchase
  /// already marked.
  final String? progress;

  /// The people to offer for what is typed: the ones that start with it,
  /// never the name exactly as typed, at most four.
  static List<String> suggestionsFor(List<String> people, String typed) {
    final String key = personKey(typed);
    return people
        .where((String p) =>
            personKey(p) != key && (key.isEmpty || personKey(p).startsWith(key)))
        .take(4)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AppChoiceChip(
          label: 'Paid for someone else',
          icon: Icons.handshake_outlined,
          selected: value,
          enabled: enabled,
          onSelected: () => onChanged(!value),
        ),
        if (value) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: person,
            builder: (BuildContext context, TextEditingValue typed, _) {
              final List<String> offered = suggestionsFor(people, typed.text);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  FieldLabel(
                    'Paid for',
                    isRequired: true,
                    hint: submitted && typed.text.trim().isEmpty
                        ? 'Add a name'
                        : null,
                  ),
                  TextField(
                    controller: person,
                    enabled: enabled,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    inputFormatters: <TextInputFormatter>[
                      LengthLimitingTextInputFormatter(80),
                    ],
                    decoration: const InputDecoration(
                      hintText: 'Name',
                      prefixIcon: Icon(
                        Icons.person_outline_rounded,
                        size: AppSpacing.iconMd,
                      ),
                    ),
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
                            onSelected: () => person.value = TextEditingValue(
                              text: name,
                              selection:
                                  TextSelection.collapsed(offset: name.length),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            progress ?? 'Owed back to you — not counted as your spending.',
            style: theme.textTheme.labelSmall,
          ),
        ],
      ],
    );
  }
}
