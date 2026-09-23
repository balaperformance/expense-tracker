import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_glass.dart';
import '../../core/theme/app_spacing.dart';

/// Opens a modal sheet on the app's glass surface.
///
/// Every `showModalBottomSheet` in the app goes through here, which is what
/// makes the sheet material a one-file decision: the blur, the fill, the lit
/// top edge, the corner radius, the drag handle and the barrier are all
/// settled once, and a screen only supplies its content.
///
/// The theme deliberately leaves `bottomSheetTheme` transparent — a surface
/// there would paint *behind* this glass and cancel the blur.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isDismissible = true,
  bool enableDrag = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.32),
    builder: (BuildContext sheetContext) =>
        _GlassSheetSurface(child: builder(sheetContext)),
  );
}

/// The blurred pane every sheet sits on.
///
/// This is one of the few places a `BackdropFilter` earns its cost: the page
/// is visibly behind the sheet and the user can drag the sheet over it.
class _GlassSheetSurface extends StatelessWidget {
  const _GlassSheetSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final GlassTokens glass = AppGlass.of(context);
    const BorderRadius shape = BorderRadius.vertical(
      top: Radius.circular(AppSpacing.radiusXxl),
    );

    return ClipRRect(
      borderRadius: shape,
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: AppGlass.blurOverlay,
          sigmaY: AppGlass.blurOverlay,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: glass.fillStrong,
            borderRadius: shape,
            border: Border(
              top: BorderSide(color: glass.borderTop, width: 0.75),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const _DragHandle(),
              Flexible(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.35),
          borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        ),
      ),
    );
  }
}

/// Standard layout for every modal bottom sheet in the app.
///
/// Centralising this fixes three things that were previously re-solved (and
/// re-solved slightly differently) in each sheet: lifting content above the
/// keyboard, keeping a long form scrollable on a short screen, and clearing
/// the gesture inset at the bottom.
///
/// Open it with `showModalBottomSheet(isScrollControlled: true, ...)` — the
/// drag handle and rounded top come from the theme.
class AppSheet extends StatelessWidget {
  const AppSheet({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.action,
    this.footer,
  });

  final String title;
  final String? subtitle;

  /// Optional control on the title row — usually a delete or reset button.
  final Widget? action;

  final List<Widget> children;

  /// Pinned below the scroll area. Use for the primary action so it stays
  /// reachable while the user is still scrolling the form.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final double maxHeight = MediaQuery.sizeOf(context).height * 0.9;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.xs,
                AppSpacing.sm,
                AppSpacing.md,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(title, style: theme.textTheme.titleLarge),
                        if (subtitle != null) ...<Widget>[
                          const SizedBox(height: AppSpacing.xxs),
                          Text(subtitle!, style: theme.textTheme.bodySmall),
                        ],
                      ],
                    ),
                  ),
                  if (action != null) action!,
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.md,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
            if (footer != null)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.xs,
                  AppSpacing.lg,
                  AppSpacing.md + MediaQuery.paddingOf(context).bottom,
                ),
                child: footer,
              )
            else
              SizedBox(
                height: AppSpacing.sm + MediaQuery.paddingOf(context).bottom,
              ),
          ],
        ),
      ),
    );
  }
}
