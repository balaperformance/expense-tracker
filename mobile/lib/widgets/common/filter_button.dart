import 'package:flutter/material.dart';

import '../../core/theme/app_spacing.dart';

/// The app-bar Filter button, with a count badge while filters are on.
/// Shared by Expenses and Income.
class FilterButton extends StatelessWidget {
  const FilterButton({super.key, required this.count, required this.onPressed});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        IconButton(
          tooltip: 'Filter',
          onPressed: onPressed,
          icon: Icon(
            count > 0 ? Icons.filter_alt_rounded : Icons.tune_rounded,
            color: count > 0 ? scheme.primary : null,
          ),
        ),
        if (count > 0)
          Positioned(
            right: 5,
            top: 7,
            child: Container(
              constraints: const BoxConstraints(minWidth: 15),
              height: 15,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
                border: Border.all(color: scheme.surface, width: 1.5),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontSize: 9.5,
                  height: 1,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
