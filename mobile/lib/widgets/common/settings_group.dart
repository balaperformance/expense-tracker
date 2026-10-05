import 'package:flutter/material.dart';

import '../../core/theme/app_glass.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

/// A Settings section that folds away — the web app's `SettingsGroup`.
///
/// The heading is the toggle: the serif section title, one line saying what
/// is inside (so a folded screen still reads as a table of contents), and a
/// chevron that turns over as the section opens. The whole row is the tap
/// target, never less than 48px tall.
///
/// The group owns its own open state and animation, so folding one section
/// rebuilds that section and nothing else; [onOpenChanged] is how the screen
/// remembers it (see `SettingsProvider.setSectionOpen`). [initiallyOpen] is
/// read once, when the group is first built.
///
/// A folded section's content is not built at all — it is neither painted
/// nor announced, the counterpart of the web's `inert` panel. Under the
/// platform's reduce-motion setting it opens and closes in one step.
class SettingsGroup extends StatefulWidget {
  const SettingsGroup({
    super.key,
    required this.title,
    required this.child,
    this.summary,
    this.initiallyOpen = false,
    this.onOpenChanged,
  });

  final String title;

  /// The one line under the title — what is inside, or its current state.
  final String? summary;

  final Widget child;
  final bool initiallyOpen;
  final ValueChanged<bool>? onOpenChanged;

  /// Drawn size of the chevron's disc.
  static const double _chevron = 32;

  @override
  State<SettingsGroup> createState() => _SettingsGroupState();
}

class _SettingsGroupState extends State<SettingsGroup>
    with SingleTickerProviderStateMixin {
  late bool _open = widget.initiallyOpen;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.normal,
    value: _open ? 1 : 0,
  );

  late final Animation<double> _reveal = CurvedAnimation(
    parent: _controller,
    curve: AppMotion.standard,
  );

  bool get _reduced => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _open = !_open);
    if (_reduced) {
      _controller.value = _open ? 1 : 0;
    } else if (_open) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
    widget.onOpenChanged?.call(_open);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String? summary = widget.summary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Semantics(
          button: true,
          expanded: _open,
          child: InkWell(
            onTap: _toggle,
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(minHeight: AppSpacing.minTouch),
              child: Padding(
                // The SectionHeader's inset, so a folded group lines up with
                // the plain sections (About) on the same screen.
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xs,
                  AppSpacing.xs,
                  AppSpacing.xs,
                  AppSpacing.sm,
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            widget.title,
                            style: AppTypography.section(theme.textTheme),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (summary != null) ...<Widget>[
                            const SizedBox(height: AppSpacing.xxs),
                            Text(
                              summary,
                              style: theme.textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: _reduced ? Duration.zero : AppMotion.normal,
                      curve: AppMotion.standard,
                      child: Container(
                        width: SettingsGroup._chevron,
                        height: SettingsGroup._chevron,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppGlass.of(context).fill,
                          border: Border.all(color: scheme.outline, width: 0.75),
                        ),
                        child: Icon(
                          Icons.expand_more_rounded,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedBuilder(
          animation: _reveal,
          builder: (BuildContext context, Widget? child) {
            if (_controller.isDismissed) return const SizedBox.shrink();
            return ClipRect(
              // Clipped only while it moves: once open, the cards' shadows
              // must be free to fall outside the panel.
              clipBehavior:
                  _controller.isCompleted ? Clip.none : Clip.hardEdge,
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: _reveal.value,
                child: child,
              ),
            );
          },
          child: widget.child,
        ),
      ],
    );
  }
}
