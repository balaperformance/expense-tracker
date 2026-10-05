// Settings: the palette preference, and sections that fold away.
//
// Both are device-local and remembered across launches, as on the web
// (ui/src/state/settings.tsx, ui/src/features/settings/SettingsGroup.tsx).
// Everything here runs on fakes — no account is touched.

import 'package:expense_tracker/core/theme/app_palette.dart';
import 'package:expense_tracker/core/theme/app_theme.dart';
import 'package:expense_tracker/providers/auth_provider.dart';
import 'package:expense_tracker/providers/notification_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/repositories/auth_repository.dart';
import 'package:expense_tracker/repositories/notification_repository.dart';
import 'package:expense_tracker/repositories/profile_repository.dart';
import 'package:expense_tracker/screens/settings/settings_screen.dart';
import 'package:expense_tracker/services/preferences_service.dart';
import 'package:expense_tracker/services/push/push_platform.dart';
import 'package:expense_tracker/services/schema_capabilities.dart';
import 'package:expense_tracker/widgets/common/settings_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

SupabaseClient _client() => SupabaseClient(
      'http://localhost:54321',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );

SettingsProvider _settings(PreferencesService preferences) => SettingsProvider(
      repository: ProfileRepository(_client()),
      preferences: preferences,
    );

class _SignedOutAuth extends AuthProvider {
  _SignedOutAuth()
      : super(AuthRepository(GoTrueClient(autoRefreshToken: false)));
}

