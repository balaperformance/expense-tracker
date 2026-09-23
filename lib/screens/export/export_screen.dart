import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/formatters.dart';
import '../../models/bank_account.dart';
import '../../models/expense_category.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/category_provider.dart';
import '../../providers/export_provider.dart';
import '../../providers/payment_method_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/export/export_models.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';

/// Choose a report, a period and a format; see what it contains; export it.
///
/// One screen rather than a wizard. The choices are few enough to fit, and
/// seeing the preview update as the period changes is the point — it is what
/// tells the user they picked the right month before they generate a file and
/// open a share sheet.
class ExportScreen extends StatefulWidget {
  const ExportScreen({
    super.key,
    this.initialType = ExportReportType.spendingReport,
    this.initialAccountId,
    this.initialRange,
  });

  /// Preset by the contextual entry points: exporting from a statement opens
  /// on that statement, exporting from Reports opens on the spending report.
  final ExportReportType initialType;
  final String? initialAccountId;
  final ExportDateRange? initialRange;

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  /// Coalesces a burst of choices into one query.
  ///
  /// Picking four categories is four taps, and without this it is also four
  /// round trips whose first three results are thrown away.
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Deferred to the first frame: `start` notifies listeners, which is not
    // allowed while the tree is still building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ExportProvider provider = context.read<ExportProvider>();
      provider.start(
        type: widget.initialType,
        presetAccountId: widget.initialAccountId ?? _onlyAccountId(),
        range: widget.initialRange,
      );
      _reload();
    });
  }

  /// With a single bank account there is nothing to choose, so a statement
  /// export opens ready to run.
  String? _onlyAccountId() {
    final List<BankAccount> accounts =
        context.read<BankAccountProvider>().accounts;
    return accounts.length == 1 ? accounts.first.id : null;
  }

  ExportReferenceData get _reference => ExportReferenceData(
        currencyCode: context.read<SettingsProvider>().currency,
        accounts: context.read<BankAccountProvider>().accounts,
        categories: context.read<CategoryProvider>().categories,
        paymentMethods: context.read<PaymentMethodProvider>().methods,
      );

  Future<void> _reload() async {
    final String? userId = context.read<AuthProvider>().userId;
    if (userId == null) return;
    await context
        .read<ExportProvider>()
        .loadPreview(userId: userId, reference: _reference);
  }

  @override
  Widget build(BuildContext context) {
    final ExportProvider export = context.watch<ExportProvider>();
    final ExportRequest request = export.request;
    final List<BankAccount> accounts =
        context.watch<BankAccountProvider>().accounts;
    final List<ExpenseCategory> categories =
        context.watch<CategoryProvider>().categories;

    return Scaffold(
      appBar: AppBar(title: const Text('Export')),
      bottomNavigationBar: _ExportBar(
        format: request.format,
        enabled: export.preview?.hasRows ?? false,
        busy: export.exporting,
        onExport: _export,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.md,
          AppSpacing.page,
          AppSpacing.xl,
        ),
        children: <Widget>[
          // -----------------------------------------------------------
          // What
          // -----------------------------------------------------------
          const FieldLabel('Report'),
          CardList(
            dividerIndent: AppSpacing.md,
            children: <Widget>[
              for (final ExportReportType type in ExportReportType.values)
                AppListRow(
                  title: type.label,
                  subtitle: type.description,
                  dense: true,
                  onTap: () => _change(() => export.setType(type)),
                  trailing: _Tick(selected: request.type == type),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),

          // -----------------------------------------------------------
          // When
          // -----------------------------------------------------------
          const FieldLabel('Period'),
          _RangePicker(
            range: request.range,
            onChanged: (ExportDateRange range) =>
                _change(() => export.setRange(range)),
          ),
          const SizedBox(height: AppSpacing.xl),

          // -----------------------------------------------------------
          // Which account — statements only
          // -----------------------------------------------------------
          if (request.type.needsAccount) ...<Widget>[
            const FieldLabel('Account', isRequired: true),
            if (accounts.isEmpty)
              const AppNotice(
                message: 'Add a bank account before exporting a statement.',
              )
            else
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: accounts.map((BankAccount account) {
                  return AppChoiceChip(
                    label: account.displayLabel,
                    icon: Icons.account_balance_outlined,
                    selected: request.accountId == account.id,
                    onSelected: () =>
                        _change(() => export.setAccount(account.id)),
                  );
                }).toList(),
              ),
            const SizedBox(height: AppSpacing.xl),
          ],

          // -----------------------------------------------------------
          // Which categories — where narrowing makes sense
          // -----------------------------------------------------------
          if (request.type.supportsCategoryFilter &&
              categories.isNotEmpty) ...<Widget>[
            FieldLabel(
              'Categories',
              hint: request.categoryIds.isEmpty
                  ? 'All'
                  : '${request.categoryIds.length} selected',
            ),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                AppChoiceChip(
                  label: 'All categories',
                  selected: request.categoryIds.isEmpty,
                  onSelected: () => _change(export.clearCategories),
                ),
                ...categories.map((ExpenseCategory category) {
                  return AppChoiceChip(
                    label: category.name,
                    selected: request.categoryIds.contains(category.id),
                    tone: AppColors.readableOn(
                      AppColors.fromHex(category.color),
                      Theme.of(context).brightness,
                    ),
                    onSelected: () =>
                        _change(() => export.toggleCategory(category.id)),
                  );
                }),
              ],
            ),
            const SizedBox(height: AppSpacing.xl),
          ],

          // -----------------------------------------------------------
          // Preview
          // -----------------------------------------------------------
          const FieldLabel('Preview'),
          _Preview(export: export, onRetry: _reload),
          const SizedBox(height: AppSpacing.xl),

          // -----------------------------------------------------------
          // Format
          // -----------------------------------------------------------
          const FieldLabel('Format'),
          Row(
            children: <Widget>[
              for (final ExportFormat format in ExportFormat.values) ...<Widget>[
                if (format != ExportFormat.values.first)
                  const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: _FormatTile(
                    format: format,
                    selected: request.format == format,
                    onTap: () => export.setFormat(format),
                  ),
                ),
              ],
            ],
          ),

          if (export.exportError != null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            InlineError(message: export.exportError!),
          ],
        ],
      ),
    );
  }

  /// Applies a choice and refetches, since every choice above changes what
  /// the preview should show.
  void _change(VoidCallback mutate) {
    mutate();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) _reload();
    });
  }

  Future<void> _export() async {
    final ExportProvider export = context.read<ExportProvider>();

    // iPad anchors the share popover to a rectangle; everything else ignores
    // it. Taking the whole screen keeps it centred rather than pointing at
    // nothing.
    final Size size = MediaQuery.sizeOf(context);

    final ExportResult? result = await export.exportAndShare(
      reference: _reference,
      shareOrigin: Rect.fromLTWH(0, 0, size.width, size.height / 2),
    );

    if (!mounted) return;

    if (result != null) {
      AppFeedback.success(
        context,
        '${result.fileName} ready — ${result.readableSize}',
      );
    } else if (export.exportError != null) {
      AppFeedback.error(context, export.exportError!);
    }
  }
}

