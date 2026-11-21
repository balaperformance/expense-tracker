import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_spacing.dart';
import '../core/utils/formatters.dart';
import '../core/utils/validators.dart';
import '../models/emi_plan.dart';
import '../models/expense_category.dart';
import '../models/payment_method.dart';
import '../models/tag.dart';
import '../models/tag_rules.dart';
import 'category_avatar.dart';
import 'common/app_fields.dart';
import 'common/surface_card.dart';
import 'payment_method_chips.dart';
import 'personal_field.dart';
import 'tag_field.dart';

/// The fields of an expense, shared by every place one is added or edited —
/// Add/Edit Expense, a bank statement row and a card statement row — so each
/// offers the same options the same way: category, EMI, paid for someone,
/// whose money, description, tags, notes and payment method.
///
/// It owns no state: each screen keeps its values and passes them in with a
/// callback per field. A field is shown only when the screen passes it (a
/// null value or callback hides it), and slots ([afterCategory], [funding],
/// [paidFor]) carry what differs by context — the date of a form, the
/// account or card it is paid from, a claim's progress.
///
/// Choosing Groceries adds the `groceries` and `famspendings` tags (see
/// [TagRules.autoTagsOnCategoryChange]); they can be removed again.
class ExpenseFields extends StatelessWidget {
  const ExpenseFields({
    super.key,
    required this.categories,
    required this.categoryId,
    required this.onCategory,
    this.categoryHint,
    this.categoryError = false,
    this.categoryDeselect = false,
    this.afterCategory = const <Widget>[],
    this.funding = const <Widget>[],
    this.emiPlans = const <EmiPlan>[],
    this.emiPlanId,
    this.onEmiPicked,
    this.emiPendingLeft,
    this.amount,
    this.emiAlreadyCounted = 0,
    this.currency = 'INR',
    this.paidFor = const <Widget>[],
    this.isPersonal,
    this.onPersonal,
    this.merchant,
    this.description,
    this.tags,
    this.tagDraft,
    this.knownTags = const <Tag>[],
    this.onTags,
    this.notes,
    this.methods = const <PaymentMethod>[],
    this.methodId,
    this.onMethod,
    this.methodHint,
    this.enabled = true,
  });

  final List<ExpenseCategory> categories;
  final String? categoryId;

  /// The category picked — null when [categoryDeselect] and the chosen one
  /// is tapped again.
  final ValueChanged<String?> onCategory;
  final String? categoryHint;
  final bool categoryError;
  final bool categoryDeselect;

  /// Shown right under the category (the form's date, a note on the row).
  final List<Widget> afterCategory;

  /// Where the money came from, when the context lets the user choose.
  final List<Widget> funding;

  /// The EMIs this can be a month's payment of; the picker shows only when
  /// there are some.
  final List<EmiPlan> emiPlans;
  final String? emiPlanId;

  /// A plan tapped: the screen picks it (or, if already picked, clears it)
  /// and fills what it allows from the plan.
  final ValueChanged<EmiPlan>? onEmiPicked;

  /// What is still pending on a plan, when it has a pending amount.
  final double? Function(EmiPlan plan)? emiPendingLeft;

  /// The amount being entered, for the "Pending after this" line.
  final ValueListenable<TextEditingValue>? amount;

  /// For an edit: the part of the pending amount this expense already took.
  final double emiAlreadyCounted;
  final String currency;

  /// "Paid for someone else", where the context supports it.
  final List<Widget> paidFor;

  /// Whose money (migration 019); hidden when null.
  final bool? isPersonal;
  final ValueChanged<bool>? onPersonal;

  final TextEditingController? merchant;
  final TextEditingController? description;

  /// The tags, and the one still being typed; hidden when null.
  final List<String>? tags;
  final TextEditingController? tagDraft;
  final List<Tag> knownTags;
  final ValueChanged<List<String>>? onTags;

  final TextEditingController? notes;

  /// The payment method chips; hidden when [onMethod] is null or there are
  /// no methods.
  final List<PaymentMethod> methods;
  final String? methodId;
  final ValueChanged<String?>? onMethod;
  final String? methodHint;
  final bool enabled;

  /// The name of the category with [id], if any.
  static String? categoryName(List<ExpenseCategory> categories, String? id) {
    if (id == null) return null;
    for (final ExpenseCategory c in categories) {
      if (c.id == id) return c.name;
    }
    return null;
  }

  /// The tags after the category changed from [fromId] to [toId] — with the
  /// grocery tags added on moving into Groceries — or null when unchanged.
  /// For screens that set the category themselves (a scan, Quick add, an
  /// EMI's category).
  static List<String>? tagsAfterCategoryChange({
    required List<ExpenseCategory> categories,
    required List<String> tags,
    required String? fromId,
    required String? toId,
    List<Tag> known = const <Tag>[],
  }) =>
      TagRules.autoTagsOnCategoryChange(
        tags,
        categoryName(categories, fromId),
        categoryName(categories, toId),
        known,
      );

