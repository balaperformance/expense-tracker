import 'package:flutter/material.dart';

import '../../core/theme/app_motion.dart';
import '../../core/theme/app_spacing.dart';
import 'money_text.dart';

/// What a button means, which decides how loud it looks.
///
/// There is exactly one [AppButtonVariant.primary] per screen. Everything
/// else steps down from it, so the eye lands on the committing action without
/// that action having to be large.
enum AppButtonVariant {
  /// The one committing action. Filled with the brand colour.
  primary,

  /// An alternative action of equal standing. Outlined.
  secondary,

  /// A supporting action inside a card or a busy row. Tinted, no border.
  tonal,

  /// Destructive. Filled red, and only where the outcome is irreversible.
  danger,

  /// The quietest form — dismissals, "see all", inline links.
  ghost,
}

/// How large a button is drawn.
///
/// Both sizes clear the 48px hit target through Material's padded tap area;
/// only the painted box changes.
enum AppButtonSize {
  /// 40px. The default.
  medium,

  /// 32px. Inside a card, beside a field, in a compact empty state.
  small,

  /// 44px. Reserved for a pinned save bar or a sheet footer — the one place
  /// a full-width button is correct rather than lazy.
  large,
}

/// The button used everywhere in the app.
///
/// Sizing, radius, typography, icon size and icon spacing all come from here,
/// so a button cannot drift screen to screen. A button hugs its label by
/// default; [expand] is opt-in and belongs only to a committing action that
/// owns the full width of a bar or sheet.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.size = AppButtonSize.medium,
    this.icon,
    this.trailingIcon,
    this.expand = false,
    this.busy = false,
    this.busyLabel,
  });

  /// Convenience for the commonest case: a full-width committing action.
  const AppButton.submit({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.busyLabel,
    this.variant = AppButtonVariant.primary,
  })  : size = AppButtonSize.large,
        trailingIcon = null,
        expand = true;

  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final AppButtonSize size;
  final IconData? icon;
  final IconData? trailingIcon;

  /// Stretches to the parent's width. Off by default.
  final bool expand;

  /// Swaps the leading icon for a spinner and blocks the press, so a saving
  /// form stays visible instead of being covered by an overlay.
  final bool busy;
  final String? busyLabel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    final double height = switch (size) {
      AppButtonSize.small => AppSpacing.buttonHeightSm,
      AppButtonSize.medium => AppSpacing.buttonHeight,
      AppButtonSize.large => AppSpacing.buttonHeightLg,
    };
    final double padX = size == AppButtonSize.small
        ? AppSpacing.buttonPadXSm + 2
        : AppSpacing.buttonPadX;
    final double iconSize = size == AppButtonSize.small
        ? AppSpacing.buttonIconSm
        : AppSpacing.buttonIcon;
    final TextStyle? textStyle = size == AppButtonSize.small
        ? theme.textTheme.labelLarge?.copyWith(fontSize: 13)
        : theme.textTheme.labelLarge;

    final (Color background, Color foreground, BorderSide? border) =
        switch (variant) {
      AppButtonVariant.primary => (scheme.primary, scheme.onPrimary, null),
      AppButtonVariant.danger => (scheme.error, scheme.onError, null),
      AppButtonVariant.secondary => (
          Colors.transparent,
          scheme.onSurface,
          BorderSide(color: scheme.outline),
        ),
      AppButtonVariant.tonal => (
          ToneColors.wash(context, scheme.primary),
          scheme.primary,
          null,
        ),
      AppButtonVariant.ghost => (
          Colors.transparent,
          scheme.primary,
          null,
        ),
    };

    final ButtonStyle style = ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(
        Size(expand ? double.infinity : 0, height),
      ),
      maximumSize: WidgetStatePropertyAll<Size>(
        Size(expand ? double.infinity : double.infinity, height),
      ),
      padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: padX),
      ),
      iconSize: WidgetStatePropertyAll<double>(iconSize),
      textStyle: WidgetStatePropertyAll<TextStyle?>(textStyle),
      backgroundColor: WidgetStateProperty.resolveWith<Color>(
        (Set<WidgetState> states) => states.contains(WidgetState.disabled)
            ? (variant == AppButtonVariant.primary ||
                    variant == AppButtonVariant.danger
                ? scheme.onSurface.withOpacity(0.10)
                : Colors.transparent)
            : background,
      ),
      foregroundColor: WidgetStateProperty.resolveWith<Color>(
        (Set<WidgetState> states) => states.contains(WidgetState.disabled)
            ? scheme.onSurfaceVariant
            : foreground,
      ),
      overlayColor: WidgetStatePropertyAll<Color>(
        foreground.withOpacity(0.08),
      ),
      side: border == null
          ? null
          : WidgetStateProperty.resolveWith<BorderSide>(
              (Set<WidgetState> states) => states.contains(WidgetState.disabled)
                  ? BorderSide(color: scheme.outline)
                  : border,
            ),
      elevation: const WidgetStatePropertyAll<double>(0),
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusButton),
        ),
      ),
      // Painted short, hit at 48. Density must not cost reachability.
      tapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      alignment: Alignment.center,
    );

    final Widget child = _content(context, iconSize, foreground);

    // The scale is applied outside the button and observes pointer events
    // without recognising them, so the button keeps sole ownership of the tap.
    return AppPressEffect(
      enabled: !busy && onPressed != null,
      child: TextButton(
        onPressed: busy ? null : onPressed,
        style: style,
        child: child,
      ),
    );
  }

  Widget _content(BuildContext context, double iconSize, Color foreground) {
    final String text = busy ? (busyLabel ?? label) : label;

    if (busy) {
      return Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: iconSize,
            height: iconSize,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              // Matches the label, so the spinner never disappears against
              // the button in one of the two themes.
              color: foreground,
            ),
          ),
          const SizedBox(width: AppSpacing.buttonIconGap),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    // maxLines is not optional: the style clamps the button's height, so a
    // label allowed to wrap would overflow that clamp rather than ellipsise.
    if (icon == null && trailingIcon == null) {
      return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);
    }

    return Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: iconSize),
          const SizedBox(width: AppSpacing.buttonIconGap),
        ],
        Flexible(
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        if (trailingIcon != null) ...<Widget>[
          const SizedBox(width: AppSpacing.buttonIconGap),
          Icon(trailingIcon, size: iconSize),
        ],
      ],
    );
  }
}