/// Preset ranges plus a custom picker.
class _RangePicker extends StatelessWidget {
  const _RangePicker({required this.range, required this.onChanged});

  final ExportDateRange range;
  final ValueChanged<ExportDateRange> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DateTime now = DateTime.now();

    final ExportDateRange thisMonth = ExportDateRange.month(now);
    final ExportDateRange lastMonth =
        ExportDateRange.month(DateTime(now.year, now.month - 1, 1));
    final ExportDateRange last90 = ExportDateRange.lastDays(90, now: now);
    final ExportDateRange thisYear = ExportDateRange.year(now);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            AppChoiceChip(
              label: 'This month',
              selected: range == thisMonth,
              onSelected: () => onChanged(thisMonth),
            ),
            AppChoiceChip(
              label: 'Last month',
              selected: range == lastMonth,
              onSelected: () => onChanged(lastMonth),
            ),
            AppChoiceChip(
              label: 'Last 90 days',
              selected: range == last90,
              onSelected: () => onChanged(last90),
            ),
            AppChoiceChip(
              label: 'This year',
              selected: range == thisYear,
              onSelected: () => onChanged(thisYear),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: <Widget>[
            Expanded(
              child: SelectField(
                value: Formatters.dayMonthYear(range.start),
                icon: Icons.calendar_today_rounded,
                onTap: () => _pick(context, isStart: true),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              child: Text('to', style: theme.textTheme.bodySmall),
            ),
            Expanded(
              child: SelectField(
                value: Formatters.dayMonthYear(range.endInclusive),
                icon: Icons.event_rounded,
                onTap: () => _pick(context, isStart: false),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _pick(BuildContext context, {required bool isStart}) async {
    final DateTime now = DateTime.now();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: isStart ? range.start : range.endInclusive,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (picked == null) return;

    final DateTime day = DateTime(picked.year, picked.month, picked.day);
    // An end before a start is not an error worth an error message — the two
    // dates simply swap, which is what the user meant.
    onChanged(
      isStart
          ? (day.isAfter(range.endInclusive)
              ? ExportDateRange(range.endInclusive, day)
              : ExportDateRange(day, range.endInclusive))
          : (day.isBefore(range.start)
              ? ExportDateRange(day, range.start)
              : ExportDateRange(range.start, day)),
    );
  }
}

/// What the export will contain, before the file exists.
class _Preview extends StatelessWidget {
  const _Preview({required this.export, required this.onRetry});

  final ExportProvider export;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (!export.request.isRunnable) {
      return const AppNotice(
        message: 'Choose an account to preview the statement.',
      );
    }

    if (export.isLoading) {
      return const SurfaceCard(
        child: Column(
          children: <Widget>[
            Skeleton(height: 16, width: 140),
            SizedBox(height: AppSpacing.md),
            Skeleton(height: 30),
            SizedBox(height: AppSpacing.sm),
            Skeleton(height: 30),
          ],
        ),
      );
    }

    if (export.hasError) {
      return ErrorView(
        compact: true,
        message: export.errorMessage ?? 'Could not load the data.',
        onRetry: onRetry,
      );
    }

    final ExportDataset? dataset = export.preview;
    if (dataset == null) return const SizedBox.shrink();

    if (!dataset.hasRows) {
      return const AppNotice(
        icon: Icons.inbox_outlined,
        message: 'Nothing to export for this period. Try a wider date range '
            'or a different report.',
      );
    }

    final ThemeData theme = Theme.of(context);

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(dataset.title, style: theme.textTheme.titleSmall),
              ),
              AppBadge(label: dataset.periodLabel),
            ],
          ),
          if (dataset.subtitle != null) ...<Widget>[
            const SizedBox(height: AppSpacing.xxs),
            Text(dataset.subtitle!, style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: AppSpacing.md),

          for (final ExportSummaryItem item in dataset.summary)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(item.label, style: theme.textTheme.bodySmall),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    item.value,
                    style: item.emphasis
                        ? theme.textTheme.titleSmall
                        : theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),

          const SizedBox(height: AppSpacing.md),
          Divider(height: 1, color: theme.colorScheme.outline),
          const SizedBox(height: AppSpacing.md),

          for (final ExportSection section in dataset.sections)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Row(
                children: <Widget>[
                  Icon(
                    section.isEmpty
                        ? Icons.remove_rounded
                        : Icons.table_rows_outlined,
                    size: AppSpacing.iconSm,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      section.title,
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    section.isEmpty
                        ? 'empty'
                        : '${section.rows.length} '
                            '${section.rows.length == 1 ? 'row' : 'rows'}',
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),

          if (export.isTruncated) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            AppNotice(
              icon: Icons.warning_amber_rounded,
              tone: ToneColors.warning(context),
              message: 'This period has more rows than one export can hold. '
                  'Narrow the date range to include everything.',
            ),
          ],
        ],
      ),
    );
  }
}

