import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_spacing.dart';
import '../../widgets/common/brand_mark.dart';
import '../../widgets/common/surface_card.dart';

/// Shared chrome for the signed-out screens.
///
/// Keeps the keyboard from covering inputs and gives every auth screen the
/// same composition — the brand mark, a serif headline, and the form on a
/// glass pane over a soft blue-gray light — so signing in, signing up and checking
/// email feel like one flow rather than three pages.
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
    final bool isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: showBack
          ? AppBar(
              leading: const BackButton(),
              backgroundColor: Colors.transparent,
            )
          : null,
      body: Stack(
        children: <Widget>[
          // The one decorative element on the signed-out screens: a soft
          // accent light behind the header, painted as a gradient (no image, no
          // blur), fading into the page before the form begins.
          Positioned(
            top: -160,
            left: -80,
            right: -80,
            child: IgnorePointer(
              child: Container(
                height: 420,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: <Color>[
                      AppColors.accent.withOpacity(isDark ? 0.18 : 0.22),
                      AppColors.accent.withOpacity(0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                return SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.xl,
                    showBack ? AppSpacing.appBarHeight : AppSpacing.sm,
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
                          if (!showBack)
                            const SizedBox(height: AppSpacing.xxxl),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: BrandMark(size: 52, icon: icon),
                          ),
                          const SizedBox(height: AppSpacing.xl),
                          Text(title, style: theme.textTheme.displaySmall),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            subtitle,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xl),
                          SurfaceCard(
                            radius: AppSpacing.radiusXl,
                            padding: const EdgeInsets.all(AppSpacing.lg + 2),
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
        ],
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
