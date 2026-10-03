/// One motion system for the whole app.
///
/// Every duration and curve in the UI comes from here, so animation reads as
/// one considered system rather than as whatever each screen happened to
/// pick. The values are deliberately short: this is a financial tool people
/// open to check a number, and motion that draws attention to itself is
/// motion that got in the way.
///
/// Three rules decide everything below.
///
///  * **Nothing here repeats.** Every animation this file defines is
///    determinate and self-terminating. The one looping animation in the app
///    is the loading skeleton's shimmer, which is bounded by the request it
///    represents; nothing else is allowed to run indefinitely, because a
///    loop costs frames for as long as it is on screen.
///  * **Nothing blocks.** Every animation is decorative; the content is laid
///    out and readable at t=0 and at t=1, so a dropped frame costs polish
///    rather than usability.
///  * **Nothing animates on scroll.** List rows appear instantly. Staggering
///    a scrolling list is the single most common way a "premium" redesign
///    ends up feeling slower than the thing it replaced.
library;

import 'package:flutter/material.dart';

class AppMotion {
  const AppMotion._();

  // ---------------------------------------------------------------------
  // Durations
  // ---------------------------------------------------------------------

  /// Pressed/hover feedback. Must land inside the same gesture, so it is
  /// shorter than anything else here.
  static const Duration instant = Duration(milliseconds: 90);

  /// A control changing state — chip selected, icon swapped, colour moved.
  static const Duration fast = Duration(milliseconds: 160);

  /// The default. Content appearing, a card settling, a value counting.
  static const Duration normal = Duration(milliseconds: 240);

  /// Larger surfaces: a sheet, an expanding panel.
  static const Duration slow = Duration(milliseconds: 320);

  /// A figure counting to a new value. Longer than [normal] because the eye
  /// is reading digits rather than watching a shape move.
  static const Duration figure = Duration(milliseconds: 420);

  // ---------------------------------------------------------------------
  // Curves
  // ---------------------------------------------------------------------

  /// Default easing. Decelerating, so a thing arrives gently and leaves
  /// promptly — the iOS feel, without importing anything.
  static const Curve standard = Curves.easeOutCubic;

  /// For something entering from off screen or from nothing.
  static const Curve enter = Curves.easeOutQuart;

  /// For something leaving. Faster out than in, so dismissal feels obedient.
  static const Curve exit = Curves.easeInCubic;

  /// Pressed-state scale. Symmetric, because the finger controls both ends.
  static const Curve press = Curves.easeOut;

  /// How far a button shrinks when pressed. Small enough to read as physical
  /// rather than as a bounce.
  static const double pressScale = 0.97;
}

/// Fades and lifts its child in once, on first build.
///
/// Used for page-level content and section blocks — never for the rows of a
/// scrolling list, where it would re-run on every recycle and turn a smooth
/// scroll into a slideshow.
///
/// [delay] staggers a small group. Keep groups under about six: beyond that
/// the last item arrives late enough to feel like lag rather than polish.
class AppFadeIn extends StatefulWidget {
  const AppFadeIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = AppMotion.normal,
    this.offset = 8,
  });

  final Widget child;
  final Duration delay;
  final Duration duration;

  /// Vertical travel in logical pixels. Deliberately tiny — the eye reads
  /// this as the content settling, not as it flying in.
  final double offset;

  @override
  State<AppFadeIn> createState() => _AppFadeInState();
}

class _AppFadeInState extends State<AppFadeIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      Future<void>.delayed(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Respects the platform "reduce motion" setting: the content still
    // appears, it just stops travelling.
    final bool reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduced) return widget.child;

    final Animation<double> eased = CurvedAnimation(
      parent: _controller,
      curve: AppMotion.enter,
    );

    return FadeTransition(
      opacity: eased,
      child: AnimatedBuilder(
        animation: eased,
        builder: (BuildContext context, Widget? child) => Transform.translate(
          offset: Offset(0, widget.offset * (1 - eased.value)),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

/// Scales its child down slightly while a finger is on it.
///
/// Deliberately **observe-only**. It listens to raw pointer events rather than
/// recognising a tap, so it never enters the gesture arena and cannot compete
/// with — or double up on — the button or ink well inside it. Wrapping a
/// control that already has an `onTap` is therefore safe: the inner control
/// still owns the tap, and this only animates.
///
/// [enabled] is false for a disabled control, which must not appear to
/// respond to a press it is going to ignore.
class AppPressEffect extends StatefulWidget {
  const AppPressEffect({
    super.key,
    required this.child,
    this.enabled = true,
    this.scale = AppMotion.pressScale,
  });

  final Widget child;
  final bool enabled;
  final double scale;

  @override
  State<AppPressEffect> createState() => _AppPressEffectState();
}

class _AppPressEffectState extends State<AppPressEffect> {
  bool _down = false;

  void _set(bool value) {
    if (_down != value && mounted) setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    final bool reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduced) return widget.child;

    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: AppMotion.instant,
        curve: AppMotion.press,
        child: widget.child,
      ),
    );
  }
}

/// Cross-fades between states without the layout jumping.
///
/// Used wherever a screen swaps a skeleton for content, or an empty state for
/// a list: the swap is the moment the user is most likely to think something
/// broke, and a 160ms fade reads as "arrived" rather than "flashed".
class AppSwap extends StatelessWidget {
  const AppSwap({super.key, required this.child, this.alignment = Alignment.topCenter});

  final Widget child;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppMotion.fast,
      switchInCurve: AppMotion.standard,
      switchOutCurve: AppMotion.exit,
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        alignment: alignment,
        children: <Widget>[...previous, if (current != null) current],
      ),
      child: child,
    );
  }
}

/// Page transition that matches iOS on both platforms.
///
/// Deliberately identical on Android rather than using the platform's own
/// vertical/fade transition. Every push in this app is a drill-down —
/// dashboard to statement, list to form — and a horizontal slide is what
/// makes "back" feel like going back. Android's predictive-back gesture still
/// works; only the visual differs.
class AppPageTransitions extends PageTransitionsTheme {
  const AppPageTransitions()
      : super(
          builders: const <TargetPlatform, PageTransitionsBuilder>{
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
            TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
            TargetPlatform.fuchsia: FadeUpwardsPageTransitionsBuilder(),
          },
        );
}