class _FormatTile extends StatelessWidget {
  const _FormatTile({
    required this.format,
    required this.selected,
    required this.onTap,
  });

  final ExportFormat format;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color accent = theme.colorScheme.primary;

    return Material(
      color: selected ? ToneColors.wash(context, accent) : theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.md,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(
              color: selected ? accent : theme.colorScheme.outline,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                format == ExportFormat.pdf
                    ? Icons.picture_as_pdf_outlined
                    : Icons.grid_on_rounded,
                size: AppSpacing.iconMd,
                color: selected ? accent : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      format.label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: selected ? accent : null,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      format.description,
                      style: theme.textTheme.labelSmall,
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tick extends StatelessWidget {
  const _Tick({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    if (!selected) {
      return Icon(
        Icons.circle_outlined,
        size: AppSpacing.iconMd,
        color: Theme.of(context).colorScheme.outline,
      );
    }
    return Icon(
      Icons.check_circle_rounded,
      size: AppSpacing.iconMd,
      color: Theme.of(context).colorScheme.primary,
    );
  }
}

/// Pinned primary action, matching the save bars elsewhere.
class _ExportBar extends StatelessWidget {
  const _ExportBar({
    required this.format,
    required this.enabled,
    required this.busy,
    required this.onExport,
  });

  final ExportFormat format;
  final bool enabled;
  final bool busy;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.colorScheme.outline)),
      ),
      padding: EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.md,
        AppSpacing.page,
        AppSpacing.md + MediaQuery.paddingOf(context).bottom,
      ),
      child: AppButton.submit(
        label: 'Export ${format.label}',
        icon: Icons.ios_share_rounded,
        busy: busy,
        busyLabel: 'Preparing…',
        onPressed: enabled && !busy ? onExport : null,
      ),
    );
  }
}
