import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_spacing.dart';
import '../../providers/ai_chat_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/bank_account_provider.dart';
import '../../providers/budget_provider.dart';
import '../../providers/category_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/expense_provider.dart';
import '../../providers/income_provider.dart';
import '../../providers/payment_method_provider.dart';
import '../../providers/reports_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/statement_provider.dart';
import '../../services/dev_auth_bypass.dart';
import '../../services/schema_capabilities.dart';
import '../../services/supabase_service.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/brand_mark.dart';
import '../../widgets/common/state_views.dart';
import '../shell/home_shell.dart';
import 'login_screen.dart';

/// Root router: splash while the persisted session resolves, the login flow
/// when signed out, and the app shell once the session is bootstrapped.
///
/// Bootstrapping (profile row, default categories and payment methods) runs
/// once per signed-in user before the shell renders, so no screen has to cope
/// with half-initialised reference data.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  String? _bootstrappedUserId;
  bool _bootstrapping = false;
  String? _bootstrapError;

  // Development bypass state. Untouched when AppConfig.bypassAuth is false.
  bool _bypassRunning = false;
  bool _bypassAttempted = false;
  String? _bypassError;

  /// Set when the user signs out deliberately, so the bypass does not
  /// immediately sign them back in and make the sign-out button look broken.
  bool _bypassSuppressed = false;

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();

    switch (auth.stage) {
      case AuthStage.initialising:
        return const _SplashScreen();

      case AuthStage.signedOut:
        if (_bootstrappedUserId != null) {
          // Defer so providers are not mutated during this build.
          WidgetsBinding.instance.addPostFrameCallback((_) => _teardown());
        }

        if (AppConfig.bypassAuth && !_bypassSuppressed) {
          if (_bypassError != null) {
            return _DevBypassErrorScreen(
              message: _bypassError!,
              onRetry: () {
                setState(() {
                  _bypassError = null;
                  _bypassAttempted = false;
                });
              },
              onUseLogin: () => setState(() => _bypassSuppressed = true),
            );
          }
          if (!_bypassAttempted) {
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _runBypass());
          }
          return const _SplashScreen(message: 'Signing in (dev bypass)…');
        }

        return const LoginScreen();

      case AuthStage.signedIn:
        final String userId = auth.userId!;
        if (_bootstrappedUserId != userId) {
          if (!_bootstrapping && _bootstrapError == null) {
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _bootstrap(userId));
          }
          if (_bootstrapError != null) {
            return _BootstrapErrorScreen(
              message: _bootstrapError!,
              onRetry: () {
                setState(() => _bootstrapError = null);
                _bootstrap(userId);
              },
            );
          }
          return const _SplashScreen(message: 'Setting things up…');
        }
        return const HomeShell();
    }
  }

  /// Acquires a session without showing the login screen. Development only.
  ///
  /// On success the Supabase auth stream moves [AuthProvider] to signedIn and
  /// the normal bootstrap path takes over, so nothing downstream is aware the
  /// bypass happened.
  Future<void> _runBypass() async {
    if (_bypassRunning || _bypassAttempted) return;
    _bypassRunning = true;
    _bypassAttempted = true;

    final DevSessionResult result =
        await DevAuthBypass(SupabaseService.auth).ensureSession();

    _bypassRunning = false;
    if (!mounted) return;

    if (result.succeeded) {
      DevSessionBadge.source = result;
      // No setState needed: the auth stream drives the rebuild.
      return;
    }
    setState(() => _bypassError = result.message);
  }

  Future<void> _bootstrap(String userId) async {
    if (_bootstrapping) return;
    _bootstrapping = true;

    final AuthProvider auth = context.read<AuthProvider>();
    final SettingsProvider settings = context.read<SettingsProvider>();
    final CategoryProvider categories = context.read<CategoryProvider>();
    final PaymentMethodProvider payments =
        context.read<PaymentMethodProvider>();

    try {
      // Which optional tables and columns exist decides what the rest of the
      // app may query, so this has to settle before any screen loads data.
      await SchemaCapabilities.resolve(SupabaseService.client);

      // Profile first: currency drives every money label on the first frame.
      await settings.loadProfile(
        userId: userId,
        fallbackName: auth.metadataName,
      );
      await Future.wait(<Future<void>>[
        categories.initialise(userId),
        payments.initialise(userId),
      ]);

      final String? failure = categories.errorMessage ?? payments.errorMessage;
      if (!mounted) return;

      setState(() {
        if (failure != null) {
          _bootstrapError = failure;
        } else {
          _bootstrappedUserId = userId;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _bootstrapError = error.toString());
    } finally {
      _bootstrapping = false;
    }
  }

  /// Clears every user-scoped provider so a second account never sees the
  /// first one's cached rows.
  void _teardown() {
    if (!mounted) return;
    // Reaching here means the user was signed in and now is not, i.e. they
    // signed out deliberately. Suppress the bypass for the rest of this
    // launch so the sign-out actually sticks and the login flow is testable.
    _bypassSuppressed = true;
    DevSessionBadge.clear();
    context.read<SettingsProvider>().reset();
    context.read<CategoryProvider>().reset();
    context.read<PaymentMethodProvider>().reset();
    context.read<ExpenseProvider>().reset();
    context.read<IncomeProvider>().reset();
    context.read<BudgetProvider>().reset();
    context.read<DashboardProvider>().reset();
    context.read<BankAccountProvider>().reset();
    context.read<StatementProvider>().reset();
    context.read<ReportsProvider>().reset();
    // The conversation is the user's; the next account must not read it.
    context.read<AiChatProvider>().reset();
    setState(() {
      _bootstrappedUserId = null;
      _bootstrapError = null;
    });
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: AppFadeIn(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const BrandLockup(tagline: 'Spend with intention'),
              const SizedBox(height: AppSpacing.xxl),
              // A short line rather than a spinner: quieter, and it reads as
              // "loading" without drawing the eye away from the mark.
              SizedBox(
                width: 72,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
                  child: LinearProgressIndicator(
                    minHeight: 3,
                    color: theme.colorScheme.primary,
                    backgroundColor:
                        theme.colorScheme.primary.withOpacity(0.14),
                  ),
                ),
              ),
              if (message != null) ...<Widget>[
                const SizedBox(height: AppSpacing.lg),
                Text(message!, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown when the development bypass could not get a session.
///
/// Always offers the real login screen, so a failed bypass never blocks work.
class _DevBypassErrorScreen extends StatelessWidget {
  const _DevBypassErrorScreen({
    required this.message,
    required this.onRetry,
    required this.onUseLogin,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onUseLogin;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Icon(
                  Icons.developer_mode_rounded,
                  size: 38,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'Dev bypass could not sign in',
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.md),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withOpacity(0.04),
                    borderRadius:
                        BorderRadius.circular(AppSpacing.radiusMd),
                  ),
                  child: Text(
                    message,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                AppButton(label: 'Retry', onPressed: onRetry),
                const SizedBox(height: AppSpacing.sm),
                AppButton(
                  label: 'Use the login screen',
                  variant: AppButtonVariant.secondary,
                  onPressed: onUseLogin,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BootstrapErrorScreen extends StatelessWidget {
  const _BootstrapErrorScreen({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Expanded(child: ErrorView(message: message, onRetry: onRetry)),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.xxl),
              child: TextButton(
                onPressed: () => context.read<AuthProvider>().signOut(),
                child: const Text('Sign out'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
