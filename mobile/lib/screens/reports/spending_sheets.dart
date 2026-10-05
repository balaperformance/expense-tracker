import 'package:flutter/material.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/date_utils.dart';
import '../../core/utils/formatters.dart';
import '../../models/insights.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_fields.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/surface_card.dart';

/// The Spending tab's sheets — the phone's counterparts of the web's
/// features/reports/SpendingFilters.tsx: the date range, and the filters that
/// narrow the analysis. Both edit a local copy and hand it back on a choice,
/// so backing out of a sheet changes nothing.

/// A date range picked in [showPeriodSheet]: a preset, or 'custom' with its
/// two dates.
typedef SpendingPeriodChoice = ({String preset, ({DateTime start, DateTime end})? custom});

/// The presets, for when the engine's overview has not given its own list.
const List<({String value, String label})> spendingPeriodPresets = <({String value, String label})>[
  (value: 'thisMonth', label: 'This month'),
  (value: 'lastMonth', label: 'Last month'),
  (value: 'last3', label: 'Last 3 months'),
  (value: 'last6', label: 'Last 6 months'),
  (value: 'last12', label: 'Last 12 months'),
];

/// Opens the date range sheet; null when dismissed.
Future<SpendingPeriodChoice?> showPeriodSheet(
  BuildContext context, {
  required List<({String value, String label})> presets,
  required String preset,
  ({DateTime start, DateTime end})? custom,
  String? customLabel,
  required DateTime earliest,
}) {
  return showAppSheet<SpendingPeriodChoice>(
    context: context,
    builder: (_) => PeriodSheet(
      presets: presets.isEmpty ? spendingPeriodPresets : presets,
      preset: preset,
      custom: custom,
      customLabel: customLabel,
      earliest: earliest,
    ),
  );
}

/// What the filter sheet opens on: only the tags (from the tags chip), or
/// everything that narrows the analysis.
enum SpendingFilterFocus { tags, all }

/// Opens the filter sheet; the filter to apply, or null when dismissed.
Future<SpendingFilter?> showSpendingFilterSheet(
  BuildContext context, {
  required SpendingFilter initial,
  required SpendingFilterOptions options,
  SpendingFilterFocus focus = SpendingFilterFocus.all,
}) {
  return showAppSheet<SpendingFilter>(
    context: context,
    builder: (_) => SpendingFilterSheet(initial: initial, options: options, focus: focus),
  );
}

/// The date range: a preset, or any two dates.
class PeriodSheet extends StatefulWidget {
  const PeriodSheet({
    super.key,
    required this.presets,
    required this.preset,
    required this.earliest,
    this.custom,
    this.customLabel,
  });

  final List<({String value, String label})> presets;
  final String preset;
  final ({DateTime start, DateTime end})? custom;

  /// The custom range as the engine labels it, shown when it is the one in use.
  final String? customLabel;

  /// The earliest date a custom range may start: years back is fine, the
  /// history is read when it is chosen.
  final DateTime earliest;

  @override
  State<PeriodSheet> createState() => _PeriodSheetState();
}

class _PeriodSheetState extends State<PeriodSheet> {
  late DateTime? _from = widget.custom?.start;
  late DateTime? _to = widget.custom?.end;

