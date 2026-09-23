import 'dart:ui';

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
/// A single rounded bar inset from the screen edges, blurred so the page
/// shows through it, with the active destination marked by a lighter pill
/// that slides between slots. Icons only — the labels survive as tooltips
/// and semantics.
///
/// The surface is the app's own glass, so the bar reads as the same material
/// as every card behind it rather than as a coloured object dropped on top.
/// Selection is the same primary tint a selected chip uses, which keeps the
/// accent to the one active icon instead of the whole bar.
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

  /// The moving highlight behind the active icon.
  static const double _pillMaxWidth = 50;
  static const double _pillHeight = 38;

  static const double _iconSize = 22;

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
          boxShadow: glass.shadow,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_height / 2),
          child: BackdropFilter(
            // One blurred surface for the whole bar. Content scrolls under it
            // on every tab, so this is blur that visibly earns its cost.
            filter: ImageFilter.blur(
              sigmaX: AppGlass.blurBar,
              sigmaY: AppGlass.blurBar,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                // The app's own glass, not a colour of its own: the bar now
                // belongs to the page it floats over instead of importing a
                // purple that appeared nowhere else on the screen.
                color: glass.fillStrong,
                borderRadius: BorderRadius.circular(_height / 2),
                border: Border.all(color: glass.borderBottom, width: 0.75),
              ),
              child: SizedBox(
                height: _height,
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final double slot = constraints.maxWidth / items.length;
                    final double pillWidth =
                        slot - AppSpacing.sm < _pillMaxWidth
                            ? slot - AppSpacing.sm
                            : _pillMaxWidth;

                    return Stack(
                      children: <Widget>[
                        AnimatedPositioned(
                          duration: AppMotion.normal,
                          curve: AppMotion.standard,
                          left: slot * index + (slot - pillWidth) / 2,
                          top: (_height - _pillHeight) / 2,
                          width: pillWidth,
                          height: _pillHeight,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              // The same tint a selected chip uses, so
                              // selection reads the same everywhere.
                              color: scheme.primary.withOpacity(
                                glass.isDark ? 0.20 : 0.11,
                              ),
                              borderRadius:
                                  BorderRadius.circular(_pillHeight / 2.2),
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

    return Semantics(
      label: item.label,
      button: true,
      selected: selected,
      child: Tooltip(
        message: item.label,
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          // Kept subtle: the sliding pill is the selection feedback, and a
          // bright splash over it reads as a flash.
          splashColor: scheme.primary.withOpacity(0.10),
          highlightColor: Colors.transparent,
          child: Center(
            child: AnimatedScale(
              duration: AppMotion.fast,
              curve: AppMotion.standard,
              scale: selected ? 1.0 : 0.92,
              child: AnimatedSwitcher(
                duration: AppMotion.fast,
                child: Icon(
                  selected ? item.activeIcon : item.icon,
                  key: ValueKey<bool>(selected),
                  size: GlassNavBar._iconSize,
                  color: selected
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
