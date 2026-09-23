import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config/app_config.dart';
import 'core/config/env_config.dart';
import 'core/constants/app_constants.dart';
import 'core/theme/app_spacing.dart';
import 'core/theme/app_theme.dart';
import 'providers/ai_chat_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/bank_account_provider.dart';
import 'providers/budget_provider.dart';
import 'providers/category_provider.dart';
import 'providers/dashboard_provider.dart';
import 'providers/expense_provider.dart';
import 'providers/export_provider.dart';
import 'providers/income_provider.dart';
import 'providers/payment_method_provider.dart';
import 'providers/reports_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/statement_provider.dart';
import 'repositories/auth_repository.dart';
import 'repositories/bank_account_repository.dart';
import 'repositories/budget_repository.dart';
import 'repositories/category_repository.dart';
import 'repositories/expense_repository.dart';
import 'repositories/export_repository.dart';
import 'repositories/income_repository.dart';
import 'repositories/ledger_repository.dart';
import 'repositories/payment_method_repository.dart';
import 'repositories/profile_repository.dart';
import 'screens/auth/auth_gate.dart';
import 'services/ai/ai_chat_service.dart';
import 'services/preferences_service.dart';
import 'services/receipt/mlkit_receipt_scanner.dart';
import 'services/receipt/receipt_scanner_service.dart';
import 'services/supabase_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // This is a mobile app; lock to portrait so layouts stay predictable.
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  try {
    await EnvConfig.load();
    await SupabaseService.initialize();
  } catch (error) {
    // Without configuration the app cannot function, but it must still render
    // something actionable instead of a blank screen.
    runApp(_StartupFailureApp(error: error));
    return;
  }

  final PreferencesService preferences = await PreferencesService.create();

  runApp(ExpenseTrackerApp(preferences: preferences));
}

class ExpenseTrackerApp extends StatelessWidget {
  const ExpenseTrackerApp({super.key, required this.preferences});

  final PreferencesService preferences;

  @override
  Widget build(BuildContext context) {
    final SupabaseClient client = SupabaseService.client;

    // Repositories are created once and injected into providers, so no widget
    // reaches Supabase directly and each layer stays independently testable.
    final ExpenseRepository expenseRepository = ExpenseRepository(client);
    final IncomeRepository incomeRepository = IncomeRepository(client);
    final BudgetRepository budgetRepository = BudgetRepository(client);
    final LedgerRepository ledgerRepository = LedgerRepository(client);
    final BankAccountRepository bankAccountRepository =
        BankAccountRepository(client);

    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(
          create: (_) => AuthProvider(AuthRepository(SupabaseService.auth)),
        ),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(
            repository: ProfileRepository(client),
            preferences: preferences,
          ),
        ),
        ChangeNotifierProvider<CategoryProvider>(
          create: (_) => CategoryProvider(CategoryRepository(client)),
        ),
        ChangeNotifierProvider<PaymentMethodProvider>(
          create: (_) =>
              PaymentMethodProvider(PaymentMethodRepository(client)),
        ),
        ChangeNotifierProvider<ExpenseProvider>(
          create: (_) => ExpenseProvider(expenseRepository),
        ),
        ChangeNotifierProvider<IncomeProvider>(
          create: (_) => IncomeProvider(incomeRepository),
        ),
        ChangeNotifierProvider<BudgetProvider>(
          create: (_) => BudgetProvider(
            budgets: budgetRepository,
            expenses: expenseRepository,
          ),
        ),
        ChangeNotifierProvider<DashboardProvider>(
          create: (_) => DashboardProvider(
            expenses: expenseRepository,
            income: incomeRepository,
            budgets: budgetRepository,
          ),
        ),
        ChangeNotifierProvider<BankAccountProvider>(
          create: (_) => BankAccountProvider(
            accounts: bankAccountRepository,
            ledger: ledgerRepository,
          ),
        ),
        ChangeNotifierProvider<StatementProvider>(
          create: (_) => StatementProvider(ledgerRepository),
        ),
        ChangeNotifierProvider<ReportsProvider>(
          create: (_) => ReportsProvider(
            expenses: expenseRepository,
            income: incomeRepository,
          ),
        ),
        ChangeNotifierProvider<ExportProvider>(
          create: (_) => ExportProvider(
            repository: ExportRepository(
              expenses: expenseRepository,
              income: incomeRepository,
              ledger: ledgerRepository,
            ),
          ),
        ),
        // The one place the OCR engine is named. Swapping the on-device
        // recogniser for a cloud or GenAI extractor later is a change to this
        // line and nothing else — every screen depends on the interface.
        Provider<ReceiptScannerService>(
          create: (_) => MlKitReceiptScanner(),
          dispose: (_, ReceiptScannerService scanner) => scanner.dispose(),
        ),
        // The assistant's only connection to the outside world: the
        // authenticated `ai-chat` Edge Function, called with the session the
        // Supabase client already holds. No model, key or endpoint is known
        // to the app, so there is nothing here for an APK to leak.
        Provider<AiChatService>(
          create: (_) => SupabaseAiChatService(client),
        ),
        ChangeNotifierProvider<AiChatProvider>(
          create: (BuildContext context) =>
              AiChatProvider(context.read<AiChatService>()),
        ),
      ],
      child: Consumer<SettingsProvider>(
        builder: (BuildContext context, SettingsProvider settings, Widget? _) {
          return MaterialApp(
            title: AppConstants.appName,
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: settings.themeMode,
            home: const AuthGate(),
            builder: (BuildContext context, Widget? child) {
              // Cap text scaling so extreme accessibility settings cannot
              // break the dense currency layouts.
              final MediaQueryData media = MediaQuery.of(context);
              Widget content = MediaQuery(
                data: media.copyWith(
                  textScaler: media.textScaler.clamp(
                    minScaleFactor: 0.85,
                    maxScaleFactor: 1.3,
                  ),
                ),
                child: child ?? const SizedBox.shrink(),
              );

              // Corner ribbon whenever the auth bypass is compiled in, so a
              // build with authentication disabled can never be mistaken for
              // a normal one.
              if (AppConfig.bypassAuth) {
                content = Banner(
                  message: 'DEV AUTH',
                  location: BannerLocation.topEnd,
                  color: Colors.deepOrange,
                  child: content,
                );
              }
              return content;
            },
          );
        },
      ),
    );
  }
}

/// Shown when `.env` is missing or Supabase cannot be initialised.
///
/// Deliberately describes the problem without echoing any configuration value.
class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final String detail = error is StateError
        ? (error as StateError).message
        : 'Supabase could not be initialised. Check that .env contains a '
            'valid SUPABASE_URL and SUPABASE_ANON_KEY, and that .env is '
            'listed under flutter/assets in pubspec.yaml.';

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.settings_ethernet_rounded, size: 40),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'Configuration problem',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
