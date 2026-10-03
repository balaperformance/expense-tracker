/// The four push-notification switches (`notification_preferences`,
/// migration 008) — shared with the web app: turning one off on either turns
/// it off for every device.
enum NotificationPref { daily, summary, lowBalance, cardDue }

extension NotificationPrefInfo on NotificationPref {
  /// The table's column.
  String get column => switch (this) {
        NotificationPref.daily => 'daily_reminder',
        NotificationPref.summary => 'spending_summary',
        NotificationPref.lowBalance => 'low_balance',
        NotificationPref.cardDue => 'card_due',
      };

  String get title => switch (this) {
        NotificationPref.daily => 'Daily expense reminder',
        NotificationPref.summary => 'Spending summary',
        NotificationPref.lowBalance => 'Low bank balance',
        NotificationPref.cardDue => 'Credit card due reminder',
      };
}

class NotificationPrefs {
  const NotificationPrefs({
    this.daily = true,
    this.summary = true,
    this.lowBalance = true,
    this.cardDue = true,
  });

  /// All on: nothing is sent to a device until it is turned on, so this
  /// changes nothing for anyone until they opt in — as on the web.
  static const NotificationPrefs defaults = NotificationPrefs();

  final bool daily;
  final bool summary;
  final bool lowBalance;
  final bool cardDue;

  /// A missing value reads as on, as the server reads it.
  factory NotificationPrefs.fromMap(Map<String, dynamic>? map) {
    if (map == null) return defaults;
    bool on(NotificationPref p) => map[p.column] != false;
    return NotificationPrefs(
      daily: on(NotificationPref.daily),
      summary: on(NotificationPref.summary),
      lowBalance: on(NotificationPref.lowBalance),
      cardDue: on(NotificationPref.cardDue),
    );
  }

  bool valueOf(NotificationPref pref) => switch (pref) {
        NotificationPref.daily => daily,
        NotificationPref.summary => summary,
        NotificationPref.lowBalance => lowBalance,
        NotificationPref.cardDue => cardDue,
      };

  NotificationPrefs withValue(NotificationPref pref, bool value) =>
      NotificationPrefs(
        daily: pref == NotificationPref.daily ? value : daily,
        summary: pref == NotificationPref.summary ? value : summary,
        lowBalance: pref == NotificationPref.lowBalance ? value : lowBalance,
        cardDue: pref == NotificationPref.cardDue ? value : cardDue,
      );
}
