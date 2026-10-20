/// Small text helpers shared by the models and forms.
library;

/// The text trimmed, or null when nothing is left — how optional text is stored.
String? blankToNull(String? value) {
  final String? trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}
