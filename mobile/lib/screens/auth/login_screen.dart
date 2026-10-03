import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/validators.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/app_buttons.dart';
import 'auth_scaffold.dart';
import 'signup_screen.dart';
import 'verify_email_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    final AuthProvider auth = context.read<AuthProvider>();
    await auth.signIn(email: _email.text, password: _password.text);
    // Navigation is driven by AuthGate reacting to the auth state stream, so
    // there is nothing to push here on success.
  }

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    final bool busy = auth.submitting;

    return AuthScaffold(
      title: 'Welcome back',
      subtitle: 'Sign in to pick up where you left off.',
      children: <Widget>[
        Form(
          key: _formKey,
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                AuthField(
                  controller: _email,
                  label: 'Email',
                  icon: Icons.mail_outline_rounded,
                  validator: Validators.email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const <String>[AutofillHints.email],
                  enabled: !busy,
                ),
                const SizedBox(height: AppSpacing.lg),
                AuthField(
                  controller: _password,
                  label: 'Password',
                  icon: Icons.lock_outline_rounded,
                  validator: Validators.password,
                  obscure: _obscure,
                  textInputAction: TextInputAction.done,
                  onSubmitted: busy ? null : _submit,
                  autofillHints: const <String>[AutofillHints.password],
                  enabled: !busy,
                  suffix: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (auth.errorMessage != null) ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          InlineError(message: auth.errorMessage!),
        ],
        const SizedBox(height: AppSpacing.xl),
        AppButton.submit(
          label: 'Sign in',
          busy: busy,
          busyLabel: 'Signing in…',
          onPressed: _submit,
        ),

        // Registration is a full-width outlined button rather than a text
        // link: it is the second thing anyone arriving here might need, and a
        // link buried in a sentence is easy to miss. Secondary, not primary,
        // so Sign in remains the one filled action on the screen.
        const SizedBox(height: AppSpacing.md),
        AppButton.submit(
          label: 'Register New User',
          variant: AppButtonVariant.secondary,
          onPressed: busy ? null : _openSignUp,
        ),

        // Password reset is deliberately not offered here. Changing a
        // password needs the current one and happens in Settings once signed
        // in, so a locked-out user is told who can actually help rather than
        // being sent to a dead end.
        const SizedBox(height: AppSpacing.lg),
        Text(
          'Forgotten your password? It can only be changed from Settings '
          'while signed in — ask whoever administers this app to reset it '
          'for you.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    );
  }

  Future<void> _openSignUp() async {
    final AuthProvider auth = context.read<AuthProvider>();
    auth.clearError();

    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SignUpScreen()),
    );

    if (!mounted) return;

    // Sign-up with email confirmation leaves the user signed out; surface the
    // verify screen rather than silently returning to the login form.
    final String? pending = auth.pendingConfirmationEmail;
    if (pending != null) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => VerifyEmailScreen(email: pending),
        ),
      );
    }
  }
}
