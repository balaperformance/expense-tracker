import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_glass.dart';
import '../../core/theme/app_spacing.dart';
import '../../models/notification_item.dart';
import '../../providers/notification_inbox_provider.dart';
import '../../providers/notification_provider.dart';
import '../../services/schema_capabilities.dart';
import 'app_buttons.dart';
import 'app_feedback.dart';
import 'app_sheet.dart';
import 'money_text.dart';
import 'state_views.dart';
import 'surface_card.dart';

/// The header bell: the unread count on a round glass button, and the
/// notification history in the app's sheet — the web app's
/// `NotificationBell`. Hidden until migration 010 exists.
///
/// Opening an item marks it read and goes where its notification goes when
/// tapped in the shade (the shell's one route, via [NotificationProvider]).
class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key, this.glass = true});

  /// The dashboard header's round glass disc; false for a plain app-bar icon.
  final bool glass;

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  @override
  void initState() {
    super.initState();
    // After the first frame: activating may notify, which a build must not.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && SchemaCapabilities.notificationInbox) {
        context.read<NotificationInboxProvider>().activate();
      }
    });
  }

  Future<void> _open() async {
    final NotificationInboxProvider inbox =
        context.read<NotificationInboxProvider>();
    inbox.activate();
    unawaited(inbox.refresh());
    final NotificationItem? chosen = await showAppSheet<NotificationItem>(
      context: context,
      builder: (_) => const NotificationInboxSheet(),
    );
    final String? path = chosen?.path;
    if (path != null && mounted) {
      context.read<NotificationProvider>().openPath(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!SchemaCapabilities.notificationInbox) return const SizedBox.shrink();
    final int unread = context
        .select<NotificationInboxProvider, int>((NotificationInboxProvider p) => p.unreadCount);
    final String? badge = NotificationItem.badgeLabel(unread);
    final String label =
        unread > 0 ? 'Notifications, $unread unread' : 'Notifications';

    final Widget icon = Icon(
      unread > 0 ? Icons.notifications_rounded : Icons.notifications_none_rounded,
    );
    Widget button = widget.glass
        ? GlassSurface(
            radius: 20,
            child: SizedBox(
              width: 40,
              height: 40,
              child: IconButton(
                tooltip: 'Notifications',
                onPressed: _open,
                iconSize: AppSpacing.iconMd,
                padding: EdgeInsets.zero,
                icon: icon,
              ),
            ),
          )
        : IconButton(tooltip: 'Notifications', onPressed: _open, icon: icon);

    if (badge != null) {
      // Outside the disc, which clips to its circle.
      button = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          button,
          Positioned(
            top: widget.glass ? -3 : 4,
            right: widget.glass ? -3 : 4,
            child: IgnorePointer(child: Badge(label: Text(badge))),
          ),
        ],
      );
    }

    return Semantics(
      container: true,
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: _open,
      child: button,
    );
  }
}

/// The notification history, in the app's sheet. Pops with the chosen item
/// when it has somewhere to go.
class NotificationInboxSheet extends StatefulWidget {
  const NotificationInboxSheet({super.key});

  @override
  State<NotificationInboxSheet> createState() => _NotificationInboxSheetState();
}

class _NotificationInboxSheetState extends State<NotificationInboxSheet> {
  /// A failed mark or clear, said here: a snackbar would sit under the sheet.
  String? _failure;

  void _report(String? failure) {
    if (!mounted) return;
    setState(() => _failure = failure);
  }

  void _choose(NotificationItem item) {
    final NotificationInboxProvider inbox =
        context.read<NotificationInboxProvider>();
    // Captured now: the sheet may be gone when the save answers, and then
    // the page it opened says so instead.
    final BuildContext pageContext = Navigator.of(context).context;
    if (!item.read) {
      unawaited(inbox.markRead(item.key).then((String? failure) {
        if (failure == null) return;
        if (mounted) {
          _report(failure);
        } else if (pageContext.mounted) {
          AppFeedback.error(pageContext, failure);
        }
      }));
    }
    if (item.path == null) return;
    Navigator.of(context).pop(item);
  }

  Future<void> _markAll() async {
    _report(null);
    _report(await context.read<NotificationInboxProvider>().markAllRead());
  }

  Future<void> _clearRead(NotificationInboxProvider inbox) async {
    final int count = inbox.readCount;
    final int unread = inbox.unreadCount;
    final bool ok = await AppFeedback.confirm(
      context,
      title: 'Clear $count read ${count == 1 ? 'notification' : 'notifications'}?',
      message: unread > 0
          ? 'They leave this list. Your $unread unread '
              '${unread == 1 ? 'notification stays' : 'notifications stay'}.'
          : 'They leave this list. New notifications will still arrive here.',
      confirmLabel: 'Clear',
    );
    if (!ok || !mounted) return;
    _report(null);
    _report(await inbox.clearRead());
  }