void main() {
  late PreferencesService preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    preferences = await PreferencesService.create();
  });

  group('palette', () {
    test('everyone starts on Current, as on the web', () {
      expect(preferences.palette, AppPalette.current);
      expect(_settings(preferences).palette, AppPalette.current);
    });

    test('a chosen palette is stored by the web id and survives a restart',
        () async {
      final SettingsProvider settings = _settings(preferences);
      int heard = 0;
      settings.addListener(() => heard++);

      await settings.setPalette(AppPalette.matte);
      expect(settings.palette, AppPalette.matte);
      expect(heard, 1, reason: 'the MaterialApp rebuilds its themes');

      final SharedPreferences raw = await SharedPreferences.getInstance();
      expect(raw.getString('pref_palette'), 'matte');

      final PreferencesService relaunched = await PreferencesService.create();
      expect(_settings(relaunched).palette, AppPalette.matte);
    });

    test('choosing the palette already in use changes nothing', () async {
      final SettingsProvider settings = _settings(preferences);
      int heard = 0;
      settings.addListener(() => heard++);
      await settings.setPalette(AppPalette.current);
      expect(heard, 0);
    });

    test('an unknown stored value reads as Current', () async {
      SharedPreferences.setMockInitialValues(
        <String, Object>{'pref_palette': 'neon'},
      );
      final PreferencesService stale = await PreferencesService.create();
      expect(stale.palette, AppPalette.current);
    });

    test('signing out keeps the palette: it belongs to the device', () async {
      final SettingsProvider settings = _settings(preferences);
      await settings.setPalette(AppPalette.matte);
      await settings.reset();
      expect(settings.palette, AppPalette.matte);
      expect(preferences.palette, AppPalette.matte);
    });
  });

  group('folding sections', () {
    test('every section starts folded; an open one is remembered', () async {
      final SettingsProvider settings = _settings(preferences);
      expect(settings.isSectionOpen('money'), isFalse);

      int heard = 0;
      settings.addListener(() => heard++);
      await settings.setSectionOpen('money', true);
      await settings.setSectionOpen('appearance', true);
      expect(heard, 0, reason: 'folding must not rebuild the whole app');

      final PreferencesService relaunched = await PreferencesService.create();
      final SettingsProvider again = _settings(relaunched);
      expect(again.isSectionOpen('money'), isTrue);
      expect(again.isSectionOpen('appearance'), isTrue);
      expect(again.isSectionOpen('export'), isFalse);

      await again.setSectionOpen('money', false);
      expect((await PreferencesService.create()).settingsOpen,
          <String>{'appearance'});
    });

    Future<void> pumpGroup(
      WidgetTester tester, {
      bool initiallyOpen = false,
      ValueChanged<bool>? onOpenChanged,
      bool reduceMotion = false,
    }) {
      return tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Scaffold(
            body: Column(
              children: <Widget>[
                SettingsGroup(
                  title: 'Money',
                  summary: 'Accounts, cards · INR',
                  initiallyOpen: initiallyOpen,
                  onOpenChanged: onOpenChanged,
                  child: const Text('Bank accounts'),
                ),
                const Text('below'),
              ],
            ),
          ),
        ),
      ));
    }

    testWidgets('folded, it shows its title and summary and builds nothing',
        (WidgetTester tester) async {
      await pumpGroup(tester);
      expect(find.text('Money'), findsOneWidget);
      expect(find.text('Accounts, cards · INR'), findsOneWidget);
      expect(find.text('Bank accounts'), findsNothing);
      expect(
        tester.getSize(find.byType(InkWell).first).height,
        greaterThanOrEqualTo(48),
        reason: 'the heading is a full touch target',
      );
    });

    testWidgets('the heading opens and closes it, turning the chevron',
        (WidgetTester tester) async {
      final List<bool> changes = <bool>[];
      await pumpGroup(tester, onOpenChanged: changes.add);

      await tester.tap(find.text('Money'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Bank accounts'), findsOneWidget,
          reason: 'content appears as the panel opens');
      await tester.pumpAndSettle();
      expect(find.text('Bank accounts'), findsOneWidget);
      expect(
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
        0.5,
      );

      await tester.tap(find.text('Money'));
      await tester.pumpAndSettle();
      expect(find.text('Bank accounts'), findsNothing);
      expect(changes, <bool>[true, false]);
    });

    testWidgets('opened earlier, it starts open', (WidgetTester tester) async {
      await pumpGroup(tester, initiallyOpen: true);
      expect(find.text('Bank accounts'), findsOneWidget);
    });

    testWidgets('under reduce motion it opens in one step',
        (WidgetTester tester) async {
      await pumpGroup(tester, reduceMotion: true);
      await tester.tap(find.text('Money'));
      await tester.pump();
      expect(find.text('Bank accounts'), findsOneWidget);
      // Fully open on the first frame — no panel travelling (the ink ripple
      // under the finger is the only thing still moving).
      final Align panel = tester.widget(find.ancestor(
        of: find.text('Bank accounts'),
        matching: find.byType(Align),
      ).first);
      expect(panel.heightFactor, 1);
      expect(
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).duration,
        Duration.zero,
      );
    });
  });

  group('the Settings screen', () {
    setUp(() {
      SchemaCapabilities.debugReset();
      SchemaCapabilities.debugOverride(notifications: true);
    });

    tearDown(SchemaCapabilities.debugReset);

    /// The screen under the palette the provider holds, wired the way
    /// main.dart wires the MaterialApp.
    Future<SettingsProvider> pumpScreen(
      WidgetTester tester, {
      double width = 360,
      Brightness brightness = Brightness.light,
      SettingsProvider? provider,
    }) async {
      tester.view.physicalSize = Size(width * 2, 1000 * 2);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      final SettingsProvider settings = provider ?? _settings(preferences);
      await tester.pumpWidget(MultiProvider(
        providers: <ChangeNotifierProvider<dynamic>>[
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AuthProvider>.value(value: _SignedOutAuth()),
          ChangeNotifierProvider<NotificationProvider>.value(
            value: NotificationProvider(
              platform: MethodChannelPushPlatform(),
              repository: NotificationRepository(_client()),
              preferences: preferences,
            ),
          ),
        ],
        child: Consumer<SettingsProvider>(
          builder: (BuildContext context, SettingsProvider s, Widget? _) =>
              MaterialApp(
            theme: AppTheme.of(s.palette, Brightness.light),
            darkTheme: AppTheme.of(s.palette, Brightness.dark),
            themeMode: brightness == Brightness.dark
                ? ThemeMode.dark
                : ThemeMode.light,
            home: const SettingsScreen(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return settings;
    }

    testWidgets('every section but About folds, each with its one line',
        (WidgetTester tester) async {
      await pumpScreen(tester);

      for (final (String title, String summary) in <(String, String)>[
        ('Assistant', 'Ask about your money, or record an entry'),
        ('Notifications', 'Checking this phone…'),
        ('Money', 'Accounts, cards, budgets, categories · INR'),
        ('Data & Export', 'Statement import, reports and transactions'),
        ('Appearance', 'Current · System'),
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
        expect(find.text(summary), findsOneWidget, reason: summary);
      }
      expect(find.byType(SettingsGroup), findsNWidgets(5));
      expect(find.text('Bank accounts'), findsNothing);
      expect(find.text('Import bank statement'), findsNothing);

      // About stays a plain, open section.
      expect(find.text('About'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('the phone-only import row lives in Data & Export',
        (WidgetTester tester) async {
      await pumpScreen(tester);
      await tester.tap(find.text('Data & Export'));
      await tester.pumpAndSettle();
      expect(find.text('Import bank statement'), findsOneWidget);
      expect(find.text('Export a report'), findsOneWidget);
      expect(preferences.settingsOpen, contains('export'));
    });

    testWidgets('Appearance switches the palette, and the app follows',
        (WidgetTester tester) async {
      final SettingsProvider settings = await pumpScreen(tester);
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      expect(find.text('Palette'), findsOneWidget);
      expect(find.text('Mode'), findsOneWidget);

      await tester.tap(find.text('Matte & Sand'));
      await tester.pumpAndSettle();

      expect(settings.palette, AppPalette.matte);
      expect(preferences.palette, AppPalette.matte);
      expect(find.text('Matte & Sand · System'), findsOneWidget);
      final BuildContext context = tester.element(find.text('Palette'));
      expect(Theme.of(context).extension<PaletteTokens>()?.palette,
          AppPalette.matte);
      expect(Theme.of(context).scaffoldBackgroundColor,
          PaletteTokens.matteLight.background);
    });

    testWidgets('a section opened before is open on the next visit',
        (WidgetTester tester) async {
      await preferences.setSettingsOpen(<String>{'money'});
      await pumpScreen(tester, provider: _settings(preferences));
      expect(find.text('Bank accounts'), findsOneWidget);
      expect(find.text('Import bank statement'), findsNothing);
    });

    for (final double width in <double>[320, 360, 411]) {
      testWidgets('lays out open at $width dp in every palette and mode',
          (WidgetTester tester) async {
        await preferences.setSettingsOpen(<String>{'appearance', 'money'});
        for (final AppPalette palette in AppPalette.values) {
          await preferences.setPalette(palette);
          for (final Brightness brightness in Brightness.values) {
            await pumpScreen(
              tester,
              width: width,
              brightness: brightness,
              provider: _settings(preferences),
            );
            expect(tester.takeException(), isNull,
                reason: '$palette $brightness at $width');
            expect(find.text('Matte & Sand'), findsOneWidget);
          }
        }
      });
    }
  });
}
