import 'package:flutter/material.dart';

import '../../core/theme/app_motion.dart';
import '../../core/theme/app_spacing.dart';
import '../../widgets/common/surface_card.dart';

/// Shared chrome for the signed-out screens.
///
/// Keeps the keyboard from covering inputs and gives every auth screen the
/// same header rhythm, so signing in, signing up and resetting a password
/// feel like one flow rather than three pages.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
    this.showBack = false,
    this.icon = Icons.account_balance_wallet_rounded,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final bool showBack;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: showBack
          ? AppBar(
              leading: const BackButton(),
              backgroundColor: Colors.transparent,
            )
          : null,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl,
                AppSpacing.sm,
                AppSpacing.xl,
                AppSpacing.xl,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - AppSpacing.xl * 2,
                ),
                child: AppFadeIn(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (!showBack) const SizedBox(height: AppSpacing.xl),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            borderRadius:
                                BorderRadius.circular(AppSpacing.radiusMd + 2),
                          ),
                          child: Icon(
                            icon,
                            color: theme.colorScheme.onPrimary,
                            size: 22,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(title, style: theme.textTheme.headlineLarge),
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      // The form sits on a glass pane rather than bare on the
                      // page, which is what gives the signed-out screens the
                      // same layered material as everything behind the login.
                      SurfaceCard(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: children,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Text field preset for auth forms.
///
/// Auth is the one place a floating label is right: the fields are few, the
/// labels are short, and autofill needs a stable label to attach to.
class AuthField extends StatelessWidget {
  const AuthField({
    super.key,
    required this.controller,
    required this.label,
    required this.icon,
    this.validator,
    this.keyboardType,
    this.obscure = false,
    this.suffix,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
    this.autofillHints,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final String? Function(String?)? validator;
  final TextInputType? keyboardType;
  final bool obscure;
  final Widget? suffix;
  final TextInputAction textInputAction;
  final VoidCallback? onSubmitted;
  final List<String>? autofillHints;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      validator: validator,
      keyboardType: keyboardType,
      obscureText: obscure,
      enabled: enabled,
      textInputAction: textInputAction,
      autofillHints: autofillHints,
      onFieldSubmitted: (_) => onSubmitted?.call(),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: AppSpacing.iconMd),
        suffixIcon: suffix,
      ),
    );
  }
}
