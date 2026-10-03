# Expense Tracker — Web  & PWA

The web and installable-PWA version of the Flutter Expense Tracker in
[`../mobile`](../mobile). It is a **frontend only**: it talks to the same
Supabase project, the same tables, the same row-level-security policies and the
same `ai-chat` Edge Function as the phone app. The one schema addition is
[`supabase/004_credit_cards.sql`](supabase/004_credit_cards.sql) for the web's
credit cards — additive, with RLS, and invisible to the phone app (see
[Credit cards](#credit-cards)). Nothing else in the database, RLS or the
function was changed.

Stack: React 19 · Vite 8 · TypeScript (strict) · TanStack Query · React Router ·
Supabase JS · vite-plugin-pwa (Workbox) · Tesseract.js (on-device OCR) · PDF.js (on-device statement reading).

## Run locally

```bash
cd ui
npm install
cp .env.example .env.local   # then fill in the two values
npm run dev                  # http://localhost:5173
```

`.env.local` needs only public values:

| Variable | Value |
| --- | --- |
| `VITE_SUPABASE_URL` | `https://<project-ref>.supabase.co` |
| `VITE_SUPABASE_ANON_KEY` | the **anon / publishable** key |

The app refuses to start with a service-role / secret key. AI keys live only in
the Edge Function's secrets and are never read here.

Other scripts:

| Command | What it does |
| --- | --- |
| `npm run build` | type-check + production build into `dist/` (also writes `dist/_headers`) |
| `npm run preview` | serves `dist/` with the production Content-Security-Policy |
| `npm run typecheck` / `lint` / `test` | TypeScript, ESLint (strict type-checked), Vitest |
| `npm run check:pwa` | validates manifest, icons, service worker, iOS meta, headers in `dist/` |
| `npm run check:supabase` | read-only checks against the live project with the anon key |
| `npm run validate` | typecheck → lint → test → build → PWA check |
| `npm run icons` | regenerates PWA icons from `public/favicon.svg` and `assets/app-icon.svg` |
| `npm run build:engine` | bundles the statement-import engine (`src/engine/`) into `../mobile/assets/statement_engine/engine.js` for the Android app — rerun after changing statement parsing, classification or duplicate rules, then rebuild the APK |

**UI preview without signing in (development only):** open
`http://localhost:5173/?demo` to run every screen over seeded sample data
(`src/dev/DemoApp.tsx`). The branch is compiled out of production builds;
clear it with `sessionStorage.removeItem('et.demo')`.

## Architecture

```
src/
  config/      env.ts — validated public config; rejects privileged keys
  lib/         supabase client, error mapping, retry, dates, formatting, validators, colours, share/print
  domain/      pure TypeScript ports of the Dart models and logic:
               models, analytics, statement, transfer rules, expense filter,
               sms/ (bank SMS parser + account matcher + draft), receipt/ (OCR text parser + suggester),
               export/ (datasets, CSV, printable PDF), aiChat contract,
               statementImport/ (bank statement reader — see below),
               creditCards (billing cycles, card statement, bill status)
  services/    the only code that talks to Supabase — one module per table,
               schema capabilities probe, ai-chat client, OCR adapter, export loader
  state/       auth, settings (theme/currency/masked balances), session bootstrap,
               AI conversation, feedback (toasts/confirm), list state, query client
  hooks/       react-query read hooks (data.ts) and write hooks (mutations.ts), UI hooks
  components/  ui/ design system · finance/ money widgets · charts/ SVG charts · layout/ shell
  features/    screens: auth, dashboard, expenses, income, accounts, creditCards, budgets,
               catalog, reports, receipt, sms, assistant, export, settings
supabase/      004–008 migrations (001–003 live in ../mobile/supabase);
               functions/push-notify — the push notification sender (Deno Edge Function)
  styles/      tokens.css (Gothic Noir light/dark), base.css (typography, helpers)
```

* **Same backend rules as Flutter.** Every query carries the explicit
  `user_id` filter the Flutter repositories use; RLS does the enforcing. Ledger
  sync for bank-funded expenses/income, two-leg transfers in one insert,
  balances derived from the ledger, find-then-write budgets, detach-then-delete
  categories — all ported, not re-invented.
* **Optional schema.** Like `SchemaCapabilities` in Flutter, the app probes
  `expenses.merchant`, `bank_accounts`, `*.bank_account_id`,
  `account_transactions.counterparty_account_id` and the credit-card tables
  and columns of 004, and hides what is missing.
* **AI.** Only `supabase.functions.invoke('ai-chat', …)` with the user's own
  session: `chat`, `confirm` (pending-action cards) and `classify` (payee only,
  for SMS import). The transcript is in memory and cleared on sign-out.
* **Privacy.** Receipt photos and bank SMS text are processed in the browser.
  The service worker precaches the app shell only; Supabase responses are never
  cached. Exports are generated on the device.
* **Design system.** Tokens are taken from `app_colors.dart`, `app_glass.dart`,
  `app_chart_colors.dart`, `app_spacing.dart`, `app_typography.dart` and
  `app_motion.dart`: system serif (New York on iPhone) for figures and titles,
  system sans for work, zero font downloads; hand-drawn SVG charts.
* **Parity tests.** `src/**/*.test.ts` port the Flutter test cases for the SMS
  parser, account matcher, receipt parser, statement builder, transfer rules,
  budgets and export, plus the statement-import and credit-card suites
  (240 tests).

### Bank statement import

Accounts → **Import statement** (or the same icon on an account's statement).
Pick the account, add one or more statements — PDF, or the Excel (.xlsx)
download — weekly, fortnightly or monthly, overlapping is fine — review, then
import.

```
PDF/xlsx ─▶ TextExtractor ─▶ StatementParser ─▶ normalizeStatement ─▶ classify ─▶ markDuplicates ─▶ review ─▶ ImportPlan ─▶ Supabase
       services/          domain/statementImport/ (pure TypeScript — portable to Dart)                                  importer
```

* **On the device.** PDF.js reads the text layer locally (password-protected
  PDFs prompt for the password, which is never stored); `.xlsx` files are read
  by a small built-in reader (`services/statementImport/xlsx.ts`, no library).
  Old `.xls` and password-protected spreadsheets are explained, not guessed at. No AI is used, and
  nothing is sent anywhere until the user confirms the import.
* **Parsers are pluggable.** `parsers/index.ts` holds `BANK_PARSERS` and a
  bank-agnostic fallback that reads tables by their column headings. A bank
  parser locates each row's date, narration and amount text and may name a
  bank-neutral *channel* (upi, atm, loan, card, …) and the payee; everything
  downstream is shared.
  * **HDFC Bank** (`parsers/hdfc.ts`) — the NetBanking Excel download and the
    PDF: Withdrawal Amt. → debit, Deposit Amt. → credit, Closing Balance,
    Chq./Ref.No. and wrapped narrations preserved; UPI payee, NWD/ATW cash,
    EMI/DPI loans, NEFT/RTGS/IMPS, POS, ACH, card autopay, interest, charges
    and reversals recognised. Claimed only when HDFC is named in the
    statement's own header.
  * **Airtel Payments Bank** (`parsers/airtelPaymentsBank.ts`) — the PDF:
    Date, Transaction ID → reference, Particulars rebuilt from the 26-character
    pieces Airtel prints (a space that falls at the start of a piece is not in
    the PDF text, so those words stay joined), Debit, Credit and Balance; UPI rows and
    account charges recognised (UPI Particulars carry only a UPI ID, so no
    payee is taken). The summary's opening/closing balances anchor the balance
    check and its totals are compared with the rows read. Claimed only when
    Airtel Payments Bank (or its AIRP IFSC) appears outside the transaction table.
* **Duplicate protection.** Fingerprint = account | date | cents | debit/credit
  | normalised narration. Overlapping statements are matched by fingerprint
  *and occurrence*, and incoming rows are matched one-to-one against the
  account's ledger (every expense, income, movement and transfer leg), then
  checked again against a fresh read just before writing.
* **Where rows go.** Debits → expenses, credits → income (each with its ledger
  row, via the normal create paths); refunds and transfers (own accounts,
  ATM cash, card bills) → balance-only ledger movements. No schema change.
* **The Android app uses this same code.** `src/engine/` wraps the reader,
  review and plan in a JSON API that `npm run build:engine` bundles into one
  offline script; the app runs it in a hidden WebView (network loads blocked)
  and performs the confirmed writes with its own repositories. A parser fixed
  here is fixed on the phone by rebuilding the bundle and the APK.
* **Scanned PDFs** are detected and reported; `OCR_EXTRACTOR` in
  `services/statementImport/extractors.ts` is the slot for an OCR fallback.

### Credit cards

**Setup:** run [`supabase/004_credit_cards.sql`](supabase/004_credit_cards.sql)
once in the Supabase SQL editor, after `../mobile/supabase/002` and `003`.
It is additive and idempotent; until it runs, Credit cards shows a "one
migration away" screen and everything else works as before.

Credit cards (side rail, Settings, the Accounts header or the dashboard) lists
each card with its outstanding, available credit, limit and bill status; a
card's page shows the latest bill (statement balance, due date, paid since,
still to pay), the open cycle, and a statement by billing cycle with a running
outstanding. Cards have a name, issuer, network, last four digits, limit,
opening outstanding, statement day, due day, a usual paying account, notes and
active/inactive.

Every movement is stored **once**, where the app already keeps that kind of
row — nothing is duplicated to represent the account/card relationship:

| Movement | Stored as | Bank balance | Card outstanding | Spending |
| --- | --- | --- | --- | --- |
| Purchase | `expenses` row with `credit_card_id` (no `bank_account_id`, so no ledger row) | — | + | counted (it is an expense) |
| Bill payment from an account | **one** `account_transactions` debit with `credit_card_id` | − | − | not counted |
| Bill payment in cash | `credit_card_transactions` row, kind `payment` | — | − | not counted |
| Refund · cashback | `credit_card_transactions` credit | — | − | not income |
| Fee · interest | `credit_card_transactions` debit | — | + | not an expense |
| Adjustment | `credit_card_transactions`, either direction | — | ± | — |

* **Both sides always tally.** A bill payment from an account is a single
  ledger row that both the bank balance and the card outstanding read, so they
  cannot disagree; deleting it removes it from both. Outstanding is derived,
  never stored: opening outstanding + purchases + card debits − card credits −
  linked bank debits.
* **Reconciliation.** A bill already on the account (typed in, or imported
  from a bank statement as a "card bill" movement) is linked rather than
  re-recorded: Pay bill offers same-amount debits within three days, and
  long-pressing a plain debit on a bank statement offers *Mark as a card bill
  payment*. Linking only sets `account_transactions.credit_card_id`, and only
  on an unlinked plain debit. A statement import recognises a debit naming
  one of your cards (card wording plus its last four digits) and writes it as
  that card's linked bill payment, never an expense; a hand-recorded payment
  the bank posts a day or two later is blocked as a duplicate.
* **Integrity in the database.** RLS on both new tables; composite foreign keys
  so a row can only reference the same user's card, account or expense; a
  bill payment must be a plain debit; an expense cannot be paid from a bank
  account and a card at once.
* **Phone app.** It ignores the new columns. It shows a card purchase as a
  Cash expense (still counted as spending) and a bill payment as a debit on
  the account. If a card purchase is edited on the phone and given a bank
  account, a trigger makes that newer choice win and drops the card link.
* **Bank SMS.** A card spend alert pre-selects the card whose last four digits
  match (or asks, when the digits are ambiguous).

### Push notifications

Four optional notifications — a 10 PM spending reminder, a summary on the 16th
and the last day of the month, a low-balance alert (below ₹500), and a credit
card reminder the day before a bill is due — each with an on/off switch under
**Settings → Notifications**. They are produced by the `push-notify` Edge
Function on a 15-minute `pg_cron` schedule, so they arrive with the app closed.
The service worker (generated by vite-plugin-pwa) loads `public/push-sw.js` for
the `push` and `notificationclick` handlers; its caching is unchanged.

Setup — the migration `supabase/008_push_notifications.sql`, a VAPID key pair,
the function's secrets and the Vault entries — is in
[`supabase/functions/push-notify/README.md`](supabase/functions/push-notify/README.md).
Without `VITE_VAPID_PUBLIC_KEY` in the build, or without the migration, the
section does not appear or says it is not set up, and nothing else changes.

### Quick add

A blank new expense offers the user's frequent purchases as chips
("Coffee · ₹120.00"): anything bought at least three times in the last 90
days, grouped by category and merchant (or description). A tap fills the
amount when it is usually the same, the category, the description, the
payment method and the account or card it was last paid from; nothing is
saved until the user saves. Purchases paid for someone else are left out, and
a deleted category or a closed account or card is never suggested. It reads
the user's own expenses — no new table or server code — in
`src/domain/frequentExpenses.ts`, which the phone app ports line for line;
both are tested against `src/domain/frequentExpenses.fixture.json`.

## Deploy to Cloudflare Pages (free plan)

### Option A — Git integration (recommended)

1. Push this repository to GitHub or GitLab.
2. Cloudflare dashboard → **Workers & Pages** → **Create** → **Pages** →
   **Connect to Git**, and pick the repository.
3. Build settings:
   * **Framework preset:** None (or Vite)
   * **Root directory:** `ui`
   * **Build command:** `npm run build`
   * **Build output directory:** `dist`
4. **Environment variables** (Production *and* Preview):
   * `VITE_SUPABASE_URL` = `https://<project-ref>.supabase.co`
   * `VITE_SUPABASE_ANON_KEY` = the anon / publishable key
   * (`ui/.node-version` pins Node 22; set `NODE_VERSION=22` only if your build image ignores it.)
5. **Save and Deploy.** The site is served at `https://<project>.pages.dev`.
   SPA routes work out of the box (Pages serves `index.html` for unknown paths
   because the build has no `404.html`), and `dist/_headers` applies the CSP,
   security headers and cache rules.
6. In **Supabase → Authentication → URL Configuration**, add
   `https://<project>.pages.dev/**` (and any custom domain) to **Redirect URLs**
   so email-confirmation links return to the web app. Set the **Site URL** to it
   if the web app is the primary client.
7. Optional: **Custom domains** → add your domain; Cloudflare issues the
   certificate. Add that origin to the Supabase redirect list too.

Every push to the production branch redeploys; other branches get preview URLs.

### Option B — Direct upload

```bash
cd ui
npm run build            # uses the values in .env.local
npx wrangler pages deploy dist --project-name expense-tracker
```

## Install on iPhone

Open the site in Safari → **Share** → **Add to Home Screen**. It launches
full-screen with its own icon, respects the notch and home indicator, and
opens offline to the app shell. Android/desktop Chrome offer **Install** (also
available from Settings → About in the app).
