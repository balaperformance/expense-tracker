import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/validators.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/state_views.dart';

/// Changes the signed-in user's password.
///
/// No email, no link, no code: the user proves who they are with the password
/// they already have, which is the only thing they need to know to choose a
/// new one. Nothing typed here is stored, cached or logged — the fields are
/// disposed with the sheet.
class ChangePasswordSheet extends StatefulWidget {
  const ChangePasswordSheet({super.key});

  /// Opens the sheet. Returns true when the password was changed.
  static Future<bool> show(BuildContext context) async {
    context.read<AuthProvider>().clearError();
    final bool? changed = await showAppSheet<bool>(
      context: context,
      builder: (_) => const ChangePasswordSheet(),
    );
    return changed ?? false;
  }

  @override
  State<ChangePasswordSheet> createState() => _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends State<ChangePasswordSheet> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  bool _obscureCurrent = true;
  bool _obscureNew = true;

  @override
  void dispose() {
    // Clearing before disposing keeps the typed passwords out of any
    // controller still referenced while the sheet animates away.
    _current.clear();
    _next.clear();
    _confirm.clear();
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    final bool busy = auth.submitting;

    return Form(
      key: _formKey,
      child: AppSheet(
        title: 'Change password',
        subtitle: 'Confirm the password you use now, then choose a new one.',
        footer: AppButton.submit(
          label: 'Update password',
          busy: busy,
          busyLabel: 'Updating…',
          onPressed: busy ? null : _submit,
        ),
        children: <Widget>[
          _PasswordField(
            controller: _current,
            label: 'Current password',
            obscure: _obscureCurrent,
            enabled: !busy,
            validator: (String? v) =>
                (v ?? '').isEmpty ? 'Enter your current password' : null,
            onToggle: () =>
                setState(() => _obscureCurrent = !_obscureCurrent),
            autofillHint: AutofillHints.password,
          ),
          const SizedBox(height: AppSpacing.lg),
          const Divider(height: 1),
          const SizedBox(height: AppSpacing.lg),
          _PasswordField(
            controller: _next,
            label: 'New password',
            obscure: _obscureNew,
            enabled: !busy,
            validator: Validators.newPassword,
            onToggle: () => setState(() => _obscureNew = !_obscureNew),
            autofillHint: AutofillHints.newPassword,
          ),
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.xs),
            child: Text(
              Validators.passwordHint,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _PasswordField(
            controller: _confirm,
            label: 'Confirm new password',
            obscure: _obscureNew,
            enabled: !busy,
            textInputAction: TextInputAction.done,
            onSubmitted: busy ? null : _submit,
            validator: (String? v) =>
                Validators.confirmPassword(v, _next.text),
            onToggle: () => setState(() => _obscureNew = !_obscureNew),
            autofillHint: AutofillHints.newPassword,
          ),
          if (auth.errorMessage != null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            InlineError(message: auth.errorMessage!),
          ],
          const SizedBox(height: AppSpacing.md),
          Text(
            'You will stay signed in on this device. Sign in with the new '
            'password everywhere else.',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    final AuthProvider auth = context.read<AuthProvider>();
    final NavigatorState navigator = Navigator.of(context);

    final bool ok = await auth.changePassword(
      currentPassword: _current.text,
      newPassword: _next.text,
    );

    if (!mounted) return;

    if (!ok) {
      // The sheet stays open showing auth.errorMessage — a wrong current
      // password should cost one field, not the whole form.
      return;
    }

    navigator.pop(true);
  }
}

/// One obscured field with a reveal toggle, so the three rows match.
class _PasswordField extends StatelessWidget {
  const _PasswordField({
    required this.controller,
    required this.label,
    required this.obscure,
    required this.enabled,
    required this.validator,
    required this.onToggle,
    required this.autofillHint,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final bool obscure;
  final bool enabled;
  final String? Function(String?) validator;
  final VoidCallback onToggle;
  final String autofillHint;
  final TextInputAction textInputAction;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      validator: validator,
      obscureText: obscure,
      enabled: enabled,
      textInputAction: textInputAction,
      autofillHints: <String>[autofillHint],
      onFieldSubmitted: (_) => onSubmitted?.call(),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(
          Icons.lock_outline_rounded,
          size: AppSpacing.iconMd,
        ),
        suffixIcon: IconButton(
          tooltip: obscure ? 'Show' : 'Hide',
          onPressed: onToggle,
          icon: Icon(
            obscure
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
            size: 20,
          ),
        ),
      ),
    );
  }
}

/// Convenience used by Settings: opens the sheet and reports the result.
Future<void> openChangePassword(BuildContext context) async {
  final bool changed = await ChangePasswordSheet.show(context);
  if (!context.mounted || !changed) return;
  AppFeedback.success(context, 'Password updated.');
}
