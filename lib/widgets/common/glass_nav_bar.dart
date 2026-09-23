import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
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
/// A single deep-olive bar inset from the screen edges, in both themes. The
/// active destination is a cream circle that slides between slots, holding a
/// deep-olive icon and a small dot (7.5:1). Idle icons are beige (5.4:1).
/// Icons only — the labels survive as tooltips and semantics.
///
/// **No blur, no see-through.** A blur costs a full-screen read-back on every
/// scrolled frame, and without one a translucent bar lets rows ghost through
/// it. The bar is opaque deep olive, with the lit top edge and floating shadow
/// carrying the glass read.
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
          opaque: true,
          elevated: false,
          color: AppColors.navBar,
          borderColor: AppColors.cream.withOpacity(0.10),
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
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          // Cream on deep olive: the one bright spot in the
                          // bar, so the active tab is found at a glance.
                          color: AppColors.cream,
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
    // The bar is deep olive in both themes, so its ink is fixed rather than
    // taken from the page's scheme.
    final Color tone = selected ? AppColors.deepOlive : AppColors.beige;

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
          splashColor: AppColors.cream.withOpacity(0.12),
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
                  decoration: const BoxDecoration(
                    color: AppColors.deepOlive,
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
