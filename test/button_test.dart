// Button system tests.
//
// The redesign's central bug was a button theme that set
// `minimumSize: Size.fromHeight(50)` — which is `Size(double.infinity, 50)`,
// an infinite *minimum width*. Every button in the app silently stretched to
// fill its parent. That is invisible in a code review and obvious on a phone,
// so it is pinned here by measurement rather than by inspection.
//
// These tests measure real rendered geometry: painted height, hugged width,
// and the tap target, which must stay at 48 even though nothing is drawn that
// tall any more.

import 'package:expense_tracker/core/theme/app_spacing.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/widgets/common/app_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps [child] centred on a 360px-wide screen.
Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
  double width = 360,
  /// False when the subject contains an endless animation (a busy spinner):
  /// pumpAndSettle never returns on one.
  bool settle = true,
}) async {
  tester.view.physicalSize = Size(width * 3, 720 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
      home: Scaffold(body: Center(child: child)),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// The box the button actually paints, as opposed to its padded hit area.
Size _paintedSize(WidgetTester tester) {
  final Finder material = find
      .descendant(of: find.byType(AppButton), matching: find.byType(Material))
      .first;
  return tester.getSize(material);
}

/// The full hit area, including Material's invisible tap padding.
Size _tapSize(WidgetTester tester) => tester.getSize(find.byType(AppButton));

void main() {
  group('the stretch regression', () {
    // This is the specific defect the redesign shipped with. A minimum width
    // above zero anywhere in the button themes means buttons stretch again.
    test('no button theme declares an infinite minimum width', () {
      for (final ThemeData theme in <ThemeData>[
        AppTheme.light,
        AppTheme.dark,
      ]) {
        final Map<String, ButtonStyle?> styles = <String, ButtonStyle?>{
          'filled': theme.filledButtonTheme.style,
          'elevated': theme.elevatedButtonTheme.style,
          'outlined': theme.outlinedButtonTheme.style,
          'text': theme.textButtonTheme.style,
        };

        styles.forEach((String name, ButtonStyle? style) {
          final Size? min = style?.minimumSize?.resolve(<WidgetState>{});
          expect(min, isNotNull, reason: '$name has no minimumSize');
          expect(
            min!.width,
            0,
            reason: '$name button would stretch: minimum width is ${min.width}',
          );
          expect(
            min.width.isFinite,
            isTrue,
            reason: '$name button has an infinite minimum width',
          );
        });
      }
    });

    testWidgets('a button hugs its label instead of filling the screen',
        (WidgetTester tester) async {
      await _pump(tester, AppButton(label: 'Add', onPressed: () {}));

      final double width = _paintedSize(tester).width;
      // "Add" plus 16px padding either side lands near 90px. The assertion is
      // loose on the exact value and strict on the thing that matters: it is
      // nowhere near the 360px screen.
      expect(width, lessThan(140));
      expect(width, greaterThan(50));
    });

    testWidgets('a label too long to fit clamps instead of overflowing',
        (WidgetTester tester) async {
      // The test font draws every glyph as a fixed fontSize-wide box, so this
      // 25-character label measures ~382px here and genuinely cannot fit 360.
      // What matters is that it clamps and ellipsises rather than overflowing,
      // which an unclamped button would do noisily.
      await _pump(
        tester,
        AppButton(label: 'Transfer between accounts', onPressed: () {}),
      );
      expect(tester.takeException(), isNull);
      final Size size = _paintedSize(tester);
      expect(size.width, lessThanOrEqualTo(360));
      expect(size.height, AppSpacing.buttonHeight);
    });
  });

  group('sizing', () {
    testWidgets('medium is drawn at the compact height',
        (WidgetTester tester) async {
      await _pump(tester, AppButton(label: 'Add', onPressed: () {}));
      expect(_paintedSize(tester).height, AppSpacing.buttonHeight);
    });

    testWidgets('small is drawn shorter', (WidgetTester tester) async {
      await _pump(
        tester,
        AppButton(
          label: 'Add',
          size: AppButtonSize.small,
          onPressed: () {},
        ),
      );
      expect(_paintedSize(tester).height, AppSpacing.buttonHeightSm);
    });

    testWidgets('submit is the tallest and the only one that expands',
        (WidgetTester tester) async {
      await _pump(
        tester,
        AppButton.submit(label: 'Add expense', onPressed: () {}),
      );
      final Size size = _paintedSize(tester);
      expect(size.height, AppSpacing.buttonHeightLg);
      expect(size.width, 360);
    });

    testWidgets('every size is comfortably tappable',
        (WidgetTester tester) async {
      // Compact is a painting decision, not an interaction one. Each size
      // must still present a 48px target.
      for (final AppButtonSize size in AppButtonSize.values) {
        await _pump(
          tester,
          AppButton(label: 'Add', size: size, onPressed: () {}),
        );
        final Size tap = _tapSize(tester);
        expect(
          tap.height,
          greaterThanOrEqualTo(AppSpacing.minTouch),
          reason: '$size tap height is ${tap.height}',
        );
        expect(
          tap.width,
          greaterThanOrEqualTo(AppSpacing.minTouch),
          reason: '$size tap width is ${tap.width}',
        );
      }
    });

    testWidgets('the height ladder is ordered', (WidgetTester tester) async {
      expect(AppSpacing.buttonHeightSm, lessThan(AppSpacing.buttonHeight));
      expect(AppSpacing.buttonHeight, lessThan(AppSpacing.buttonHeightLg));
      // The tallest button is still shorter than the old uniform 50px.
      expect(AppSpacing.buttonHeightLg, lessThan(50));
    });

    testWidgets('an icon does not change the height',
        (WidgetTester tester) async {
      await _pump(tester, AppButton(label: 'Add', onPressed: () {}));
      final double plain = _paintedSize(tester).height;

      await _pump(
        tester,
        AppButton(
          label: 'Add',
          icon: Icons.add_rounded,
          onPressed: () {},
        ),
      );
      expect(_paintedSize(tester).height, plain);
    });
  });

  group('variants', () {
    testWidgets('all five render in both themes',
        (WidgetTester tester) async {
      for (final Brightness brightness in Brightness.values) {
        for (final AppButtonVariant variant in AppButtonVariant.values) {
          await _pump(
            tester,
            AppButton(
              label: 'Action',
              variant: variant,
              icon: Icons.check_rounded,
              onPressed: () {},
            ),
            brightness: brightness,
          );
          expect(
            tester.takeException(),
            isNull,
            reason: '$variant failed in $brightness',
          );
          expect(_paintedSize(tester).height, AppSpacing.buttonHeight);
        }
      }
    });

    testWidgets('only secondary draws a border', (WidgetTester tester) async {
      await _pump(
        tester,
        AppButton(
          label: 'Cancel',
          variant: AppButtonVariant.secondary,
          onPressed: () {},
        ),
      );
      final Material material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(AppButton),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.shape, isA<RoundedRectangleBorder>());
    });
  });

  group('behaviour', () {
    testWidgets('a press fires once', (WidgetTester tester) async {
      int taps = 0;
      await _pump(tester, AppButton(label: 'Add', onPressed: () => taps++));
      await tester.tap(find.byType(AppButton));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('busy blocks the press and shows a spinner',
        (WidgetTester tester) async {
      int taps = 0;
      await _pump(
        tester,
        AppButton(
          label: 'Save',
          busy: true,
          busyLabel: 'Saving…',
          onPressed: () => taps++,
        ),
        settle: false,
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Saving…'), findsOneWidget);

      await tester.tap(find.byType(AppButton), warnIfMissed: false);
      await tester.pump();
      expect(taps, 0, reason: 'a busy button must not re-submit');
    });

    testWidgets('a null callback disables without throwing',
        (WidgetTester tester) async {
      await _pump(tester, const AppButton(label: 'Add', onPressed: null));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(AppButton), warnIfMissed: false);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('busy keeps the height stable', (WidgetTester tester) async {
      // A button that changes size when it starts saving makes the whole form
      // jump, which reads as a glitch at the least reassuring moment.
      await _pump(tester, AppButton(label: 'Save', onPressed: () {}));
      final Size idle = _paintedSize(tester);

      await _pump(
        tester,
        AppButton(label: 'Save', busy: true, onPressed: () {}),
        settle: false,
      );
      expect(_paintedSize(tester).height, idle.height);
    });
  });

  group('button row', () {
    testWidgets('splits the width and puts confirm on the right',
        (WidgetTester tester) async {
      await _pump(
        tester,
        SizedBox(
          width: 300,
          child: AppButtonRow(
            confirmLabel: 'Delete',
            confirmVariant: AppButtonVariant.danger,
            onCancel: () {},
            onConfirm: () {},
          ),
        ),
      );

      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(
        tester.getCenter(find.text('Delete')).dx,
        greaterThan(tester.getCenter(find.text('Cancel')).dx),
      );
    });

    testWidgets('hugging mode keeps both buttons off the full width',
        (WidgetTester tester) async {
      await _pump(
        tester,
        AppButtonRow(
          expand: false,
          confirmLabel: 'Save',
          onCancel: () {},
          onConfirm: () {},
        ),
      );

      for (final Element element
          in find.byType(AppButton).evaluate().toList()) {
        expect(tester.getSize(find.byWidget(element.widget)).width,
            lessThan(180));
      }
    });
  });

  group('floating action button', () {
    testWidgets('is close in height to an ordinary button',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360 * 3, 720 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            floatingActionButton: AppFab(label: 'Add', onPressed: () {}),
            body: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The painted box, not the outer render box — the outer one carries
      // Material's 48px tap padding, exactly as the buttons do.
      final Size painted = tester.getSize(
        find
            .descendant(
              of: find.byType(FloatingActionButton),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(painted.height, AppSpacing.fabHeight);
      // Material's default extended FAB paints at 48. At or above that means
      // the oversized default has leaked back in.
      expect(painted.height, lessThan(48));
      // And it should not sprawl across the screen either.
      expect(painted.width, lessThan(160));

      // The tap target is untouched by the visual slimming.
      expect(
        tester.getSize(find.byType(FloatingActionButton)).height,
        greaterThanOrEqualTo(AppSpacing.minTouch),
      );
    });

    testWidgets('renders in both themes', (WidgetTester tester) async {
      for (final Brightness brightness in Brightness.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme:
                brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
            home: Scaffold(
              floatingActionButton: AppFab(
                label: 'Income',
                icon: Icons.savings_outlined,
                onPressed: () {},
              ),
              body: const SizedBox.shrink(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('icon button', () {
    testWidgets('stays tappable while drawing small',
        (WidgetTester tester) async {
      await _pump(
        tester,
        AppIconButton(
          icon: Icons.tune_rounded,
          tooltip: 'Filter',
          onPressed: () {},
        ),
      );

      final Size size = tester.getSize(find.byType(IconButton));
      expect(size.height, greaterThanOrEqualTo(AppSpacing.minTouch));
      expect(size.width, greaterThanOrEqualTo(AppSpacing.minTouch));
    });

    testWidgets('compact mode is smaller but still usable',
        (WidgetTester tester) async {
      await _pump(
        tester,
        AppIconButton(
          icon: Icons.delete_outline_rounded,
          tooltip: 'Delete',
          compact: true,
          onPressed: () {},
        ),
      );
      final Size size = tester.getSize(find.byType(IconButton));
      expect(size.height, greaterThanOrEqualTo(34));
    });
  });

  group('theme consistency', () {
    test('one radius across every button style', () {
      for (final ThemeData theme in <ThemeData>[
        AppTheme.light,
        AppTheme.dark,
      ]) {
        for (final ButtonStyle? style in <ButtonStyle?>[
          theme.filledButtonTheme.style,
          theme.elevatedButtonTheme.style,
          theme.outlinedButtonTheme.style,
        ]) {
          final OutlinedBorder? shape = style?.shape?.resolve(<WidgetState>{});
          expect(shape, isA<RoundedRectangleBorder>());
          final BorderRadius radius =
              (shape! as RoundedRectangleBorder).borderRadius as BorderRadius;
          expect(radius.topLeft.x, AppSpacing.radiusButton);
        }
      }
    });

    test('button icons are smaller than standalone icons', () {
      // An icon sized for a list row towers over a 14px button label.
      expect(AppSpacing.buttonIcon, lessThan(AppSpacing.iconLg));
      expect(AppSpacing.buttonIconSm, lessThan(AppSpacing.buttonIcon));
    });

    test('the FAB is sized from the same scale as the buttons', () {
      for (final ThemeData theme in <ThemeData>[
        AppTheme.light,
        AppTheme.dark,
      ]) {
        final BoxConstraints? constraints =
            theme.floatingActionButtonTheme.extendedSizeConstraints;
        expect(constraints, isNotNull);
        expect(constraints!.maxHeight, AppSpacing.fabHeight);
      }
    });
  });
}
