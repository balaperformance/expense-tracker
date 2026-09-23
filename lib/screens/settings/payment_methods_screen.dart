import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/utils/validators.dart';
import '../../models/payment_method.dart';
import '../../providers/expense_provider.dart';
import '../../providers/payment_method_provider.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/state_views.dart';
import '../../widgets/common/surface_card.dart';

class PaymentMethodsScreen extends StatelessWidget {
  const PaymentMethodsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final PaymentMethodProvider provider =
        context.watch<PaymentMethodProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Payment methods')),
      floatingActionButton: AppFab(
        heroTag: 'payment_fab',
        onPressed: () => _add(context),
        label: 'New',
      ),
      body: _buildBody(context, provider),
    );
  }

  Widget _buildBody(BuildContext context, PaymentMethodProvider provider) {
    if (provider.isInitialLoad) return const ListSkeleton(rows: 5);

    if (provider.methods.isEmpty) {
      return ScrollableCentered(
        child: EmptyState(
          icon: Icons.credit_card_outlined,
          title: 'No payment methods',
          message: 'Add the ways you pay so you can filter spending by them.',
          actionLabel: 'Add method',
          onAction: () => _add(context),
        ),
      );
    }

    // One card holding every method, rather than a card each: these are short
    // single-line records and a card per row wastes most of the screen.
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.md,
        AppSpacing.page,
        AppSpacing.bottomListPaddingPage,
      ),
      children: <Widget>[
        SectionHeader(
          title: 'Methods',
          caption: '${provider.methods.length}',
        ),
        CardList(
          dividerIndent: AppSpacing.avatarSm + AppSpacing.md + AppSpacing.md,
          children: <Widget>[
            for (final PaymentMethod method in provider.methods)
              AppListRow(
                leading: IconWell(
                  icon: _iconFor(method.name),
                  tone: Theme.of(context).colorScheme.primary,
                  size: AppSpacing.avatarSm,
                ),
                title: method.name,
                dense: true,
                trailing: IconButton(
                  tooltip: 'Delete',
                  onPressed: () => _confirmDelete(context, method),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    size: AppSpacing.iconMd,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        const AppNotice(
          message: 'Payment methods label how you paid. To track a real '
              'balance, use Bank accounts instead.',
        ),
      ],
    );
  }

  /// The table stores only a name, so the icon is inferred for display.
  static IconData _iconFor(String name) {
    final String value = name.toLowerCase();
    if (value.contains('cash')) return Icons.payments_outlined;
    if (value.contains('upi')) return Icons.qr_code_rounded;
    if (value.contains('credit')) return Icons.credit_card_rounded;
    if (value.contains('debit')) return Icons.credit_card_outlined;
    if (value.contains('bank') || value.contains('net')) {
      return Icons.account_balance_outlined;
    }
    if (value.contains('wallet')) return Icons.account_balance_wallet_outlined;
    return Icons.payment_rounded;
  }

  Future<void> _add(BuildContext context) async {
    final TextEditingController controller = TextEditingController();
    final GlobalKey<FormState> formKey = GlobalKey<FormState>();

    final String? name = await showAppDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('New payment method'),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              validator: (String? v) => Validators.required(v, 'Name'),
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. HDFC Credit Card',
              ),
            ),
          ),
          actions: <Widget>[
            AppButtonRow(
              expand: false,
              onCancel: () => Navigator.of(dialogContext).pop(),
              confirmLabel: 'Add',
              onConfirm: () {
                if (formKey.currentState!.validate()) {
                  Navigator.of(dialogContext).pop(controller.text);
                }
              },
            ),
          ],
        );
      },
    );

    controller.dispose();

    if (name == null || !context.mounted) return;

    final PaymentMethodProvider provider =
        context.read<PaymentMethodProvider>();
    final bool ok = await provider.create(name);

    if (!context.mounted) return;

    if (ok) {
      AppFeedback.success(context, 'Payment method added');
    } else {
      AppFeedback.error(
        context,
        provider.errorMessage ?? 'Could not add the payment method.',
      );
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    PaymentMethod method,
  ) async {
    final bool confirmed = await AppFeedback.confirm(
      context,
      title: 'Delete "${method.name}"?',
      message: 'Expenses paid with it keep their amount but lose the payment '
          'method. This cannot be undone.',
    );

    if (!confirmed || !context.mounted) return;

    final PaymentMethodProvider provider =
        context.read<PaymentMethodProvider>();
    final bool ok = await provider.delete(method.id);

    if (!context.mounted) return;

    if (ok) {
      AppFeedback.success(context, 'Payment method deleted');
      context.read<ExpenseProvider>().refresh();
    } else {
      AppFeedback.error(
        context,
        provider.errorMessage ?? 'Could not delete the payment method.',
      );
    }
  }
}
