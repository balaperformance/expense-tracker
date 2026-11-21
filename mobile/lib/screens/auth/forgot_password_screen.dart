import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/validators.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/state_views.dart';
import 'auth_scaffold.dart';

/// Requests a password-reset email.
///
/// The emailed link opens the web app's reset page in the browser (the app has
/// no deep link — see `PublicAppUrl`), where the new password is chosen and
/// any expired or invalid link is explained. This screen says so up front, so
/// nobody waits for the app to open.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, this.initialEmail = ''});

  final String initialEmail;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _email =
      TextEditingController(text: widget.initialEmail);

  /// The address a link was sent to; non-null shows the confirmation.
  String? _sentTo;

  @override
  void initState() {
    super.initState();
    // An error left by the sign-in form does not belong here.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AuthProvider>().clearError();
    });
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    final AuthProvider auth = context.read<AuthProvider>();
    final String email = _email.text.trim();
    final bool ok = await auth.requestPasswordReset(email);
    if (!mounted || !ok) return;
    setState(() => _sentTo = email);
  }

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    final String? sentTo = _sentTo;
    return sentTo == null ? _form(auth) : _sent(sentTo);
  }

  Widget _form(AuthProvider auth) {
    final bool busy = auth.submitting;
    return AuthScaffold(
      showBack: true,
      icon: Icons.lock_reset_rounded,
      title: 'Reset your password',
      subtitle: "Enter your account email and we'll send you a link to "
          'choose a new password.',
      children: <Widget>[
        Form(
          key: _formKey,
          child: AuthField(
            controller: _email,
            label: 'Email',
            icon: Icons.mail_outline_rounded,
            validator: Validators.email,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.send,
            onSubmitted: busy ? null : _submit,
            autofillHints: const <String>[AutofillHints.email],
            enabled: !busy,
          ),
        ),
        if (auth.errorMessage != null) ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          InlineError(message: auth.errorMessage!),
        ],
        const SizedBox(height: AppSpacing.xl),
        AppButton.submit(
          label: 'Send reset link',
          busy: busy,
          busyLabel: 'Sending…',
          onPressed: _submit,
        ),
      ],
    );
  }

  Widget _sent(String email) {
    final ThemeData theme = Theme.of(context);
    return AuthScaffold(
      showBack: true,
      icon: Icons.mark_email_unread_rounded,
      title: 'Check your email',
      subtitle: 'If $email has an account, a password reset link is on its '
          'way.',
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withOpacity(0.07),
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(
              color: theme.colorScheme.primary.withOpacity(0.20),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.lightbulb_outline_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'The link opens a web page where you choose a new '
                  'password. Then come back here and sign in with it. The '
                  'link works once and expires after a while — not seeing '
                  'it? Check your spam folder.',
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        AppButton.submit(
          label: 'Back to sign in',
          onPressed: () => Navigator.of(context).pop(),
        ),
        const SizedBox(height: AppSpacing.md),
        AppButton.submit(
          label: 'Send another link',
          variant: AppButtonVariant.secondary,
          onPressed: () => setState(() => _sentTo = null),
        ),
      ],
    );
  }
}
