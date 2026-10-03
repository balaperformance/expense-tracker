# expense_tracker

A new Flutter project.

## Bank statement import

Statements are read on the phone by the web app's own parsers, not a Dart
copy: `assets/statement_engine/engine.js` is generated from `../ui/src/engine/`
with `npm run build:engine` (in `ui/`) and runs in a hidden WebView hosted by
`MainActivity.kt` (method channel `expense_tracker/statement_engine`). After
changing statement parsing in `ui/`, rebuild the bundle, then the APK.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