/// Compact extended floating action button.
///
/// Sized from [AppSpacing.fabHeight] so it reads as the same family as the
/// buttons in the page rather than as a larger, separate species. Material's
/// default extended FAB is 48px tall with a 24px icon and 20px padding, which
/// is what made the previous one look oversized.
class AppFab extends StatelessWidget {
  const AppFab({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.add_rounded,
    this.heroTag,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData icon;
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      heroTag: heroTag,
      onPressed: onPressed,
      icon: Icon(icon, size: AppSpacing.buttonIcon + 1),
      label: Text(label),
    );
  }
}

/// Icon-only action, for app bars and the trailing slot of a row.
///
/// Wraps `IconButton` only to guarantee the tooltip and the size come from
/// the scale rather than from whatever each call site happened to pass.
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.tone,
    this.compact = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? tone;

  /// For a trailing slot inside a list row, where a 40px box is too wide.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      color: tone,
      iconSize: compact ? AppSpacing.iconMd : AppSpacing.iconLg - 2,
      visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
      constraints: compact
          ? const BoxConstraints(minWidth: 34, minHeight: 34)
          : null,
      icon: Icon(icon),
    );
  }
}

/// A pair of buttons — cancel beside confirm — sized and ordered once.
///
/// Confirm sits on the right and is the only filled one, which is the
/// arrangement dialogs and sheets already use; having it in one place stops
/// the pair drifting apart between screens.
class AppButtonRow extends StatelessWidget {
  const AppButtonRow({
    super.key,
    required this.confirmLabel,
    required this.onConfirm,
    this.cancelLabel = 'Cancel',
    this.onCancel,
    this.confirmVariant = AppButtonVariant.primary,
    this.busy = false,
    this.expand = true,
  });

  final String confirmLabel;
  final VoidCallback? onConfirm;
  final String cancelLabel;
  final VoidCallback? onCancel;
  final AppButtonVariant confirmVariant;
  final bool busy;

  /// Splits the available width between the two. False lets both hug.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final Widget cancel = AppButton(
      label: cancelLabel,
      variant: AppButtonVariant.secondary,
      onPressed: busy ? null : onCancel,
      expand: expand,
    );
    final Widget confirm = AppButton(
      label: confirmLabel,
      variant: confirmVariant,
      onPressed: onConfirm,
      busy: busy,
      expand: expand,
    );

    if (!expand) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          if (onCancel != null) ...<Widget>[
            cancel,
            const SizedBox(width: AppSpacing.sm),
          ],
          confirm,
        ],
      );
    }

    return Row(
      children: <Widget>[
        if (onCancel != null) ...<Widget>[
          Expanded(child: cancel),
          const SizedBox(width: AppSpacing.sm),
        ],
        Expanded(child: confirm),
      ],
    );
  }
}
