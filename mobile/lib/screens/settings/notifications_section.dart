import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/theme/app_spacing.dart';
import '../../models/notification_prefs.dart';
import '../../providers/notification_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/common/app_feedback.dart';
import '../../widgets/common/surface_card.dart';

/// The fixed threshold the server watches (push-notify core/run.ts
/// LOW_BALANCE_CENTS): no configuration, as on the web.
const int _lowBalanceThreshold = 500;

/// Settings → Notifications: whether this phone receives push notifications,
/// and the four on/off switches shared with the web app. Nothing else is
/// configurable — the times, the threshold and the days are fixed. Hidden
/// until migrations 008 and 009 exist.
class NotificationsSection extends StatelessWidget {
  const NotificationsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final NotificationProvider notifications =
        context.watch<NotificationProvider>();
    if (!notifications.available) return const SizedBox.shrink();
    final String symbol = AppConstants.symbolFor(
      context.watch<SettingsProvider>().currency,
    );
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader(title: 'Notifications'),
        CardList(
          dividerIndent: AppSpacing.avatarSm + AppSpacing.md + AppSpacing.md,
          children: <Widget>[
            _deviceRow(context, notifications, theme),
            for (final NotificationPref pref in NotificationPref.values)
              AppListRow(
                leading: IconWell(
                  icon: _icon(pref),
                  tone: theme.colorScheme.primary,
                  size: AppSpacing.avatarSm,
                ),
                title: pref.title,
                subtitle: _subtitle(pref, symbol),
                trailing: Switch.adaptive(
                  value: notifications.prefs.valueOf(pref),
                  onChanged: notifications.prefsLoaded
                      ? (bool value) => _setPref(context, notifications, pref, value)
                      : null,
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.section),
      ],
    );
  }

  static IconData _icon(NotificationPref pref) => switch (pref) {
        NotificationPref.daily => Icons.schedule_rounded,
        NotificationPref.summary => Icons.insights_outlined,
        NotificationPref.lowBalance => Icons.account_balance_outlined,
        NotificationPref.cardDue => Icons.credit_card_rounded,
      };

  static String _subtitle(NotificationPref pref, String symbol) => switch (pref) {
        NotificationPref.daily => "Today's spending, around 10 PM",
        NotificationPref.summary => 'On the 16th and the last day of the month',
        NotificationPref.lowBalance =>
          'When an account is below $symbol$_lowBalanceThreshold',
        NotificationPref.cardDue => 'The day before a bill is due',
      };

  Widget _deviceRow(
    BuildContext context,
    NotificationProvider notifications,
    ThemeData theme,
  ) {
    Widget row(String title, String subtitle, {Widget? trailing}) => AppListRow(
          leading: IconWell(
            icon: Icons.notifications_outlined,
            tone: theme.colorScheme.primary,
            size: AppSpacing.avatarSm,
          ),
          title: title,
          subtitle: subtitle,
          trailing: trailing,
        );

    switch (notifications.support) {
      case PushSupport.checking:
        return row('Notifications', 'Checking this phone…');
      case PushSupport.unsupported:
        return row(
          'Not available here',
          'Notifications are sent to the Android app and the web app.',
        );
      case PushSupport.notConfigured:
        return row(
          'Not set up yet',
          'This build of the app has no Firebase project yet.',
        );
      case PushSupport.ready:
        break;
    }
    if (notifications.blockedHere ||
        (notifications.permission == 'denied' && !notifications.enabledHere)) {
      return row(
        'Blocked on this phone',
        'Allow notifications for this app in Android settings.',
        trailing: TextButton(
          onPressed: notifications.openSettings,
          child: const Text('Open settings'),
        ),
      );
    }
    if (notifications.enabledHere) {
      return row(
        'On for this phone',
        'Sent by the server, even when the app is closed',
        trailing: TextButton(
          onPressed: notifications.busy ? null : () => _disable(context, notifications),
          child: const Text('Turn off'),
        ),
      );
    }
    return row(
      'Turn on notifications',
      'Reminders and updates on this phone',
      trailing: TextButton(
        onPressed: notifications.busy ? null : () => _enable(context, notifications),
        child: Text(notifications.busy ? 'Turning on…' : 'Turn on'),
      ),
    );
  }

  Future<void> _enable(BuildContext context, NotificationProvider notifications) async {
    try {
      final EnableResult result = await notifications.enable();
      if (!context.mounted) return;
      switch (result) {
        case EnableResult.enabled:
          AppFeedback.success(context, 'Notifications are on for this phone');
        case EnableResult.denied:
          AppFeedback.error(context,
              'Notifications are blocked. Allow them for this app in Android settings.');
        case EnableResult.dismissed:
          break;
        case EnableResult.unavailable:
          AppFeedback.error(context, 'Notifications are not available in this build of the app.');
      }
    } catch (error) {
      if (!context.mounted) return;
      AppFeedback.error(context,
          'Could not turn on notifications. ${ErrorMapper.map(error).message}');
    }
  }

  Future<void> _disable(BuildContext context, NotificationProvider notifications) async {
    try {
      await notifications.disable();
      if (!context.mounted) return;
      AppFeedback.success(context, 'Notifications are off for this phone');
    } catch (error) {
      if (!context.mounted) return;
      // Already off here: the phone no longer shows them, whatever the server says.
      AppFeedback.error(context,
          'Turned off here, but the server could not be told. ${ErrorMapper.map(error).message}');
    }
  }

  Future<void> _setPref(
    BuildContext context,
    NotificationProvider notifications,
    NotificationPref pref,
    bool value,
  ) async {
    final bool ok = await notifications.setPref(pref, value);
    if (!ok && context.mounted) {
      AppFeedback.error(
        context,
        notifications.errorMessage ?? 'Could not save that setting.',
      );
    }
  }
}
