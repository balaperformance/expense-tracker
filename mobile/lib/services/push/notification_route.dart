/// Where a tapped notification takes the user — the same paths the web app
/// opens (push-notify core/run.ts messages): `/expenses/new`, `/reports`,
/// `/accounts/<id>`, `/cards/<id>`.
enum NotificationDestination { addExpense, reports, account, card, home }

class NotificationRoute {
  const NotificationRoute(this.destination, [this.id]);

  final NotificationDestination destination;

  /// The account or card, for those destinations.
  final String? id;

  static final RegExp _id = RegExp(r'^[A-Za-z0-9-]{1,64}$');

  /// Anything not recognised — or not a path inside the app — opens the home screen.
  static NotificationRoute parse(String? path) {
    if (path == null || !path.startsWith('/') || path.startsWith('//')) {
      return const NotificationRoute(NotificationDestination.home);
    }
    final List<String> parts =
        path.split('?').first.split('/').where((String p) => p.isNotEmpty).toList();
    if (parts.length == 2 && parts[0] == 'expenses' && parts[1] == 'new') {
      return const NotificationRoute(NotificationDestination.addExpense);
    }
    if (parts.length == 1 && parts[0] == 'reports') {
      return const NotificationRoute(NotificationDestination.reports);
    }
    if (parts.length == 2 && _id.hasMatch(parts[1])) {
      if (parts[0] == 'accounts') {
        return NotificationRoute(NotificationDestination.account, parts[1]);
      }
      if (parts[0] == 'cards') {
        return NotificationRoute(NotificationDestination.card, parts[1]);
      }
    }
    return const NotificationRoute(NotificationDestination.home);
  }
}
