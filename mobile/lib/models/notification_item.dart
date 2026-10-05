import 'package:intl/intl.dart';

import '../core/utils/formatters.dart';

/// One entry in the in-app notification history: a notification the
/// push-notify sender produced (`notification_log`, migration 010), read or
/// unread. The port of the web app's `domain/notifications/inbox.ts`.
class NotificationItem {
  const NotificationItem({
    required this.key,
    required this.kind,
    required this.title,
    required this.body,
    required this.path,
    required this.sentAt,
    required this.read,
  });

  /// The sender's event key: unique per user.
  final String key;

  /// 'daily', 'summary', 'lowBalance', 'cardDue' — or a kind added later,
  /// which still shows under a generic label.
  final String kind;
  final String title;
  final String body;

  /// A path inside the app, or null when there is nowhere to go.
  final String? path;

  /// In the phone's own time.
  final DateTime sentAt;
  final bool read;

  /// The four kinds the sender knows today.
  static const Map<String, String> kindLabels = <String, String>{
    'daily': 'Daily expense reminder',
    'summary': 'Spending summary',
    'lowBalance': 'Low balance',
    'cardDue': 'Credit card due',
  };

  /// The sender's push title is the app's name on every message; the kind
  /// says more in a list.
  static const String genericPushTitle = 'Expense Tracker';

  static String kindLabel(String kind) => kindLabels[kind] ?? 'Notification';

  /// A path inside this app, or null. Anything else a row might hold is
  /// ignored, as the Android side ignores it for a tapped push.
  static String? safePath(String? value) {
    if (value == null ||
        !value.startsWith('/') ||
        value.startsWith('//') ||
        value.length > 200) {
      return null;
    }
    return value;
  }

  /// A malformed row is null rather than an error.
  static NotificationItem? fromRow(Map<String, dynamic> row) {
    final String key = _text(row['event_key']) ?? '';
    final String? sent = _text(row['sent_at']);
    final DateTime? sentAt = sent == null ? null : DateTime.tryParse(sent);
    if (key.isEmpty || sentAt == null) return null;
    final String kind = _text(row['kind']) ?? '';
    final String? title = _text(row['title'])?.trim();
    return NotificationItem(
      key: key,
      kind: kind,
      // A message names itself only when it says more than the app's name;
      // rows from before 010 have no text at all.
      title: title != null && title.isNotEmpty && title != genericPushTitle
          ? title
          : kindLabel(kind),
      body: _text(row['body'])?.trim() ?? '',
      path: safePath(_text(row['url'])),
      sentAt: sentAt.toLocal(),
      read: row['read_at'] != null,
    );
  }

  /// Newest first; a malformed row is dropped rather than breaking the list.
  static List<NotificationItem> fromRows(Iterable<Map<String, dynamic>> rows) {
    final List<NotificationItem> items = <NotificationItem>[
      for (final Map<String, dynamic> row in rows)
        if (fromRow(row) case final NotificationItem item) item,
    ];
    items.sort(newestFirst);
    return items;
  }

  static int newestFirst(NotificationItem a, NotificationItem b) =>
      b.sentAt.compareTo(a.sentAt);

  static String? _text(Object? value) => value is String ? value : null;

  NotificationItem copyWith({bool? read}) => NotificationItem(
        key: key,
        kind: kind,
        title: title,
        body: body,
        path: path,
        sentAt: sentAt,
        read: read ?? this.read,
      );

  static int unreadCount(Iterable<NotificationItem> items) =>
      items.where((NotificationItem item) => !item.read).length;

  /// Marks [keys] (or every item) read without reordering — the optimistic
  /// view of a mark-read.
  static List<NotificationItem> withRead(
    Iterable<NotificationItem> items, [
    Set<String>? keys,
  ]) =>
      <NotificationItem>[
        for (final NotificationItem item in items)
          item.read || (keys != null && !keys.contains(item.key))
              ? item
              : item.copyWith(read: true),
      ];

  /// The bell's badge: the count, capped so it fits; null for none.
  static String? badgeLabel(int count) =>
      count <= 0 ? null : (count > 99 ? '99+' : '$count');

  static final DateFormat _weekday = DateFormat('EEEE');

  /// "Today · 10:00 PM", "Yesterday · 8:00 PM", "Monday · 9:00 AM",
  /// "12 Mar · 9:00 AM" — in the phone's own time.
  static String sentLabel(DateTime sentAt, {DateTime? now}) {
    final DateTime local = sentAt.toLocal();
    final DateTime today = now ?? DateTime.now();
    final DateTime day = DateTime(local.year, local.month, local.day);
    final DateTime current = DateTime(today.year, today.month, today.day);
    // Rounded, so a daylight-saving change never makes yesterday today.
    final int diff = (current.difference(day).inHours / 24).round();
    final String dayLabel = switch (diff) {
      0 => 'Today',
      1 => 'Yesterday',
      > 1 && < 7 => _weekday.format(local),
      _ => day.year == current.year
          ? Formatters.dayMonth(local)
          : Formatters.dayMonthYear(local),
    };
    final String hhmm = '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    return '$dayLabel · ${Formatters.clockTime(hhmm)}';
  }
}