  void _pickCategory(String id) {
    final String? next = categoryDeselect && id == categoryId ? null : id;
    final List<String>? current = tags;
    final List<String>? withAuto = current == null || onTags == null
        ? null
        : tagsAfterCategoryChange(
            categories: categories,
            tags: current,
            fromId: categoryId,
            toId: next,
            known: knownTags,
          );
    onCategory(next);
    if (withAuto != null) onTags!(withAuto);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<String>? tags = this.tags;
    final bool showMethods = onMethod != null && methods.isNotEmpty;
    final bool showDetails = merchant != null ||
        description != null ||
        (tags != null && tagDraft != null && onTags != null) ||
        notes != null ||
        showMethods;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FieldLabel('Category', isRequired: true, hint: categoryHint),
        CategoryChips(
          categories: categories,
          selectedId: categoryId,
          enabled: enabled,
          hasError: categoryError,
          onSelected: _pickCategory,
        ),
        const SizedBox(height: AppSpacing.lg),
        ...afterCategory,
        ...funding,
        if (emiPlans.isNotEmpty && onEmiPicked != null) ...<Widget>[
          // The explanation sits under the chips: beside the label it does
          // not fit a 360 dp phone.
          const FieldLabel('EMI', hint: 'Optional'),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: <Widget>[
              for (final EmiPlan plan in emiPlans)
                AppChoiceChip(
                  label: _emiLabel(plan),
                  icon: Icons.all_inclusive_rounded,
                  selected: emiPlanId == plan.id,
                  enabled: enabled,
                  onSelected: () => onEmiPicked!(plan),
                ),
            ],
          ),
          if (emiPlanId == null) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            Text('A month’s payment lowers what is pending.', style: theme.textTheme.labelSmall),
          ],
          ..._pendingAfter(theme),
          const SizedBox(height: AppSpacing.lg),
        ],
        if (paidFor.isNotEmpty) ...<Widget>[
          ...paidFor,
          const SizedBox(height: AppSpacing.lg),
        ],
        if (isPersonal != null && onPersonal != null) ...<Widget>[
          PersonalField(
            value: isPersonal!,
            enabled: enabled,
            onChanged: onPersonal!,
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
        if (showDetails) ...<Widget>[
          const FieldLabel('Details', hint: 'Optional'),
          SurfaceCard(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              children: <Widget>[
                if (merchant != null) ...<Widget>[
                  TextFormField(
                    controller: merchant,
                    enabled: enabled,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      hintText: 'Merchant',
                      prefixIcon: Icon(Icons.storefront_outlined, size: AppSpacing.iconMd),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                if (description != null) ...<Widget>[
                  TextFormField(
                    controller: description,
                    enabled: enabled,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      hintText: 'Description',
                      prefixIcon: Icon(Icons.short_text_rounded, size: AppSpacing.iconMd),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                if (tags != null && tagDraft != null && onTags != null) ...<Widget>[
                  TagField(
                    tags: tags,
                    draft: tagDraft!,
                    known: knownTags,
                    enabled: enabled,
                    onChanged: onTags!,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                if (notes != null)
                  TextFormField(
                    controller: notes,
                    enabled: enabled,
                    maxLines: 2,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'Notes',
                      alignLabelWithHint: true,
                      prefixIcon: Icon(Icons.notes_rounded, size: AppSpacing.iconMd),
                    ),
                  ),
                if (showMethods) ...<Widget>[
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    children: <Widget>[
                      Expanded(child: Text('Payment method', style: theme.textTheme.labelMedium)),
                      if (methodHint != null) Text(methodHint!, style: theme.textTheme.labelSmall),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  PaymentMethodChips(
                    methods: methods,
                    selectedId: methodId,
                    enabled: enabled,
                    onSelected: onMethod!,
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// "Home loan · ₹36,000 pending": the plan and what is left on it.
  String _emiLabel(EmiPlan plan) {
    final String? pending = emiPendingText(
      emiPendingLeft?.call(plan),
      (double v) => Formatters.currency(v, currencyCode: currency, compact: true),
    );
    return pending == null ? plan.title : '${plan.title} · $pending';
  }

  /// "Pending after this: ₹34,000" under the picker, when the chosen plan has
  /// a pending amount.
  List<Widget> _pendingAfter(ThemeData theme) {
    EmiPlan? plan;
    for (final EmiPlan p in emiPlans) {
      if (p.id == emiPlanId) plan = p;
    }
    final double? left = plan == null ? null : emiPendingLeft?.call(plan);
    final ValueListenable<TextEditingValue>? amount = this.amount;
    if (left == null || amount == null) return const <Widget>[];
    final double before = left + emiAlreadyCounted;
    return <Widget>[
      const SizedBox(height: AppSpacing.sm),
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: amount,
        builder: (BuildContext context, TextEditingValue value, _) {
          final double? after = pendingLeft(before, Validators.parseAmount(value.text) ?? 0);
          return Text(
            'Pending after this: ${Formatters.currency(after ?? before, currencyCode: currency)}',
            style: theme.textTheme.labelMedium,
          );
        },
      ),
    ];
  }
}

/// The fields of an income, shared by Add/Edit Income and an imported bank
/// statement row: source, whose money, description, tags and notes, with
/// slots for what differs by context (the form's date and account).
class IncomeFields extends StatelessWidget {
  const IncomeFields({
    super.key,
    required this.source,
    this.sourceHint,
    this.sourcePlaceholder = 'Salary, freelance, interest…',
    this.commonSources = const <String>[],
    this.afterSource = const <Widget>[],
    this.funding = const <Widget>[],
    this.isPersonal,
    this.onPersonal,
    this.description,
    this.tags,
    this.tagDraft,
    this.knownTags = const <Tag>[],
    this.onTags,
    this.notes,
    this.enabled = true,
  });

  final TextEditingController source;
  final String? sourceHint;
  final String sourcePlaceholder;

  /// One-tap sources offered under the field.
  final List<String> commonSources;

  /// Shown under the source (the form's date).
  final List<Widget> afterSource;

  /// The account it was received in, when the context lets the user choose.
  final List<Widget> funding;
  final bool? isPersonal;
  final ValueChanged<bool>? onPersonal;
  final TextEditingController? description;
  final List<String>? tags;
  final TextEditingController? tagDraft;
  final List<Tag> knownTags;
  final ValueChanged<List<String>>? onTags;
  final TextEditingController? notes;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final List<String>? tags = this.tags;
    final bool showTags = tags != null && tagDraft != null && onTags != null;
    final bool showDetails = description != null || showTags || notes != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FieldLabel('Source', hint: sourceHint),
        TextFormField(
          controller: source,
          enabled: enabled,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            hintText: sourcePlaceholder,
            prefixIcon: const Icon(Icons.work_outline_rounded, size: AppSpacing.iconMd),
          ),
        ),
        if (commonSources.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: source,
            builder: (BuildContext context, TextEditingValue value, _) => Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: commonSources
                  .map((String s) => AppChoiceChip(
                        label: s,
                        selected: value.text.trim().toLowerCase() == s.toLowerCase(),
                        enabled: enabled,
                        onSelected: () => source.text = s,
                      ))
                  .toList(),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        ...afterSource,
        ...funding,
        if (isPersonal != null && onPersonal != null) ...<Widget>[
          PersonalField(value: isPersonal!, enabled: enabled, onChanged: onPersonal!),
          const SizedBox(height: AppSpacing.lg),
        ],
        if (showDetails) ...<Widget>[
          const FieldLabel('Details', hint: 'Optional'),
          SurfaceCard(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              children: <Widget>[
                if (description != null)
                  TextFormField(
                    controller: description,
                    enabled: enabled,
                    maxLines: 2,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'Description',
                      alignLabelWithHint: true,
                      prefixIcon: Icon(Icons.short_text_rounded, size: AppSpacing.iconMd),
                    ),
                  ),
                if (showTags) ...<Widget>[
                  if (description != null) const SizedBox(height: AppSpacing.sm),
                  TagField(
                    tags: tags,
                    draft: tagDraft!,
                    known: knownTags,
                    enabled: enabled,
                    onChanged: onTags!,
                  ),
                ],
                if (notes != null) ...<Widget>[
                  if (description != null || showTags) const SizedBox(height: AppSpacing.sm),
                  TextFormField(
                    controller: notes,
                    enabled: enabled,
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'Notes',
                      alignLabelWithHint: true,
                      prefixIcon: Icon(Icons.notes_rounded, size: AppSpacing.iconMd),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Category chips, each in its own colour; outlined in red when one must be
/// picked.
class CategoryChips extends StatelessWidget {
  const CategoryChips({
    super.key,
    required this.categories,
    required this.selectedId,
    required this.onSelected,
    this.enabled = true,
    this.hasError = false,
  });

  final List<ExpenseCategory> categories;
  final String? selectedId;
  final ValueChanged<String> onSelected;
  final bool enabled;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (categories.isEmpty) {
      return const AppNotice(
        message: 'No categories yet. Add one from Settings › Categories.',
      );
    }
    return Container(
      padding: hasError ? const EdgeInsets.all(AppSpacing.sm) : EdgeInsets.zero,
      decoration: hasError
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              border: Border.all(color: theme.colorScheme.error),
            )
          : null,
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: categories.map((ExpenseCategory category) {
          return AppChoiceChip(
            label: category.name,
            selected: category.id == selectedId,
            enabled: enabled,
            tone: AppColors.readableOn(AppColors.fromHex(category.color), theme.brightness),
            avatar: CategoryAvatar(icon: category.icon, color: category.color, size: 20),
            onSelected: () => onSelected(category.id),
          );
        }).toList(),
      ),
    );
  }
}
