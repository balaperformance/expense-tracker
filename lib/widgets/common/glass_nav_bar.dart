import 'package:flutter/material.dart';

import '../../core/theme/app_glass.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_spacing.dart';

/// One destination in [GlassNavBar].
class GlassNavItem {
  const GlassNavItem({
    required this.label,
    required this.icon,
    IconData? activeIcon,
  }) : activeIcon = activeIcon ?? icon;

  /// Never painted. The bar is icon-only by design, so this is what the
  /// tooltip and the screen reader announce — dropping it would make the
  /// navigation unusable without sight, which no amount of polish excuses.
  final String label;

  final IconData icon;
  final IconData activeIcon;
}

/// The app's bottom navigation: a floating glass pill.
///
/// A single rounded bar inset from the screen edges. The active destination
/// is marked by a soft circular highlight that slides between slots, with a
/// small dot under its icon. Icons only — the labels survive as tooltips and
/// semantics.
///
/// **No blur.** The bar is 97% opaque so its icons stay legible over any
/// content, and a backdrop blur behind a fill that opaque is invisible while
/// still costing a full-screen read-back on every scrolled frame. The glass
/// read comes from the warm fill, the lit top edge and the floating shadow.
class GlassNavBar extends StatelessWidget {
  const GlassNavBar({
    super.key,
    required this.items,
    required this.index,
    required this.onSelected,
  });

  final List<GlassNavItem> items;
  final int index;
  final ValueChanged<int> onSelected;

  /// Painted height of the pill. With no labels to stack, one row of icons
  /// is all it has to hold.
  static const double _height = 52;

  /// Inset from the screen edges, which is what makes it read as floating
  /// rather than as a docked bar.
  static const double _sideInset = AppSpacing.xxl;

  /// The moving highlight behind the active icon: a circle, not a pill.
  static const double _highlight = 42;

  static const double _iconSize = 21;
  static const double _dot = 4;

  @override
  Widget build(BuildContext context) {
    final GlassTokens glass = AppGlass.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double safeBottom = MediaQuery.paddingOf(context).bottom;

    return Padding(
      // Clears the gesture bar on iOS and Android gesture navigation, and
      // still floats clear of the edge on a device with hardware keys.
      padding: EdgeInsets.fromLTRB(
        _sideInset,
        0,
        _sideInset,
        safeBottom > 0 ? safeBottom * 0.5 + AppSpacing.xs : AppSpacing.sm,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_height / 2),
          boxShadow: glass.shadowStrong,
        ),
        child: GlassSurface(
          strong: true,
          elevated: false,
          radius: _height / 2,
          child: SizedBox(
            height: _height,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double slot = constraints.maxWidth / items.length;
                final double size = slot - AppSpacing.xs < _highlight
                    ? slot - AppSpacing.xs
                    : _highlight;

                return Stack(
                  children: <Widget>[
                    AnimatedPositioned(
                      duration: AppMotion.normal,
                      curve: AppMotion.standard,
                      left: slot * index + (slot - size) / 2,
                      top: (_height - size) / 2,
                      width: size,
                      height: size,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          // The same wash a selected chip uses, so selection
                          // reads the same everywhere in the app.
                          color: scheme.primary.withOpacity(
                            glass.isDark ? 0.18 : 0.12,
                          ),
                        ),
                      ),
                    ),
                    Row(
                      children: <Widget>[
                        for (int i = 0; i < items.length; i++)
                          Expanded(
                            child: _NavSlot(
                              item: items[i],
                              selected: i == index,
                              onTap: () => onSelected(i),
                            ),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _NavSlot extends StatelessWidget {
  const _NavSlot({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final GlassNavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color tone = selected ? scheme.primary : scheme.onSurfaceVariant;

    return Semantics(
      label: item.label,
      button: true,
      selected: selected,
      child: Tooltip(
        message: item.label,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          // Kept subtle: the sliding highlight is the selection feedback, and
          // a bright splash over it reads as a flash.
          splashColor: scheme.primary.withOpacity(0.10),
          highlightColor: Colors.transparent,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              AnimatedSwitcher(
                duration: AppMotion.fast,
                child: Icon(
                  selected ? item.activeIcon : item.icon,
                  key: ValueKey<bool>(selected),
                  size: GlassNavBar._iconSize,
                  color: tone,
                ),
              ),
              const SizedBox(height: 3),
              // Space is reserved for the dot on every slot, so the icons do
              // not jump vertically as the selection moves.
              AnimatedOpacity(
                duration: AppMotion.fast,
                opacity: selected ? 1 : 0,
                child: Container(
                  width: GlassNavBar._dot,
                  height: GlassNavBar._dot,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
