# Expense Tracker — Web & PWA

The web and installable-PWA version of the Flutter Expense Tracker in
[`../mobile`](../mobile). It is a **frontend only**: it talks to the same
Supabase project, the same tables, the same row-level-security policies and the
same `ai-chat` Edge Function as the phone app. Nothing in the database, RLS or
the function was changed.

Stack: React 19 · Vite 8 · TypeScript (strict) · TanStack Query · React Router ·
Supabase JS · vite-plugin-pwa (Workbox) · Tesseract.js (on-device OCR).

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
               export/ (datasets, CSV, printable PDF), aiChat contract
  services/    the only code that talks to Supabase — one module per table,
               schema capabilities probe, ai-chat client, OCR adapter, export loader
  state/       auth, settings (theme/currency/masked balances), session bootstrap,
               AI conversation, feedback (toasts/confirm), list state, query client
  hooks/       react-query read hooks (data.ts) and write hooks (mutations.ts), UI hooks
  components/  ui/ design system · finance/ money widgets · charts/ SVG charts · layout/ shell
  features/    screens: auth, dashboard, expenses, income, accounts, budgets, catalog,
               reports, receipt, sms, assistant, export, settings
  styles/      tokens.css (Gothic Noir light/dark), base.css (typography, helpers)
```

* **Same backend rules as Flutter.** Every query carries the explicit
  `user_id` filter the Flutter repositories use; RLS does the enforcing. Ledger
  sync for bank-funded expenses/income, two-leg transfers in one insert,
  balances derived from the ledger, find-then-write budgets, detach-then-delete
  categories — all ported, not re-invented.
* **Optional schema.** Like `SchemaCapabilities` in Flutter, the app probes
  `expenses.merchant`, `bank_accounts`, `*.bank_account_id` and
  `account_transactions.counterparty_account_id` and hides what is missing.
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
  budgets and export (110 tests).

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
