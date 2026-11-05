import 'package:flutter/material.dart';

import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/date_range_fields.dart';

/// The Income list's filter: a date range, chosen exactly as on Expenses.
///
/// Edits a local copy and returns it on Apply, so backing out leaves the list
/// untouched.
class IncomeFilterSheet extends StatefulWidget {
  const IncomeFilterSheet({super.key, this.from, this.to});

  final DateTime? from;
  final DateTime? to;

  @override
  State<IncomeFilterSheet> createState() => _IncomeFilterSheetState();
}

class _IncomeFilterSheetState extends State<IncomeFilterSheet> {
  late DateTime? _from = widget.from;
  late DateTime? _to = widget.to;

  bool get _hasAny => _from != null || _to != null;

  @override
  Widget build(BuildContext context) {
    return AppSheet(
      title: 'Filters',
      subtitle: dateRangeLabel(_from, _to) ?? 'Narrow down the list',
      action: TextButton(
        onPressed: _hasAny
            ? () => setState(() {
                  _from = null;
                  _to = null;
                })
            : null,
        child: const Text('Clear all'),
      ),
      footer: AppButton.submit(
        label: 'Apply',
        onPressed: () => Navigator.of(context).pop((from: _from, to: _to)),
      ),
      children: <Widget>[
        DateRangeFields(
          from: _from,
          to: _to,
          onChanged: (DateTime? from, DateTime? to) => setState(() {
            _from = from;
            _to = to;
          }),
        ),
      ],
    );
  }
}
