/// Tests for the global design system: glass surfaces, density and motion.
///
/// These exist because the redesign's whole premise is that appearance is
/// decided centrally. If a screen can quietly drift away from the scale, or a
/// press animation can start eating taps, the premise is false — so the
/// things that would make it false are measured here rather than eyeballed
/// on one screen.
///
/// Density is asserted as *relationships and floors*, never as absolute
/// pixel values of text: `flutter_test` substitutes a font whose every glyph
/// is one em wide, so any assertion that depends on text measuring like
/// Roboto is meaningless here.
library;

import 'package:expense_tracker/core/theme/app_glass.dart';
import 'package:expense_tracker/core/theme/app_motion.dart';
import 'package:expense_tracker/core/theme/app_spacing.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/widgets/common/app_buttons.dart';
import 'package:expense_tracker/widgets/common/money_text.dart';
import 'package:expense_tracker/widgets/common/surface_card.dart';
import 'package:expense_tracker/widgets/transaction_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const List<double> _widths = <double>[320, 360, 411];

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 360,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = Size(width * 3, 800 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.page),
            child: child,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // ---------------------------------------------------------------------
  // Glass
  // ---------------------------------------------------------------------
  group('glass tokens', () {
    test('every surface fill is genuinely translucent', () {
      for (final GlassTokens glass in <GlassTokens>[
        AppGlass.light,
        AppGlass.dark,
      ]) {
        // An opaque fill would make the whole thing a flat panel with a
        // border, which is the failure mode this design is trying to avoid.
        expect(glass.fill.alpha, lessThan(255));
        expect(glass.fillStrong.alpha, lessThan(255));
      }
    });

    test('a bar fill is more opaque than a card fill', () {
      // Text sits on a bar over arbitrary moving content; a card only ever
      // sits on the page background.
      for (final GlassTokens glass in <GlassTokens>[
        AppGlass.light,
        AppGlass.dark,
      ]) {
        expect(glass.fillStrong.alpha, greaterThan(glass.fill.alpha));
      }
    });

    test('the top edge is lit brighter than the outline', () {
      // This single asymmetry is what reads as a lit pane rather than a flat
      // rectangle. If the two ever equalise, the glass look is gone.
      for (final GlassTokens glass in <GlassTokens>[
        AppGlass.light,
        AppGlass.dark,
      ]) {
        expect(glass.borderTop.alpha, greaterThan(glass.borderBottom.alpha));
      }
    });

    test('dark glass is lighter than the page it sits on', () {
      // A translucent black over a near-black page produces no surface at
      // all, which is the classic way dark-mode "glass" disappears.
      final HSLColor fill = HSLColor.fromColor(
        Color.alphaBlend(AppGlass.dark.fill, AppTheme.dark.scaffoldBackgroundColor),
      );
      final HSLColor page =
          HSLColor.fromColor(AppTheme.dark.scaffoldBackgroundColor);
      expect(fill.lightness, greaterThan(page.lightness));
    });

    test('blur sigmas are set where blur is spent', () {
      expect(AppGlass.blurBar, greaterThan(0));
      expect(AppGlass.blurOverlay, greaterThan(AppGlass.blurBar));
      expect(AppGlass.blurCard, greaterThan(0));
    });

    testWidgets('a card paints no BackdropFilter by default',
        (WidgetTester tester) async {
      // Blur is rationed: a list of blurred cards is the single easiest way
      // to drop frames on mid-range Android.
      await _pump(tester, const SurfaceCard(child: Text('x')));
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('a card blurs when it is explicitly asked to',
        (WidgetTester tester) async {
      await _pump(
        tester,
        const SurfaceCard(blur: AppGlass.blurCard, child: Text('x')),
      );
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('glass surfaces render at every width in both themes',
        (WidgetTester tester) async {
      for (final Brightness brightness in Brightness.values) {
        for (final double width in _widths) {
          await _pump(
            tester,
            const Column(
              children: <Widget>[
                SurfaceCard(child: Text('plain')),
                SizedBox(height: AppSpacing.cardGap),
                SurfaceCard(blur: 12, child: Text('blurred')),
                SizedBox(height: AppSpacing.cardGap),
                GlassSurface(
                  padding: EdgeInsets.all(AppSpacing.cardPad),
                  child: Text('bare surface'),
                ),
              ],
            ),
            width: width,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull, reason: '$width $brightness');
        }
      }
    });
  });

  // ---------------------------------------------------------------------
  // Density
  // ---------------------------------------------------------------------
  group('density', () {
    test('the page and section rhythm is tight', () {
      expect(AppSpacing.page, lessThanOrEqualTo(16));
      // The old value was 22, and a dashboard of eight sections spent 176px
      // — over a fifth of a phone screen — on gaps alone.
      expect(AppSpacing.section, lessThanOrEqualTo(16));
      expect(AppSpacing.cardPad, lessThanOrEqualTo(14));
      expect(AppSpacing.cardGap, lessThanOrEqualTo(12));
    });

    test('buttons are drawn compact but stay ordered', () {
      expect(AppSpacing.buttonHeightSm, lessThan(AppSpacing.buttonHeight));
      expect(AppSpacing.buttonHeight, lessThan(AppSpacing.buttonHeightLg));
      // Every size is drawn below the touch floor and padded back up to it.
      expect(AppSpacing.buttonHeightLg, lessThan(AppSpacing.minTouch));
      expect(AppSpacing.fabHeight, lessThan(AppSpacing.minTouch));
    });

    test('text sizes were not sacrificed for density', () {
      final TextTheme t = AppTheme.light.textTheme;
      // Density is bought from padding. The moment it starts coming out of
      // type size, the app is just smaller rather than denser.
      expect(t.bodyMedium!.fontSize!, greaterThanOrEqualTo(13));
      expect(t.bodySmall!.fontSize!, greaterThanOrEqualTo(12));
      expect(t.titleMedium!.fontSize!, greaterThanOrEqualTo(14));
      expect(t.labelSmall!.fontSize!, greaterThanOrEqualTo(11));
    });

    testWidgets('a transaction row is compact but still hittable',
        (WidgetTester tester) async {
      await _pump(
        tester,
        const TransactionRow(
          leading: SizedBox(width: AppSpacing.avatar, height: AppSpacing.avatar),
          title: 'Green Leaf Supermarket',
          amount: -450,
          currency: 'INR',
          tone: AmountTone.negative,
          meta: <String>['Food', 'Salary Account'],
        ),
      );

      final double height = tester.getSize(find.byType(TransactionRow)).height;
      expect(height, greaterThanOrEqualTo(AppSpacing.minTouch),
          reason: 'a row must never fall below the touch floor');
      expect(height, lessThanOrEqualTo(62),
          reason: 'two lines of text plus 9px padding, not 16');
    });

    testWidgets('a list row keeps its full touch target',
        (WidgetTester tester) async {
      await _pump(
        tester,
        const CardList(
          children: <Widget>[
            AppListRow(title: 'One', subtitle: 'sub'),
            AppListRow(title: 'Two'),
          ],
        ),
      );

      for (final Element element
          in find.byType(AppListRow).evaluate().toList()) {
        expect(
          tester.getSize(find.byWidget(element.widget)).height,
          greaterThanOrEqualTo(AppSpacing.minTouch),
        );
      }
    });
  });

  // ---------------------------------------------------------------------
  // Motion
  // ---------------------------------------------------------------------
  group('motion', () {
    test('every duration is short enough to stay out of the way', () {
      for (final Duration d in <Duration>[
        AppMotion.instant,
        AppMotion.fast,
        AppMotion.normal,
        AppMotion.slow,
        AppMotion.figure,
      ]) {
        expect(d.inMilliseconds, lessThanOrEqualTo(450), reason: '$d');
        expect(d.inMilliseconds, greaterThan(0));
      }
    });

    testWidgets('AppFadeIn settles fully visible', (WidgetTester tester) async {
      await _pump(tester, const AppFadeIn(child: Text('arrived')));

      expect(find.text('arrived'), findsOneWidget);
      final FadeTransition fade =
          tester.widget<FadeTransition>(find.byType(FadeTransition).first);
      expect(fade.opacity.value, 1.0,
          reason: 'content must never be left partly transparent');
    });

    testWidgets('the press effect never swallows a tap',
        (WidgetTester tester) async {
      // The regression this guards: an outer gesture recogniser wrapping a
      // button competes for the same tap. Done wrong it either steals the
      // press or fires it twice — and a card that opens a form would open
      // two. AppPressEffect only listens to pointers, so the count is one.
      int taps = 0;
      await _pump(
        tester,
        AppButton(label: 'Add expense', onPressed: () => taps++),
      );

      await tester.tap(find.text('Add expense'));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('a tappable card fires exactly once',
        (WidgetTester tester) async {
      int taps = 0;
      await _pump(
        tester,
        SurfaceCard(onTap: () => taps++, child: const Text('open')),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('reduced motion removes the entrance travel',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: const MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(body: AppFadeIn(child: Text('static'))),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('static'), findsOneWidget);
      expect(find.byType(FadeTransition), findsNothing,
          reason: 'the platform asked for no animation');
    });

    test('back is a horizontal slide on every mobile platform', () {
      final PageTransitionsTheme transitions =
          AppTheme.light.pageTransitionsTheme;
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        expect(
          transitions.builders[platform],
          isA<CupertinoPageTransitionsBuilder>(),
          reason: '$platform',
        );
      }
    });
  });

  // ---------------------------------------------------------------------
  // The theme must not paint surfaces the glass is responsible for
  // ---------------------------------------------------------------------
  group('theme defers to the glass layer', () {
    test('sheets and navigation paint nothing of their own', () {
      for (final ThemeData theme in <ThemeData>[AppTheme.light, AppTheme.dark]) {
        // A surface here would sit *behind* the blurred pane and cancel the
        // blur, which is exactly how a "glass" sheet ends up looking flat.
        expect(theme.bottomSheetTheme.backgroundColor, Colors.transparent);
        expect(theme.bottomSheetTheme.modalBackgroundColor, Colors.transparent);
        expect(theme.navigationBarTheme.backgroundColor, Colors.transparent);
        expect(theme.bottomSheetTheme.showDragHandle, isFalse,
            reason: 'the handle is drawn on the glass, not under it');
      }
    });

    test('cards carry a translucent fill and a hairline', () {
      for (final ThemeData theme in <ThemeData>[AppTheme.light, AppTheme.dark]) {
        expect(theme.cardTheme.color!.alpha, lessThan(255));
        expect(theme.cardTheme.elevation, 0);
        final RoundedRectangleBorder shape =
            theme.cardTheme.shape! as RoundedRectangleBorder;
        expect(shape.side.width, lessThan(1.0), reason: 'hairline, not a rule');
      }
    });
  });
}
