import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/app_spacing.dart';
import '../models/tag.dart';
import '../models/tag_rules.dart';
import 'common/app_fields.dart';

/// Tags on an expense or income: type one and press Done (or a comma), or
/// tap an existing tag. Existing tags are always offered — narrowed as you
/// type — and a name that does not exist yet is created when the row is
/// saved. The web app's `TagField`.
///
/// The form owns both the chosen [tags] and the [draft] being typed, so a
/// save can include a tag the user typed but did not confirm — read it with
/// [withDraft].
class TagField extends StatelessWidget {
  const TagField({
    super.key,
    required this.tags,
    required this.draft,
    required this.onChanged,
    this.known = const <Tag>[],
    this.enabled = true,
  });

  final List<String> tags;
  final TextEditingController draft;
  final ValueChanged<List<String>> onChanged;

  /// The user's tags, offered as suggestions and reused with their own
  /// spelling.
  final List<Tag> known;
  final bool enabled;

  /// [tags] with whatever is still typed in [draft] added — what a save
  /// writes.
  static List<String> withDraft(
    List<String> tags,
    String draft, [
    List<Tag> known = const <Tag>[],
  ]) {
    List<String> next = List<String>.of(tags);
    for (final String part in draft.split(',')) {
      next = TagRules.add(next, part, known);
    }
    return next;
  }

  void _commit(String name) {
    onChanged(TagRules.add(tags, name, known));
    draft.clear();
  }

  void _typed(String text) {
    if (!text.contains(',')) return;
    final ({List<String> done, String rest}) split = TagRules.splitTyped(text);
    List<String> next = tags;
    for (final String name in split.done) {
      next = TagRules.add(next, name, known);
    }
    onChanged(next);
    draft.value = TextEditingValue(
      text: split.rest,
      selection: TextSelection.collapsed(offset: split.rest.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: draft,
      builder: (BuildContext context, TextEditingValue value, _) {
        final bool full = tags.length >= TagRules.maxPerTransaction;
        final List<Tag> suggestions = full
            ? const <Tag>[]
            : TagRules.suggestions(known, tags, value.text);
        final String? fresh =
            full ? null : TagRules.newTagFor(known, tags, value.text);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: draft,
              enabled: enabled && !full,
              textInputAction: TextInputAction.done,
              textCapitalization: TextCapitalization.none,
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: <TextInputFormatter>[
                LengthLimitingTextInputFormatter(TagRules.maxLength),
              ],
              decoration: InputDecoration(
                hintText: full ? 'Tag limit reached' : 'Add tags',
                prefixIcon: const Icon(
                  Icons.tag_rounded,
                  size: AppSpacing.iconMd,
                ),
              ),
              onChanged: _typed,
              // Adds the tag and keeps the keyboard up for the next one.
              onEditingComplete: () {
                if (draft.text.trim().isNotEmpty) _commit(draft.text);
              },
            ),
            if (tags.isNotEmpty ||
                fresh != null ||
                suggestions.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: <Widget>[
                  for (final String tag in tags)
                    InputChip(
                      label: Text('#$tag'),
                      visualDensity: VisualDensity.compact,
                      isEnabled: enabled,
                      deleteButtonTooltipMessage: 'Remove tag $tag',
                      // A disabled chip ignores it; the icon stays put.
                      onDeleted: () =>
                          onChanged(TagRules.remove(tags, tag)),
                    ),
                  if (fresh != null)
                    AppChoiceChip(
                      label: fresh,
                      icon: Icons.add_rounded,
                      selected: false,
                      enabled: enabled,
                      onSelected: () => _commit(fresh),
                    ),
                  for (final Tag tag in suggestions)
                    AppChoiceChip(
                      label: tag.name,
                      icon: Icons.tag_rounded,
                      selected: false,
                      enabled: enabled,
                      onSelected: () => _commit(tag.name),
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
