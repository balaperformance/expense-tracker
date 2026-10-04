# expense_tracker

The Android app (Flutter). The web app in `../ui` shares its Supabase backend,
its statement parsers and its push-notification sender.

## Bank statement import

Statements are read on the phone by the web app's own parsers, not a Dart
copy: `assets/statement_engine/engine.js` is generated from `../ui/src/engine/`
with `npm run build:engine` (in `ui/`) and runs in a hidden WebView hosted by
`MainActivity.kt` (method channel `expense_tracker/statement_engine`). After
changing statement parsing in `ui/`, rebuild the bundle, then the APK.

### Paytm UPI statements

A Paytm UPI statement PDF covers several of the user's accounts. Each payment
goes to the account its "Your Account" column names (matched by bank name and
last digits); a row whose account cannot be matched safely waits for the user
to choose one — nothing is put in an account nobody chose. Choose any account
to start the import; the statement decides the rest.

What the phone keeps from each row, exactly as the web import does:

* **Duplicates** — checked on every account the statement names, by the UPI
  reference number as well as by date and amount, so importing the same
  statement again (or the bank's own statement for the same payments) adds
  nothing twice.
* **Notes, tags, UPI ID, reference and time** — the note becomes the expense's
  notes; tags are created or reused (migration 006); the reference, UPI ID and
  time are kept on the movement (migration 007). Without those migrations they
  are kept in the notes instead, so nothing printed is lost.
* **Categories** — suggested from the tags and the note, among the user's own
  categories only.
* **Self transfers** ("Self transfer to HDFC Bank - 59") — recorded as a transfer
  between the two accounts, linking the other account's row when that
  statement was imported too (migration 005, else both legs at once).

Loans and reimbursements are recorded from the web app; the phone's review
offers expense, income, refund and transfer.

## Push notifications

> **Not supported in the APK at this time.** Notifications are supported on
> the installed web app (PWA) on iPhone/iPad, Android and desktop, over Web
> Push — install it from Chrome on Android to get them there. The APK's
> Firebase Cloud Messaging code below is kept but dormant: without the
> Firebase setup it shows no notification settings and requests nothing.

Four notifications, the same as the web app's, each with an on/off switch in
**Settings → Notifications** (shared with the web app):

* a reminder around 10 PM with the day's spending,
* a spending summary on the 16th and the last day of the month,
* a bank balance dropping below ₹500,
* a credit card bill due tomorrow.

They are produced on the server by the `push-notify` Edge Function
(`../ui/supabase/functions/push-notify`), which reads each user's own time zone
and sends to every device they have — browsers over Web Push, this app over
Firebase Cloud Messaging — once per event. They arrive with the app closed.

The app never asks for permission by itself: only **Turn on** does. It shows a
notification only for the account signed in on the phone, removes its token on
sign-out, and keeps no server secret: the FCM credentials live in the Edge
Function's secrets.

### Setup (once)

1. **Database** — run `../ui/supabase/008_push_notifications.sql` (if the web
   app's notifications are not set up yet) and then
   `supabase/009_mobile_push_tokens.sql`, in the Supabase SQL editor.
2. **Firebase project** — in the Firebase console create a project (or use an
   existing one), add an **Android app** with package name
   `com.example.expense_tracker`, and download its `google-services.json` into
   `android/app/`. It is git-ignored; without it the app builds as before and
   Settings says notifications are not set up.
3. **Server credentials** — Firebase console → Project settings → Service
   accounts → *Generate new private key*, then give the file to the function:
   ```bash
   supabase secrets set FCM_SERVICE_ACCOUNT="$(cat path/to/service-account.json)"
   ```
   and redeploy it (`supabase functions deploy push-notify --no-verify-jwt --workdir ../ui`).
   Never put this file in the app or in git.
4. **Build** the APK (`flutter build apk --release`) and, in the app,
   **Settings → Notifications → Turn on**.

See `../ui/supabase/functions/push-notify/README.md` for the schedule
(`pg_cron`), the Vault values and verification queries.

## Quick add

A blank new expense offers the user's frequent purchases as chips
("Coffee · ₹120.00"): anything bought at least three times in the last 90
days, grouped by category and merchant (or description). A tap fills the
amount when it is usually the same, the category, the merchant and
description, the payment method and the account or card it was last paid
from; nothing is saved until the user saves. Purchases paid for someone else
are left out, and a deleted category or a closed account or card is never
suggested. It reads the user's own expenses — no new table or server code —
in `lib/models/frequent_expense.dart`, a port of the web app's
`../ui/src/domain/frequentExpenses.ts`; both are tested against the same
fixture, `../ui/src/domain/frequentExpenses.fixture.json`.

## APK size

Release builds leave out 32-bit x86 libraries: Flutter has no x86 release
engine, so they could never load (ML Kit's text recognition alone shipped
~11 MB of them). For the smallest download per phone, build one APK per ABI
instead of the universal one and install the one matching the phone (most
phones: `app-arm64-v8a-release.apk`):

```bash
flutter build apk --release --split-per-abi
```

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
