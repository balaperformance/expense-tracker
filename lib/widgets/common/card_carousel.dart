import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_motion.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import 'surface_card.dart';

/// One page of a [CardCarousel].
class CarouselPage {
  const CarouselPage({
    required this.title,
    required this.child,
    this.caption,
  });

  /// Shown in the header, which changes as the carousel moves. Each page owns
  /// its own title rather than the group having one, because "Where it went"
  /// and "Monthly spending" are different questions, not two views of one.
  final String title;

  /// Quiet text on the right of the header — a total, a month.
  final String? caption;

  final Widget child;
}

/// A horizontal pager for cards that answer related questions.
///
/// Exists so two chart cards can occupy one card's worth of vertical space.
/// Stacking them cost around 500px on a 780px screen, which is most of a
/// phone spent on two charts the user looks at occasionally.
///
/// Auto-advance is a convenience, never a hijack:
///
///  * a manual swipe cancels the timer and restarts it from zero, so the
///    carousel never yanks the page out from under a finger that has just
///    put it there;
///  * it stops entirely while the tab is not visible, via [TickerMode], so a
///    dashboard sitting behind the Settings tab is not animating;
///  * it does not run at all when the platform asks for reduced motion,
///    because unsolicited movement is exactly what that setting is about.
class CardCarousel extends StatefulWidget {
  const CardCarousel({
    super.key,
    required this.pages,
    required this.height,
    this.interval = const Duration(seconds: 10),
  });

  final List<CarouselPage> pages;

  /// Viewport height. A `PageView` needs a bounded height, and letting each
  /// page set its own would make the surrounding list jump as the page
  /// changes — so the tallest page decides and the caller states it.
  final double height;

  final Duration interval;

  @override
  State<CardCarousel> createState() => _CardCarouselState();
}

class _CardCarouselState extends State<CardCarousel> {
  final PageController _controller = PageController();
  Timer? _timer;
  int _index = 0;

  /// True while the user has a finger on the pager.
  bool _dragging = false;

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTimer();
  }

  @override
  void didUpdateWidget(CardCarousel old) {
    super.didUpdateWidget(old);
    if (old.pages.length != widget.pages.length) _syncTimer();
  }

  /// Starts or stops the timer to match the current conditions.
  void _syncTimer() {
    final bool wanted = widget.pages.length > 1 &&
        TickerMode.of(context) &&
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

    if (!wanted) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _restart();
  }

  void _restart() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.interval, (_) => _advance());
  }

  void _advance() {
    if (!mounted || _dragging || !_controller.hasClients) return;
    if (!TickerMode.of(context)) return;

    final int next = (_index + 1) % widget.pages.length;
    _controller.animateToPage(
      next,
      duration: AppMotion.slow,
      curve: AppMotion.standard,
    );
  }

  /// Watches the pager's own scroll activity to tell a swipe from a tick.
  ///
  /// `onPageChanged` cannot make this distinction — it fires identically for
  /// both — and the drag details on the start notification can.
  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;

    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _dragging = true;
      _timer?.cancel();
    } else if (notification is ScrollEndNotification && _dragging) {
      _dragging = false;
      // Restarted rather than resumed, so the page the user chose gets a
      // full interval before anything moves again.
      _syncTimer();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pages.isEmpty) return const SizedBox.shrink();

    final CarouselPage current = widget.pages[_index];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xs,
            0,
            AppSpacing.xs,
            AppSpacing.xs + 2,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: AppSwap(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    current.title,
                    key: ValueKey<String>(current.title),
                    style: AppTypography.section(Theme.of(context).textTheme),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (current.caption != null) ...<Widget>[
                Text(
                  current.caption!,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              _Dots(count: widget.pages.length, index: _index),
            ],
          ),
        ),
        SizedBox(
          height: widget.height,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: PageView.builder(
              controller: _controller,
              itemCount: widget.pages.length,
              onPageChanged: (int page) => setState(() => _index = page),
              itemBuilder: (BuildContext context, int page) {
                return Semantics(
                  label: '${widget.pages[page].title}, '
                      'card ${page + 1} of ${widget.pages.length}',
                  child: SurfaceCard(child: widget.pages[page].child),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// Page indicators. Small, quiet, and wide enough on the active dot to be
/// legible without becoming a progress bar.
class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < count; i++) ...<Widget>[
          if (i != 0) const SizedBox(width: AppSpacing.xs),
          AnimatedContainer(
            duration: AppMotion.fast,
            curve: AppMotion.standard,
            width: i == index ? 14 : 5,
            height: 5,
            decoration: BoxDecoration(
              color: i == index
                  ? scheme.secondary
                  : scheme.onSurfaceVariant.withOpacity(0.35),
              borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
            ),
          ),
        ],
      ],
    );
  }
}