  @override
  Widget build(BuildContext context) {
    final NotificationInboxProvider inbox =
        context.watch<NotificationInboxProvider>();
    final List<NotificationItem> items = inbox.items;
    final int unread = inbox.unreadCount;
    final String? subtitle = unread > 0
        ? '$unread unread'
        : (items.isNotEmpty ? 'You’re all caught up' : null);

    final List<Widget> body;
    if (!inbox.loaded && !inbox.hasError) {
      body = const <Widget>[_InboxSkeleton()];
    } else if (inbox.hasError && items.isEmpty) {
      body = <Widget>[
        ErrorView(
          message: 'Notifications could not be loaded.',
          onRetry: inbox.refresh,
          compact: true,
        ),
      ];
    } else if (items.isEmpty) {
      body = const <Widget>[
        EmptyState(
          icon: Icons.notifications_none_rounded,
          title: 'You’re all caught up',
          message: 'Daily reminders, spending summaries, low balance alerts '
              'and card due dates will appear here.',
          compact: true,
        ),
      ];
    } else {
      body = <Widget>[
        CardList(
          children: <Widget>[
            for (final NotificationItem item in items)
              NotificationRow(item: item, onTap: () => _choose(item)),
          ],
        ),
      ];
    }

    return AppSheet(
      title: 'Notifications',
      subtitle: subtitle,
      action: unread > 0
          ? AppButton(
              label: 'Mark all as read',
              variant: AppButtonVariant.ghost,
              size: AppButtonSize.small,
              onPressed: _markAll,
            )
          : null,
      footer: inbox.canClear && inbox.readCount > 0 && items.isNotEmpty
          ? Center(
              child: AppButton(
                label: 'Clear ${inbox.readCount} read',
                variant: AppButtonVariant.ghost,
                size: AppButtonSize.small,
                icon: Icons.delete_outline_rounded,
                onPressed: () => _clearRead(inbox),
              ),
            )
          : null,
      children: <Widget>[
        if (_failure != null) ...<Widget>[
          InlineError(message: _failure!),
          const SizedBox(height: AppSpacing.md),
        ],
        ...body,
      ],
    );
  }
}

/// One notification: its kind's icon, title, text and when it was sent, with
/// a dot while unread.
class NotificationRow extends StatelessWidget {
  const NotificationRow({super.key, required this.item, required this.onTap});

  final NotificationItem item;
  final VoidCallback onTap;

  (IconData, Color) _style(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return switch (item.kind) {
      'daily' => (Icons.schedule_rounded, scheme.primary),
      'summary' => (Icons.insights_rounded, scheme.secondary),
      'lowBalance' => (Icons.account_balance_outlined, ToneColors.warning(context)),
      'cardDue' => (Icons.credit_card_rounded, ToneColors.expense(context)),
      _ => (Icons.notifications_none_rounded, scheme.onSurfaceVariant),
    };
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final (IconData icon, Color tone) = _style(context);

    return Semantics(
      button: true,
      label: '${item.read ? '' : 'Unread. '}${item.title}. ${item.body}'.trim(),
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: Ink(
            color: item.read
                ? null
                : theme.colorScheme.primary.withOpacity(0.04),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: 11,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                IconWell(icon: icon, tone: tone),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight:
                                    item.read ? FontWeight.w500 : FontWeight.w600,
                              ),
                            ),
                          ),
                          if (!item.read) ...<Widget>[
                            const SizedBox(width: AppSpacing.sm),
                            Container(
                              key: const ValueKey<String>('unread-dot'),
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (item.body.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(item.body, style: theme.textTheme.bodySmall),
                      ],
                      const SizedBox(height: AppSpacing.xxs + 2),
                      Text(
                        NotificationItem.sentLabel(item.sentAt),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A few rows shaped like the list, while it is first read.
class _InboxSkeleton extends StatelessWidget {
  const _InboxSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        for (int i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Row(
              children: <Widget>[
                const Skeleton(
                  height: AppSpacing.avatar,
                  width: AppSpacing.avatar,
                  radius: AppSpacing.radiusMd,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Skeleton(width: i.isEven ? 170 : 130),
                      const SizedBox(height: AppSpacing.sm),
                      const Skeleton(height: 10, width: 90),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
