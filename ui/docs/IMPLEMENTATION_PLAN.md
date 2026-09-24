# Expense Tracker — Web + PWA implementation plan

Source of truth: the Flutter app in `../mobile` (read-only for this project).
Backend: the **existing** Supabase project and its `ai-chat` Edge Function.
Nothing is added to or changed in the database, RLS, or the function.

## 1. What the Flutter app does (inspected)

| Area | Flutter behaviour to reproduce |
| --- | --- |
| Auth | Email + password sign-in; register (full name, strength rule: 8+ chars, a letter, a number); email-confirmation screen with resend; change password in Settings by re-proving the current one (no email reset flow). |
| Bootstrap | Probe optional schema (`expenses.merchant`, `bank_accounts`, `*.bank_account_id`, `account_transactions.counterparty_account_id`); fetch-or-create `profiles`; seed default categories + payment methods idempotently. |
| Dashboard | Greeting + name; chart carousel (category donut + top-3, 6-month spend bars with delta badge); Net hero card (income/expense legs, spend bar, masked bank total); quick actions; budget alert/overall budget; account carousel; recent 5 expenses; first-run card. |
| Expenses | Paginated (20), day-grouped, searchable (merchant/description/notes, debounced), filters (date range + presets, categories, payment methods), sort, swipe-to-delete, export. |
| Expense form | Amount, category (required), date, "Paid from" (Cash / bank account → ledger debit), merchant, description, notes, payment method; receipt scan + SMS paste entry points; delete. |
| Income | Same list pattern; form with source presets, date, "Deposit into" (ledger credit), description. |
| Accounts | Ledger-derived balances; total hero; add/edit/delete account; add money / take money out; transfers (two legs, one insert, shared `transfer_group_id`, sufficient-funds check re-derived from the ledger in cents). |
| Statement | Month stepper / all history, All/Debits/Credits, brought-forward opening balance, running balance, day groups, delete manual entries / both transfer legs. |
| Budgets | Per-month overall + per-category budgets, find-then-write, copy last month, 80% warning / over. |
| Categories / Payment methods | CRUD with case-insensitive duplicate checks, detach expenses before delete, usage count. |
| Reports | Month stepper, saved/overspent summary, income-vs-expense bars, donut + breakdown, top category. |
| Receipt scanner | On-device OCR → heuristic parser (total/merchant/date/items + confidence) → review → prefilled expense form. |
| Bank SMS | On-device regex parser → account matcher → keyword category → optional `classify` (payee only) → review with duplicate check (reference in notes / same day+amount+account). |
| AI Assistant | `ai-chat` Edge Function with the user's JWT: `chat`, `confirm` (pending action card), `classify`. In-memory transcript, 10-turn text history, 1000-char cap. |
| Export | Six report types → CSV (formula-injection safe) or PDF. |
| Settings | Profile name, currency (9), theme (system/light/dark, device-local), hide balances (device-local, reset on sign-out), sign out. |

## 2. Web architecture

```
src/
  config/        env (validated; refuses a service-role key)
  lib/           supabase client, errors, retry, formatting, dates, validators, ids
  domain/        pure TS ports of the Dart models + logic (statement, breakdown,
                 transfer rules, SMS parser, receipt parser, export builder, CSV)
  services/      repositories — one per table — plus schema capabilities,
                 AI client and OCR adapter. The only code that touches Supabase.
  state/         auth, settings, bootstrap and AI-chat contexts; query keys
  hooks/         react-query hooks per feature (+ invalidation helpers)
  components/    design system (ui/), charts/, layout/, feature widgets
  features/      one folder per screen group (auth, dashboard, expenses, …)
  styles/        tokens.css (Gothic Noir light/dark), base.css
```

* **Data**: `@tanstack/react-query` replaces the Flutter providers' manual
  cache/invalidate. Keys are scoped by user id; a sign-out clears the cache.
* **Security**: only the publishable anon key is shipped; every query carries
  the explicit `user_id` filter the Flutter repositories use, RLS does the
  enforcing. AI keys stay in the Edge Function. Financial API responses are
  never cached by the service worker.
* **Routing**: `react-router` — tabs are routes; Flutter pushes become routes,
  Flutter bottom sheets become sheets.
* **Design system**: CSS custom properties generated from `app_colors.dart`,
  `app_glass.dart`, `app_chart_colors.dart`, `app_spacing.dart`,
  `app_typography.dart`, `app_motion.dart`. System serif (Georgia on iOS) for
  display, system sans for work — zero font bytes, like the Flutter app.
* **Charts**: hand-written SVG (donut, bars) — no chart library.
* **Icons**: `@mdi/js` path constants (tree-shaken, no icon font).
* **OCR**: `tesseract.js`, lazy-loaded only when scanning, self-hosted assets,
  image never leaves the device.
* **PWA**: `vite-plugin-pwa` (Workbox): manifest, precached app shell,
  navigate fallback, update prompt, iOS meta + safe areas, generated icons.
* **Hosting**: Cloudflare Pages (static `dist/`, SPA fallback, `_headers`).

## 3. Order of work

1. Scaffold (Vite, TS strict, ESLint, Vitest, PWA plugin), tokens, base CSS.
2. Domain ports + unit tests mirroring the Flutter tests.
3. Services (repositories, capabilities, AI, OCR).
4. Design-system components, layout shell (glass nav / desktop rail).
5. Features: auth → dashboard → expenses → income → accounts/statement/
   transfers → budgets → categories/payment methods → reports → receipt →
   SMS → assistant → export → settings.
6. PWA assets + headers; validation (tsc, lint, tests, build, PWA, Supabase
   connectivity, responsive screenshots).
