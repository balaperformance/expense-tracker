/// Money arithmetic. Amounts are compared and summed in whole cents (paise),
/// so thousands of decimal amounts can never drift by a fraction.
library;

/// Whole cents, so comparisons never trip over floating point.
int toCents(double value) => (value * 100).round();
