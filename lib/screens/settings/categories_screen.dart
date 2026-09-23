import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/category_icons.dart';
import '../../core/utils/validators.dart';
import '../../models/expense_category.dart';
import '../../providers/category_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/expense_provider.dart';
import '../../providers/reports_provider.dart';
import '../../widgets/category_avatar.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';

class CategoriesScreen extends StatelessWidget {
  const CategoriesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final CategoryProvider provider = context.watch<CategoryProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Categories')),
      floatingActionButton: AppFab(
        heroTag: 'category_fab',
        onPressed: () => _openEditor(context, null),
        label: 'New',
      ),
      body: _buildBody(context, provider),
    );
  }

  Widget _buildBody(BuildContext context, CategoryProvider provider) {
    if (provider.isInitialLoad) return const ListSkeleton(rows: 7);

    if (provider.hasError && provider.categories.isEmpty) {
      return ScrollableCentered(
        child: ErrorView(
          message: provider.errorMessage!,
          onRetry: provider.refresh,
        ),
      );
    }

    if (provider.categories.isEmpty) {
      return ScrollableCentered(
        child: EmptyState(
          icon: Icons.category_outlined,
          title: 'No categories',
          message: 'Create categories to organise your spending.',
          actionLabel: 'Add category',
          onAction: () => _openEditor(context, null),
        ),
      );
    }

    // Grouped into one card: these are single-line records, and a card each
    // turned a list of nine defaults into a full screen of scrolling.
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.md,
        AppSpacing.page,
        AppSpacing.bottomListPaddingPage,
      ),
      children: <Widget>[
        SectionHeader(
          title: 'Categories',
          caption: '${provider.categories.length}',
        ),
        CardList(
          children: <Widget>[
            for (final ExpenseCategory category in provider.categories)
              AppListRow(
                leading: CategoryAvatar(
                  icon: category.icon,
                  color: category.color,
                ),
                title: category.name,
                subtitle: category.isDefault ? 'Default' : null,
                dense: true,
                onTap: () => _openEditor(context, category),
                trailing: IconButton(
                  tooltip: 'Delete',
                  onPressed: () => _confirmDelete(context, category),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    size: AppSpacing.iconMd,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        const AppNotice(
          message: 'Tap a category to rename it or change its icon and colour.',
        ),
      ],
    );
  }

  Future<void> _openEditor(
    BuildContext context,
    ExpenseCategory? category,
  ) async {
    final bool? changed = await showAppSheet<bool>(
      context: context,
      builder: (_) => CategoryEditorSheet(category: category),
    );

    if (changed == true && context.mounted) {
      _invalidateDerived(context);
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    ExpenseCategory category,
  ) async {
    final CategoryProvider provider = context.read<CategoryProvider>();
    final int usage = await provider.usageCount(category.id);

    if (!context.mounted) return;

    final String consequence = usage == 0
        ? 'No expenses use this category.'
        : '$usage ${usage == 1 ? 'expense keeps' : 'expenses keep'} their '
            'amount but become uncategorised.';

    final bool confirmed = await AppFeedback.confirm(
      context,
      title: 'Delete "${category.name}"?',
      message: '$consequence This cannot be undone.',
    );

    if (!confirmed || !context.mounted) return;

    final bool ok = await provider.delete(category.id);
    if (!context.mounted) return;

    if (ok) {
      AppFeedback.success(context, 'Category deleted');
      _invalidateDerived(context);
    } else {
      AppFeedback.error(
        context,
        provider.errorMessage ?? 'Could not delete the category.',
      );
    }
  }

  void _invalidateDerived(BuildContext context) {
    context.read<DashboardProvider>().invalidate();
    context.read<ReportsProvider>().invalidate();
    // Expense rows embed their category, so the cached list is now stale.
    context.read<ExpenseProvider>().refresh();
  }
}

/// Create/edit sheet for a single category.
class CategoryEditorSheet extends StatefulWidget {
  const CategoryEditorSheet({super.key, this.category});

  final ExpenseCategory? category;

  @override
  State<CategoryEditorSheet> createState() => _CategoryEditorSheetState();
}

class _CategoryEditorSheetState extends State<CategoryEditorSheet> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _name =
      TextEditingController(text: widget.category?.name ?? '');

  late String _icon = widget.category?.icon ?? 'category';
  late String _color = widget.category?.color ?? AppColors.categorySwatches.first;

  bool _saving = false;
  String? _error;

  bool get _isEditing => widget.category != null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color tint = AppColors.readableOn(
      AppColors.fromHex(_color),
      theme.brightness,
    );

    return Form(
      key: _formKey,
      child: AppSheet(
        title: _isEditing ? 'Edit category' : 'New category',
        subtitle: 'Name, colour and icon',
        action: Padding(
          padding: const EdgeInsets.only(right: AppSpacing.sm),
          child: CategoryAvatar(icon: _icon, color: _color, size: 40),
        ),
        footer: AppButton.submit(
          label: _isEditing ? 'Save changes' : 'Add category',
          busy: _saving,
          busyLabel: 'Saving…',
          onPressed: _saving ? null : _save,
        ),
        children: <Widget>[
          const FieldLabel('Name', isRequired: true),
          TextFormField(
            controller: _name,
            autofocus: !_isEditing,
            enabled: !_saving,
            textCapitalization: TextCapitalization.words,
            validator: (String? v) => Validators.required(v, 'Name'),
            decoration: const InputDecoration(hintText: 'Groceries, Rent…'),
          ),
          const SizedBox(height: AppSpacing.lg),

          const FieldLabel('Colour'),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.md,
            children: AppColors.categorySwatches.map((String hex) {
              final bool selected = hex.toUpperCase() == _color.toUpperCase();
              final Color swatch = AppColors.readableOn(
                AppColors.fromHex(hex),
                theme.brightness,
              );
              return InkWell(
                onTap: _saving ? null : () => setState(() => _color = hex),
                borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: swatch,
                    shape: BoxShape.circle,
                    border: selected
                        ? Border.all(
                            color: theme.colorScheme.onSurface,
                            width: 2.5,
                          )
                        : null,
                  ),
                  child: selected
                      ? Icon(
                          Icons.check_rounded,
                          size: 17,
                          // Chosen against the swatch itself: a white tick
                          // disappears on the lighter amber and teal swatches.
                          color:
                              ThemeData.estimateBrightnessForColor(swatch) ==
                                      Brightness.dark
                                  ? Colors.white
                                  : Colors.black87,
                        )
                      : null,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: AppSpacing.lg),

          const FieldLabel('Icon'),
          // Fixed height with its own scroll: the icon set is long, and
          // letting it expand pushed the save button off a short screen.
          SizedBox(
            height: 132,
            child: GridView.count(
              crossAxisCount: 6,
              mainAxisSpacing: AppSpacing.sm,
              crossAxisSpacing: AppSpacing.sm,
              children: CategoryIcons.pickable.map((String name) {
                final bool selected = name == _icon;
                return InkWell(
                  onTap: _saving ? null : () => setState(() => _icon = name),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  child: Container(
                    decoration: BoxDecoration(
                      color: selected
                          ? tint.withOpacity(0.18)
                          : theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                      border: selected
                          ? Border.all(color: tint, width: 1.6)
                          : null,
                    ),
                    child: Icon(
                      CategoryIcons.resolve(name),
                      size: AppSpacing.iconMd,
                      color: selected
                          ? tint
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),

          if (_error != null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            InlineError(message: _error!),
          ],
        ],
      ),
    );
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    final CategoryProvider provider = context.read<CategoryProvider>();
    final bool ok = _isEditing
        ? await provider.update(
            id: widget.category!.id,
            name: _name.text,
            icon: _icon,
            color: _color,
          )
        : await provider.create(
            name: _name.text,
            icon: _icon,
            color: _color,
          );

    if (!mounted) return;

    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = provider.errorMessage ?? 'Could not save the category.';
      });
    }
  }
}
