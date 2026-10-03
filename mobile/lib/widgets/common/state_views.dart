import 'package:flutter/material.dart';

import '../../core/theme/app_motion.dart';
import '../../core/theme/app_spacing.dart';
import 'app_buttons.dart';
import 'money_text.dart';

/// Centred spinner for a first load.
class AppLoader extends StatelessWidget {
  const AppLoader({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          if (message != null) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            Text(message!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// Placeholder block shown while real content loads.
///
/// Preferred over a bare spinner for list and card screens: keeping the page
/// shape stable while data arrives avoids the layout jump that makes an app
/// feel slower than it is.
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.height = 14,
    this.width,
    this.radius = AppSpacing.radiusXs,
  });

  final double height;
  final double? width;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color base = Theme.of(context).colorScheme.onSurface;

    final Widget bar = Container(
      height: widget.height,
      width: widget.width,
      decoration: BoxDecoration(
        color: base.withOpacity(0.09),
        borderRadius: BorderRadius.circular(widget.radius),
      ),
    );

    // The only looping animation in the app, and the one most worth turning
    // off: a pulsing placeholder is exactly what "reduce motion" is for.
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return bar;

    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 0.7).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: bar,
    );
  }
}

/// A few skeleton rows shaped like a transaction list.
class ListSkeleton extends StatelessWidget {
  const ListSkeleton({super.key, this.rows = 6});

  final int rows;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.md,
        AppSpacing.page,
        AppSpacing.page,
      ),
      itemCount: rows,
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (BuildContext context, int index) {
        return Row(
          children: <Widget>[
            const Skeleton(
              height: AppSpacing.avatar,
              width: AppSpacing.avatar,
              radius: AppSpacing.radiusMd,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Skeleton(width: index.isEven ? 150 : 110),
                  const SizedBox(height: AppSpacing.sm),
                  const Skeleton(height: 10, width: 80),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            const Skeleton(height: 14, width: 62),
          ],
        );
      },
    );
  }
}

/// Zero-data state with an optional primary action.
///
/// The icon sits in a small medallion rather than an illustration: it marks
/// the state warmly, in the brand tone, without turning an ordinary empty list
/// into an event — and it costs no image asset.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color tone = theme.colorScheme.primary;

    return Center(
      // An empty state is the one screen a user may worry is a failure, so it
      // arrives rather than appearing — which reads as "we looked" instead of
      // "something is missing".
      child: AppFadeIn(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.xxl,
            vertical: compact ? AppSpacing.lg : AppSpacing.xxl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              StateMedallion(icon: icon, tone: tone, compact: compact),
              SizedBox(height: compact ? AppSpacing.sm : AppSpacing.md),
              Text(
                title,
                style: compact
                    ? theme.textTheme.titleMedium
                    : theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                message,
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              if (actionLabel != null && onAction != null) ...<Widget>[
                SizedBox(height: compact ? AppSpacing.md : AppSpacing.lg),
                AppButton(
                  label: actionLabel!,
                  size: compact
                      ? AppButtonSize.small
                      : AppButtonSize.medium,
                  onPressed: onAction,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The icon badge shared by the empty and error states: a hairline ring
/// around a tinted disc, both in the state's tone.
class StateMedallion extends StatelessWidget {
  const StateMedallion({
    super.key,
    required this.icon,
    required this.tone,
    this.compact = false,
  });

  final IconData icon;
  final Color tone;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final double outer = compact ? 50 : 62;
    final double inner = compact ? 38 : 46;

    return Container(
      width: outer,
      height: outer,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: tone.withOpacity(0.22)),
      ),
      child: Container(
        width: inner,
        height: inner,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: ToneColors.wash(context, tone),
        ),
        child: Icon(icon, size: compact ? 19 : 22, color: tone),
      ),
    );
  }
}

/// Error state with a retry affordance.
class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.message,
    this.onRetry,
    this.compact = false,
  });

  final String message;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color tone = theme.colorScheme.error;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            StateMedallion(
              icon: Icons.cloud_off_rounded,
              tone: tone,
              compact: compact,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Something went wrong',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              message,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                label: 'Try again',
                icon: Icons.refresh_rounded,
                variant: AppButtonVariant.secondary,
                size: compact ? AppButtonSize.small : AppButtonSize.medium,
                onPressed: onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Inline banner used inside forms, where a full-screen error would be wrong.
class InlineError extends StatelessWidget {
  const InlineError({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color tone = theme.colorScheme.error;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: ToneColors.wash(context, tone),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: tone.withOpacity(0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline_rounded, size: AppSpacing.iconSm + 1,
              color: tone),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(color: tone),
            ),
          ),
        ],
      ),
    );
  }
}

/// Wraps a centred state view so it can live inside a `RefreshIndicator`.
///
/// A plain `Center` is not scrollable, so pull-to-refresh silently stops
/// working on exactly the screens — empty and error — where the user is most
/// likely to try it.
class ScrollableCentered extends StatelessWidget {
  const ScrollableCentered({super.key, required this.child, this.topFactor});

  final Widget child;

  /// Fraction of the viewport to leave above the content. Defaults to a
  /// value that reads as optically centred once the nav bar is accounted for.
  final double? topFactor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: EdgeInsets.only(
                bottom: constraints.maxHeight * (topFactor ?? 0.08),
              ),
              child: Center(child: child),
            ),
          ),
        );
      },
    );
  }
}
