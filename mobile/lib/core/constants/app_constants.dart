/// App-wide constants. Keep free of Flutter imports so it stays testable.
library;

class AppConstants {
  const AppConstants._();

  static const String appName = 'Expense Tracker';
  static const String appVersion = '1.0.0';

  /// Page size for paginated transaction lists.
  static const int pageSize = 20;

  /// Upper bound when aggregating a single month in memory.
  static const int monthlyAggregateLimit = 2000;

  /// Upper bound on the rows one export may pull.
  ///
  /// An export range can be a whole year, so the cap is higher than the
  /// monthly one — but it is still a cap: a runaway query would build a
  /// multi-megabyte PDF on the phone's own heap. The export screen says so
  /// when a report hits the limit rather than silently truncating.
  static const int exportRowLimit = 5000;

  static const String defaultCurrencyCode = 'INR';

  /// Currencies offered in Settings. Symbol is used for display only.
  static const Map<String, String> supportedCurrencies = <String, String>{
    'INR': '₹',
    'USD': r'$',
    'EUR': '€',
    'GBP': '£',
    'AUD': r'$',
    'CAD': r'$',
    'SGD': r'$',
    'AED': 'د.إ',
    'JPY': '¥',
  };

  static String symbolFor(String currencyCode) =>
      supportedCurrencies[currencyCode] ?? currencyCode;
}
