# `push-notify` — push notifications, server side

Four notifications, generated on the server so they arrive whether or not the
app is open, from one run and under one event key.

**Supported platforms: the installed web app (PWA) on iPhone/iPad, Android and
desktop**, all over standard Web Push with the project's VAPID keys. No
Firebase project, `google-services.json` or `FCM_SERVICE_ACCOUNT` is needed.
The Android APK's Firebase Cloud Messaging channel is built but **dormant**:
it is not supported at this time and stays off unless all of its setup below
is done.

| Notification | When (the user's own clock) | Text |
|---|---|---|
| Daily reminder | 22:00–22:59, once a day | `Today's spending: ₹X. Don't forget to add any missing expenses.` (₹0 on a quiet day) |
| Spending summary | 20:00–20:59 on the **16th** (spending 1st–15th) and on the **last day** (the whole month) | `Spending update: ₹X spent so far this month.` / `… spent this month.` |
| Low bank balance | once per spell below ₹500 for each active account (including one already low when first seen); again only after it has recovered to ₹500 or more | `Low balance: HDFC Savings is ₹420.` |
| Credit card due | from 09:00 on the day before a bill's due date, while it is unpaid | `Credit card reminder: HDFC Visa payment is due tomorrow.` |

```
pg_cron (every 15 min) ──► public.invoke_push_notify() ──pg_net──► push-notify
                                                                       │
        reads (service role): expenses, receivables, bank accounts,    │
        ledger, credit cards ◄─────────────────────────────────────────┤
        claims a unique event key in notification_log, then ───────────┴─► Web Push (VAPID)  → browsers
                                                                         └─► FCM HTTP v1      → Android app
```

One schedule serves every time zone: each run reads each user's own wall clock
(the zone is stored with their preferences, refreshed whenever the app opens).

## What counts

The sums use the **same definitions as the app** — they are restated in
`core/` (the function runs in Deno and cannot import the app's code), and
`src/domain/notifications/parity.test.ts` holds each one to the app's own
implementation:

* **Spending** — rows of `expenses`, except purchases paid on someone else's
  behalf (`receivables.expense_id`). Transfers, loans, repayments,
  reimbursements, refunds and card bill payments are never expenses.
* **Bank balance** — opening balance + ledger credits − ledger debits, in whole
  cents. Credit cards are not accounts and are never included. Closed
  accounts are not watched.
* **Card due date** — the billing cycle and last-statement logic of
  `src/domain/creditCards.ts`. A bill that is paid, or nothing, gets no reminder.

## Never twice

Every event has a deterministic key — `daily:2026-10-03`,
`summary:2026-10:mid`, `card:<card>:<due date>`, `low:<account>:<n>` — claimed
with a unique insert into `notification_log` **before** sending. Overlapping
runs and repeated runs find the key taken and do nothing. A claim is handed
back only when every device failed for a reason that may pass (network, 5xx),
so the next run tries again.

The low-balance watch keeps one row per account (`low_balance_state`) and
alerts once per spell below ₹500 while the switch is on: an account that is
already low when first seen is alerted, as is a spell that began while the
switch was off, once it is turned on. It alerts again only after the balance
has recovered to ₹500 or more. (Rows an earlier version wrote on its first
look — `is_low` with episode 0, never alerted — are alerted on the next run.)

A subscription the push service reports gone (404/410) is switched off
(`disabled_at`); a browser that registers again is switched back on. A phone
token FCM reports gone (UNREGISTERED, a sender mismatch, an invalid token) is
switched off the same way in `mobile_push_tokens`.

## Phones (Firebase Cloud Messaging) — dormant, not supported at this time

The Android app registers its FCM token with `register_mobile_push_token`
(`mobile/supabase/009_mobile_push_tokens.sql`), which also records the
phone's time zone. Every user with a browser **or** a phone is processed; each
event is claimed once and handed to every device the user has
(`core/channels.ts`) — it counts as sent when any device took it.

Messages to phones are **data only** (`core/fcm.ts`): the app draws the
notification itself, and only when the message's `audience` — the first 32 hex
digits of SHA-256 of the user id — is the account signed in on that phone. A
phone that signed out, or that someone else signed in to, stays quiet even if
its token could not be removed. The user id itself is never sent.

The server logs in as a Firebase service account (an RS256-signed assertion
exchanged for an access token, all with WebCrypto — no extra library). Each
channel is optional: configure Web Push, FCM or both.

## Setup (once per project)

1. **Run the migration** — `ui/supabase/008_push_notifications.sql` in the SQL editor.
   Enable the `pg_cron` and `pg_net` extensions first (Database → Extensions).
2. **Generate a VAPID key pair**:
   ```bash
   npx web-push generate-vapid-keys
   ```
3. **Set the function's secrets** (never in git, never in the app):
   ```bash
   supabase secrets set VAPID_PUBLIC_KEY=<public key> VAPID_PRIVATE_KEY=<private key> \
     VAPID_SUBJECT=mailto:you@example.com PUSH_NOTIFY_SECRET=<a long random string>
   ```
4. **Deploy it without JWT verification** — the caller is the database, and it
   proves itself with `PUSH_NOTIFY_SECRET`:
   ```bash
   supabase functions deploy push-notify --no-verify-jwt --workdir ui
   ```
5. **Tell the schedule where it is** — in the SQL editor, with the *same* random string:
   ```sql
   select vault.create_secret('https://<project-ref>.supabase.co/functions/v1/push-notify', 'push_notify_url');
   select vault.create_secret('<the PUSH_NOTIFY_SECRET string>', 'push_notify_secret');
   ```
6. **Give the web build the public key** — `VITE_VAPID_PUBLIC_KEY=<public key>`
   in `ui/.env.local` and in the Cloudflare build variables, then rebuild.

Then, in the app: **Settings → Notifications → Turn on**.

### Adding the Android app (FCM) — dormant, not needed for the PWA

1. Run `mobile/supabase/009_mobile_push_tokens.sql` (after 008).
2. In the Firebase console, add an Android app with package
   `com.example.expense_tracker` and put its `google-services.json` in
   `mobile/android/app/` (git-ignored).
3. Firebase console → Project settings → Service accounts → **Generate new
   private key**, and give the file's JSON to the function:
   ```bash
   supabase secrets set FCM_SERVICE_ACCOUNT="$(cat path/to/service-account.json)"
   ```
   then redeploy (step 4 above). The key never goes into the app or git.
4. Build the APK; in the app: **Settings → Notifications → Turn on**.

## Checking it

```bash
npm run check:supabase       # tables present, RLS holds, push-notify answers 401 without the secret
```

A manual run (prints counts only — no personal data):

```bash
curl -X POST https://<project-ref>.supabase.co/functions/v1/push-notify \
  -H "x-push-secret: <the PUSH_NOTIFY_SECRET string>"
```

Type-check the function with Deno (the web app's `typecheck` covers `core/`):

```bash
npx deno check --no-config --node-modules-dir=none supabase/functions/push-notify/index.ts
```

## Secrets summary

| Where | Name | What |
|---|---|---|
| Function | `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` | Web Push signing |
| Function | `FCM_SERVICE_ACCOUNT` | optional, dormant: the Firebase service-account key (JSON) for the Android APK — not used by the PWA |
| Function | `PUSH_NOTIFY_SECRET` | proves the caller is the schedule |
| Vault | `push_notify_url`, `push_notify_secret` | where the schedule calls, and the same secret |
| Web build | `VITE_VAPID_PUBLIC_KEY` | the **public** key only |
| Android build | `android/app/google-services.json` | optional, dormant: the Firebase project's **public** app config |
| Platform | `SUPABASE_URL`, service-role key | injected automatically |
