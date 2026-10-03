import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/app_buttons.dart';
import 'auth_scaffold.dart';

/// Shown after sign-up when the Supabase project requires email confirmation.
///
/// Without this the user would be bounced back to a login form that rejects
/// them with no explanation.
class VerifyEmailScreen extends StatelessWidget {
  const VerifyEmailScreen({super.key, required this.email});

  final String email;

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    final ThemeData theme = Theme.of(context);

    return AuthScaffold(
      showBack: true,
      icon: Icons.mark_email_unread_rounded,
      title: 'Confirm your email',
      subtitle: 'We sent a verification link to $email. '
          'Open it, then come back and sign in.',
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
                  'Not seeing it? Check your spam folder, or resend the link '
                  'below.',
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                ),
              ),
            ],
          ),
        ),
        if (auth.errorMessage != null) ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          InlineError(message: auth.errorMessage!),
        ],
        const SizedBox(height: AppSpacing.lg),
        AppButton.submit(
          label: 'Back to sign in',
          onPressed: () => Navigator.of(context).pop(),
        ),
        const SizedBox(height: AppSpacing.md),
        AppButton.submit(
          label: 'Resend email',
          variant: AppButtonVariant.secondary,
          busy: auth.submitting,
          busyLabel: 'Sending…',
          onPressed: () async {
            final bool ok = await auth.resendConfirmation();
            if (!context.mounted) return;
            if (ok) {
              AppFeedback.success(context, 'Verification email sent.');
            }
          },
        ),
      ],
    );
  }
}
