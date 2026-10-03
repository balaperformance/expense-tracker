import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/validators.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/app_buttons.dart';
import 'auth_scaffold.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    final AuthProvider auth = context.read<AuthProvider>();
    final NavigatorState navigator = Navigator.of(context);

    final bool ok = await auth.signUp(
      email: _email.text,
      password: _password.text,
      fullName: _name.text,
    );

    if (!mounted || !ok) return;

    // Either a session now exists (AuthGate takes over) or confirmation is
    // pending and the caller shows the verify screen. Both cases pop.
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    final bool busy = auth.submitting;

    return AuthScaffold(
      showBack: true,
      title: 'Register new user',
      subtitle: 'Track spending, set budgets and stay on top of your money.',
      children: <Widget>[
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AuthField(
                controller: _name,
                label: 'Full name',
                icon: Icons.person_outline_rounded,
                validator: (String? v) => Validators.required(v, 'Name'),
                keyboardType: TextInputType.name,
                autofillHints: const <String>[AutofillHints.name],
                enabled: !busy,
              ),
              const SizedBox(height: AppSpacing.lg),
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
                validator: Validators.newPassword,
                obscure: _obscure,
                enabled: !busy,
                autofillHints: const <String>[AutofillHints.newPassword],
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
              // Stated before it can be broken, so the rule is not discovered
              // only by failing validation.
              const SizedBox(height: AppSpacing.sm),
              Padding(
                padding: const EdgeInsets.only(left: AppSpacing.xs),
                child: Text(
                  Validators.passwordHint,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              AuthField(
                controller: _confirm,
                label: 'Confirm password',
                icon: Icons.lock_outline_rounded,
                validator: (String? v) =>
                    Validators.confirmPassword(v, _password.text),
                obscure: _obscure,
                textInputAction: TextInputAction.done,
                onSubmitted: busy ? null : _submit,
                autofillHints: const <String>[AutofillHints.newPassword],
                enabled: !busy,
              ),
            ],
          ),
        ),
        if (auth.errorMessage != null) ...<Widget>[
          const SizedBox(height: AppSpacing.xl),
          InlineError(message: auth.errorMessage!),
        ],
        const SizedBox(height: AppSpacing.lg),
        AppButton.submit(
          label: 'Create account',
          busy: busy,
          busyLabel: 'Creating…',
          onPressed: _submit,
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'By continuing you agree to keep your financial data on your own '
          'Supabase project.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
