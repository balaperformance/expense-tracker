import 'package:flutter/material.dart';

import '../../core/theme/app_glass.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import 'money_text.dart';

/// The single card surface used across the app.
///
/// One glass pane: translucent fill, a hairline that is lit along the top
/// edge, and a soft shadow. Every card in the app is this, so the material
/// reads as one system and retuning it is a one-file change.
///
/// [blur] is off by default and should stay that way for cards in a list —
/// see the rationing note in `app_glass.dart`. Turn it on for the one hero
/// surface on a screen, where content genuinely passes behind it.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.cardPad),
    this.onTap,
    this.tone,
    this.blur = 0,
    this.radius = AppSpacing.radiusLg,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  /// Tints the card for a state that needs attention (over budget, error).
  /// Left null for the overwhelming majority of cards.
  final Color? tone;

  /// Backdrop blur sigma. Zero paints no `BackdropFilter` at all.
  final double blur;

  final double radius;

  @override
  Widget build(BuildContext context) {
    // The ripple is the only tap handler. An outer scale-on-press gesture
    // would sit in the same hit-test path as this InkWell and fire `onTap`
    // twice — which, on a card that opens a form, means two forms.
    return GlassSurface(
      radius: radius,
      blur: blur,
      tone: tone,
      padding: onTap == null ? padding : EdgeInsets.zero,
      child: onTap == null
          ? child
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(radius),
              child: Padding(padding: padding, child: child),
            ),
    );
  }
}

/// Card whose children are rows separated by dividers.
///
/// Padding is zero so each row controls its own height, and the divider is
/// indented to the text column rather than cutting under the leading avatar.
class CardList extends StatelessWidget {
  const CardList({
    super.key,
    required this.children,
    this.dividerIndent = AppSpacing.rowDividerIndent,
    this.onTap,
  });

  final List<Widget> children;
  final double dividerIndent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();

    return SurfaceCard(
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < children.length; i++) ...<Widget>[
            children[i],
            if (i != children.length - 1)
              Divider(height: 1, indent: dividerIndent),
          ],
        ],
      ),
    );
  }
}

/// Heading above a group, with an optional trailing action or caption.
///
/// Set in the display serif at a modest size: it structures the page without
/// competing with the figures underneath, which are what the user scans.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
    this.caption,
    this.padding = const EdgeInsets.fromLTRB(
      AppSpacing.xs,
      0,
      AppSpacing.xs,
      AppSpacing.xs + 2,
    ),
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Quiet text on the right when there is no action — a count or total.
  final String? caption;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              // Serif, like a chapter heading: the section reads as part of
              // the page's composition rather than as one more label, and
              // the figures underneath stay the loudest thing on screen.
              style: AppTypography.section(theme.textTheme),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              child: Text(actionLabel!),
            )
          else if (caption != null)
            Text(caption!, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

/// One tappable row inside a [CardList].
///
/// Deliberately tighter than `ListTile`, which reserves far more vertical
/// space than a finance list can afford, while still clearing the 48px
/// minimum touch target.
class AppListRow extends StatelessWidget {
  const AppListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.tone,
    this.showChevron = false,
    this.dense = false,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Colours the title and leading icon — used for destructive rows.
  final Color? tone;
  final bool showChevron;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSpacing.minTouch),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: dense ? AppSpacing.xs + 2 : AppSpacing.rowPadY,
          ),
          child: Row(
            children: <Widget>[
              if (leading != null) ...<Widget>[
                leading!,
                const SizedBox(width: AppSpacing.md),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(color: tone),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle != null) ...<Widget>[
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              // Flexible so a wide trailing widget — typically a balance —
              // takes space from the title instead of overflowing the row.
              if (trailing != null) ...<Widget>[
                const SizedBox(width: AppSpacing.sm),
                Flexible(child: trailing!),
              ],
              if (showChevron) ...<Widget>[
                const SizedBox(width: AppSpacing.xs),
                Icon(
                  Icons.chevron_right_rounded,
                  size: AppSpacing.iconMd,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Square tinted well holding an icon. The standard leading element.
class IconWell extends StatelessWidget {
  const IconWell({
    super.key,
    required this.icon,
    required this.tone,
    this.size = AppSpacing.avatar,
  });

  final IconData icon;
  final Color tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: ToneColors.wash(context, tone),
        borderRadius: BorderRadius.circular(size * 0.29),
      ),
      child: Icon(icon, size: size * 0.46, color: tone),
    );
  }
}

/// Small pill used for statuses and counts — "Cash", "3 filters", "Over".
class AppBadge extends StatelessWidget {
  const AppBadge({
    super.key,
    required this.label,
    this.tone,
    this.icon,
  });

  final String label;
  final Color? tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color colour = tone ?? theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: ToneColors.wash(context, colour),
        borderRadius: BorderRadius.circular(AppSpacing.radiusXs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 11, color: colour),
            const SizedBox(width: AppSpacing.xs),
          ],
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: colour,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Quiet inline explanation — a migration hint, a caveat, a tip.
///
/// Neutral by default so it informs without competing with the content, and
/// never styled as an error unless a [tone] says so.
class AppNotice extends StatelessWidget {
  const AppNotice({
    super.key,
    required this.message,
    this.icon = Icons.info_outline_rounded,
    this.tone,
    this.action,
  });

  final String message;
  final IconData icon;
  final Color? tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color colour = tone ?? theme.colorScheme.onSurfaceVariant;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm + 2,
        vertical: AppSpacing.sm + 1,
      ),
      decoration: BoxDecoration(
        color: ToneColors.wash(context, colour),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: colour.withOpacity(0.22), width: 0.75),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: AppSpacing.iconSm + 1, color: colour),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tone ?? theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (action != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
                  action!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
