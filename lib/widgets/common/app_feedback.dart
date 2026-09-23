import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_glass.dart';
import '../../core/theme/app_spacing.dart';
import 'app_buttons.dart';
import 'money_text.dart';

/// Opens a dialog over a blurred page.
///
/// The counterpart to `showAppSheet`: one place that decides what a modal
/// looks like, so a confirmation raised from any screen sits on the same
/// glass. The blur covers the whole screen rather than just the dialog's
/// footprint, which is what makes the page read as *behind* the dialog
/// instead of merely dimmed.
///
/// This is a modal — it exists for a moment and nothing scrolls under it —
/// so its blur is paid for once and released.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool useRootNavigator = false,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    useRootNavigator: useRootNavigator,
    // The scrim is drawn inside the blur layer below, so the barrier itself
    // stays clear; a second dim here would double it.
    barrierColor: Colors.transparent,
    builder: (BuildContext dialogContext) => Stack(
      children: <Widget>[
        Positioned.fill(
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: AppGlass.blurOverlay,
              sigmaY: AppGlass.blurOverlay,
            ),
            child: ColoredBox(color: Colors.black.withOpacity(0.24)),
          ),
        ),
        builder(dialogContext),
      ],
    ),
  );
}

/// Snackbars and confirmation dialogs, so tone and styling stay consistent.
///
/// Snackbars sit on `inverseSurface`, which is dark in light mode and light
/// in dark mode. Every colour here therefore derives from `onInverseSurface`
/// — a hard-coded white icon is invisible in one of the two themes.
class AppFeedback {
  const AppFeedback._();

  static void success(BuildContext context, String message) => _show(
        context,
        message,
        Icons.check_circle_rounded,
        ToneColors.income(context),
      );

  static void error(BuildContext context, String message) => _show(
        context,
        message,
        Icons.error_outline_rounded,
        ToneColors.expense(context),
      );

  static void info(BuildContext context, String message) =>
      _show(context, message, Icons.info_outline_rounded, null);

  static void _show(
    BuildContext context,
    String message,
    IconData icon,
    Color? accent,
  ) {
    final ThemeData theme = Theme.of(context);
    final Color onBar = theme.colorScheme.onInverseSurface;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        content: Row(
          children: <Widget>[
            Icon(icon, size: AppSpacing.iconMd - 2, color: accent ?? onBar),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(color: onBar),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Returns true only when the user explicitly confirms.
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    String confirmLabel = 'Delete',
    String cancelLabel = 'Cancel',
    bool destructive = true,
  }) async {
    final bool? result = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          titlePadding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          contentPadding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          actionsPadding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          // Both buttons come from the shared system and hug their labels,
          // so a dialog's actions match the buttons on the page behind it.
          actions: <Widget>[
            AppButtonRow(
              expand: false,
              cancelLabel: cancelLabel,
              onCancel: () => Navigator.of(dialogContext).pop(false),
              confirmLabel: confirmLabel,
              confirmVariant: destructive
                  ? AppButtonVariant.danger
                  : AppButtonVariant.primary,
              onConfirm: () => Navigator.of(dialogContext).pop(true),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }
}