  bool get _valid => _from != null && _to != null && !_from!.isAfter(_to!);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DateTime today = AppDateUtils.today();
    return AppSheet(
      title: 'Date range',
      children: <Widget>[
        CardList(
          dividerIndent: AppSpacing.md,
          children: <Widget>[
            for (final ({String value, String label}) option in widget.presets)
              AppListRow(
                dense: true,
                title: option.label,
                trailing: option.value == widget.preset
                    ? Icon(Icons.check_circle_rounded, size: AppSpacing.iconMd, color: theme.colorScheme.primary)
                    : null,
                onTap: () => Navigator.of(context).pop<SpendingPeriodChoice>((preset: option.value, custom: null)),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        FieldLabel(
          'Custom range',
          hint: widget.preset == 'custom' && widget.custom != null ? widget.customLabel : null,
        ),
        Row(
          children: <Widget>[
            Expanded(
              child: _DateBox(
                placeholder: 'From',
                icon: Icons.calendar_today_rounded,
                value: _from,
                first: widget.earliest,
                last: today,
                onPicked: (DateTime d) => setState(() => _from = d),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _DateBox(
                placeholder: 'To',
                icon: Icons.date_range_rounded,
                value: _to,
                first: widget.earliest,
                last: today,
                onPicked: (DateTime d) => setState(() => _to = d),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        AppButton(
          label: 'Use this range',
          expand: true,
          onPressed: _valid
              ? () => Navigator.of(context)
                  .pop<SpendingPeriodChoice>((preset: 'custom', custom: (start: _from!, end: _to!)))
              : null,
        ),
      ],
    );
  }
}

/// A field-shaped date button bounded to [first]…[last]. Narrower padding
/// than a [SelectField], so a full date fits two to a row on a 320dp phone.
class _DateBox extends StatelessWidget {
  const _DateBox({
    required this.placeholder,
    required this.icon,
    required this.value,
    required this.first,
    required this.last,
    required this.onPicked,
  });

  final String placeholder;
  final IconData icon;
  final DateTime? value;
  final DateTime first;
  final DateTime last;
  final ValueChanged<DateTime> onPicked;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool hasValue = value != null;
    return Semantics(
      button: true,
      label: hasValue ? '$placeholder: ${Formatters.dayMonthYear(value!)}' : placeholder,
      excludeSemantics: true,
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: InkWell(
          onTap: () => _pick(context),
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          child: Container(
            height: AppSpacing.fieldHeight,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              children: <Widget>[
                Icon(icon, size: AppSpacing.iconSm + 1, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    hasValue ? Formatters.dayMonthYear(value!) : placeholder,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: hasValue ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final DateTime start = value ?? last;
    final DateTime initial = start.isBefore(first) ? first : (start.isAfter(last) ? last : start);
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (picked != null) onPicked(DateTime(picked.year, picked.month, picked.day));
  }
}

/// Merchants beyond this many get a search field, and only this many show
/// until something is searched for.
const int _merchantShown = 16;

/// How many merchants a search lists.
const int _merchantFound = 40;

/// What two spellings of a name have in common, as the web's `tagKey`: no
/// leading '#', single spaces, any case.
String _searchKey(String text) =>
    text.replaceFirst(RegExp(r'^\s*#+'), '').replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

List<String> _toggle(List<String> list, String id) =>
    list.contains(id) ? list.where((String x) => x != id).toList() : <String>[...list, id];

/// Tags first — the report's main lens — then everything else that narrows it.
class SpendingFilterSheet extends StatefulWidget {
  const SpendingFilterSheet({
    super.key,
    required this.initial,
    required this.options,
    this.focus = SpendingFilterFocus.all,
  });

  final SpendingFilter initial;

  /// What the chosen range offers: every tag with its use, and the
  /// categories, merchants and sources that occur in it.
  final SpendingFilterOptions options;
  final SpendingFilterFocus focus;

  @override
  State<SpendingFilterSheet> createState() => _SpendingFilterSheetState();
}

class _SpendingFilterSheetState extends State<SpendingFilterSheet> {
  late SpendingFilter _filter = widget.initial;
  final TextEditingController _search = TextEditingController();
  String _query = '';

  bool get _tagsOnly => widget.focus == SpendingFilterFocus.tags;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _set(SpendingFilter next) => setState(() => _filter = next);

  @override
  Widget build(BuildContext context) {
    final SpendingFilterOptions options = widget.options;
    final int count = _filter.count;
    return AppSheet(
      title: _tagsOnly ? 'Tags' : 'Filters',
      subtitle: count > 0
          ? '$count selected'
          : (_tagsOnly ? 'Expenses with any of the chosen tags' : 'Narrow down the analysis'),
      action: AppButton(
        label: 'Clear',
        variant: AppButtonVariant.ghost,
        size: AppButtonSize.small,
        onPressed: count == 0
            ? null
            : () => _set(_tagsOnly ? _filter.copyWith(tagIds: const <String>[]) : SpendingFilter.empty),
      ),
      footer: AppButton.submit(
        label: 'Apply',
        onPressed: () => Navigator.of(context).pop<SpendingFilter>(_filter),
      ),
      children: <Widget>[
        FieldLabel('Tags', hint: _filter.tagIds.isEmpty ? null : '${_filter.tagIds.length} selected'),
        if (options.tags.isEmpty)
          const AppNotice(
            icon: Icons.sell_outlined,
            message: 'No tags yet. Add tags such as #carspending or #family to expenses, '
                'and they can be analysed here.',
          )
        else
          _ChipGroup(
            children: <Widget>[
              for (final ({String id, String name, int count}) tag in options.tags)
                AppChoiceChip(
                  label: '#${tag.name}${tag.count > 0 ? ' · ${tag.count}' : ''}',
                  selected: _filter.tagIds.contains(tag.id),
                  onSelected: () => _set(_filter.copyWith(tagIds: _toggle(_filter.tagIds, tag.id))),
                ),
            ],
          ),
        if (!_tagsOnly) ..._rest(options),
      ],
    );
  }

  List<Widget> _rest(SpendingFilterOptions options) {
    final String query = _searchKey(_query);
    final List<({String key, String label, double total})> merchants = options.merchants;
    final List<({String key, String label, double total})> listed = merchants
        .where((({String key, String label, double total}) m) =>
            _filter.merchantKeys.contains(m.key) || query.isEmpty || _searchKey(m.label).contains(query))
        .take(query.isEmpty ? _merchantShown : _merchantFound)
        .toList();
    // A chosen merchant stays offered, however far down the list it sits.
    final Set<String> listedKeys = listed.map((({String key, String label, double total}) m) => m.key).toSet();
    for (final ({String key, String label, double total}) m in merchants) {
      if (_filter.merchantKeys.contains(m.key) && !listedKeys.contains(m.key)) listed.add(m);
    }

    return <Widget>[
      const SizedBox(height: AppSpacing.xl),
      FieldLabel('Categories', hint: _filter.categoryIds.isEmpty ? null : '${_filter.categoryIds.length} selected'),
      _ChipGroup(
        children: <Widget>[
          for (final ({String id, String name}) category in options.categories)
            AppChoiceChip(
              label: category.name,
              selected: _filter.categoryIds.contains(category.id),
              onSelected: () => _set(_filter.copyWith(categoryIds: _toggle(_filter.categoryIds, category.id))),
            ),
        ],
      ),
      const SizedBox(height: AppSpacing.xl),
      FieldLabel(
        'Merchants',
        hint: _filter.merchantKeys.isEmpty ? 'Most spent first' : '${_filter.merchantKeys.length} selected',
      ),
      if (merchants.length > _merchantShown) ...<Widget>[
        SearchField(
          controller: _search,
          hintText: 'Find a merchant',
          onChanged: (String value) => setState(() => _query = value),
        ),
        const SizedBox(height: AppSpacing.sm),
      ],
      _ChipGroup(
        children: <Widget>[
          for (final ({String key, String label, double total}) m in listed)
            AppChoiceChip(
              label: m.label,
              selected: _filter.merchantKeys.contains(m.key),
              onSelected: () => _set(_filter.copyWith(merchantKeys: _toggle(_filter.merchantKeys, m.key))),
            ),
        ],
      ),
      if (options.sources.length > 1) ...<Widget>[
        const SizedBox(height: AppSpacing.xl),
        const FieldLabel('Paid from', hint: 'Accounts, cards and cash'),
        _ChipGroup(
          children: <Widget>[
            for (final ({String key, String label}) source in options.sources)
              AppChoiceChip(
                label: source.label,
                selected: _filter.sources.contains(source.key),
                onSelected: () => _set(_filter.copyWith(sources: _toggle(_filter.sources, source.key))),
              ),
          ],
        ),
      ],
      if (options.paymentMethods.isNotEmpty) ...<Widget>[
        const SizedBox(height: AppSpacing.xl),
        const FieldLabel('Payment methods'),
        _ChipGroup(
          children: <Widget>[
            for (final ({String id, String name}) method in options.paymentMethods)
              AppChoiceChip(
                label: method.name,
                selected: _filter.paymentMethodIds.contains(method.id),
                onSelected: () =>
                    _set(_filter.copyWith(paymentMethodIds: _toggle(_filter.paymentMethodIds, method.id))),
              ),
          ],
        ),
      ],
    ];
  }
}

class _ChipGroup extends StatelessWidget {
  const _ChipGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: children);
  }
}
