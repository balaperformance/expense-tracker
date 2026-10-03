import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_spacing.dart';
import '../../models/expense_prefill.dart';
import '../../services/receipt/receipt_result.dart';
import '../../services/receipt/receipt_scanner_service.dart';
import '../../widgets/common/app_buttons.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/app_sheet.dart';
import '../../widgets/common/money_text.dart';
import '../../widgets/common/surface_card.dart';
import 'receipt_review_screen.dart';

/// Runs the whole scan: pick a source, read the image, review the result.
///
/// Returns the values to open Add Expense with, or null if the user backed
/// out or nothing could be read. The caller does not need to know which
/// engine ran or how it failed — every failure has already been explained to
/// the user by the time this returns null.
Future<ExpensePrefill?> startReceiptScan(BuildContext context) async {
  final ReceiptScannerService scanner = context.read<ReceiptScannerService>();

  if (!scanner.isAvailable) {
    AppFeedback.info(
      context,
      'Receipt scanning needs a camera, so it is only available on your '
      'phone.',
    );
    return null;
  }

  final ReceiptImageSource? source = await _pickSource(context);
  if (source == null || !context.mounted) return null;

  final ReceiptScanOutcome outcome =
      await _runWithProgress(context, scanner, source);

  if (!context.mounted) return null;

  switch (outcome) {
    case ReceiptScanFailed(problem: final ReceiptScanProblem problem):
      // Backing out of the camera is a decision, not an error, so it passes
      // without a message.
      if (problem != ReceiptScanProblem.cancelled) {
        AppFeedback.error(context, problem.message);
      }
      return null;

    case ReceiptScanned(result: final ReceiptResult result):
      return Navigator.of(context).push<ExpensePrefill>(
        MaterialPageRoute<ExpensePrefill>(
          builder: (_) => ReceiptReviewScreen(result: result),
        ),
      );
  }
}

/// Camera or gallery.
Future<ReceiptImageSource?> _pickSource(BuildContext context) {
  return showAppSheet<ReceiptImageSource>(
    context: context,
    builder: (BuildContext sheetContext) {
      final ThemeData theme = Theme.of(sheetContext);

      return AppSheet(
        title: 'Scan receipt',
        subtitle: 'Read the amount, merchant and date from a photo',
        children: <Widget>[
          CardList(
            dividerIndent: AppSpacing.rowDividerIndent,
            children: <Widget>[
              for (final ReceiptImageSource source in ReceiptImageSource.values)
                AppListRow(
                  leading: IconWell(
                    icon: source == ReceiptImageSource.camera
                        ? Icons.photo_camera_outlined
                        : Icons.photo_library_outlined,
                    tone: theme.colorScheme.primary,
                  ),
                  title: source.label,
                  subtitle: source.description,
                  showChevron: true,
                  onTap: () => Navigator.of(sheetContext).pop(source),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const AppNotice(
            icon: Icons.lock_outline_rounded,
            message: 'The receipt is read on this device and the photo is not '
                'saved or uploaded anywhere.',
          ),
        ],
      );
    },
  );
}

/// Shows a modal progress card while the picker and recogniser work.
///
/// Blocking is correct here: the scan takes a second or two and its result is
/// the next screen, so there is nothing useful to do underneath. The card
/// cannot be dismissed, because cancelling mid-recognition would leave the
/// native recogniser running with nowhere to deliver its result.
///
/// The card is raised before the picker, not after. The picker's own
/// full-screen activity covers it while the user frames the shot, and it is
/// already in place for the recognition that follows — which avoids the
/// flicker of putting a spinner up at the exact moment the camera closes.
Future<ReceiptScanOutcome> _runWithProgress(
  BuildContext context,
  ReceiptScannerService scanner,
  ReceiptImageSource source,
) async {
  // Captured so the dialog is dismissed by its own route rather than by
  // popping whatever happens to be on top of the navigator.
  BuildContext? dialogContext;

  unawaited(
    showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (BuildContext ctx) {
        dialogContext = ctx;
        return const _ScanningDialog();
      },
    ),
  );

  try {
    return await scanner.scan(source);
  } finally {
    final BuildContext? open = dialogContext;
    if (open != null && open.mounted) Navigator.of(open).pop();
  }
}

class _ScanningDialog extends StatelessWidget {
  const _ScanningDialog();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return PopScope(
      canPop: false,
      child: Dialog(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('Reading the receipt', style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'This happens on your device.',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Entry point row used on the Add Expense screen.
class ScanReceiptCard extends StatelessWidget {
  const ScanReceiptCard({super.key, required this.onTap, this.busy = false});

  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color accent = theme.colorScheme.primary;

    return SurfaceCard(
      onTap: busy ? null : onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: AppSpacing.avatarSm,
            height: AppSpacing.avatarSm,
            decoration: BoxDecoration(
              color: ToneColors.wash(context, accent),
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            ),
            child: Icon(
              Icons.document_scanner_outlined,
              size: AppSpacing.iconMd,
              color: accent,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('Scan a receipt', style: theme.textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  'Fill this form from a photo',
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          AppButton(
            label: 'Scan',
            size: AppButtonSize.small,
            variant: AppButtonVariant.tonal,
            icon: Icons.photo_camera_outlined,
            onPressed: busy ? null : onTap,
          ),
        ],
      ),
    );
  }
}
