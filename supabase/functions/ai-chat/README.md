# `ai-chat` — the assistant's server side

The Flutter app never talks to an AI provider. It calls this Edge Function with
the user's own Supabase session, and the function does everything else: verify
the token, choose a model, run the allow-listed tools *as that user*, and hand
back a plain reply.

```
Flutter (session JWT) ──► ai-chat ──► Gemini (primary) / Groq (fallback)
                             │
                             └──► allow-listed tools ──► PostgREST as the user (RLS)
```

## Secrets

Set once per project. They live only here — never in the app, `.env`, Dart,
Android or iOS resources, or the database.

```bash
supabase secrets set GEMINI_API_KEY=...   # https://aistudio.google.com/apikey  (free tier)
supabase secrets set GROQ_API_KEY=...     # https://console.groq.com/keys      (free tier)
```

Optional overrides — the defaults are current free-tier models with tool use:

| Secret          | Default              | Notes                                              |
|-----------------|----------------------|----------------------------------------------------|
| `GEMINI_MODEL`  | `gemini-3.8-flash`   | Any Flash / Flash-Lite id on the free tier.        |
| `GROQ_MODEL`    | `openai/gpt-oss-120b`| `llama-3.3-70b-versatile` was retired 2026-08-16.  |

`SUPABASE_URL` and the publishable key are injected by the platform. The
function deliberately never reads `SUPABASE_SERVICE_ROLE_KEY`,
`SUPABASE_SECRET_KEYS` or `SUPABASE_DB_URL`.

## Deploy

```bash
supabase link --project-ref <your-project-ref>
supabase functions deploy ai-chat
```

Leave JWT verification on (the default). The function verifies the token
again itself and derives the user id from it; there is no other source of
identity anywhere in the code.

## What the model can do

Exactly twelve tools, listed in `tools/registry.ts`. Nine read aggregates
(totals, balances, budgets, a capped statement); three *prepare* a write. A
prepared write is returned to the app as a `pending_action` and executed only
when the app sends it back under `action: "confirm"` — and even then every
argument is re-validated against the user's live rows.

There is no tool that takes a table, a column, a filter expression or SQL.

## Actions

| `action`   | Used by            | What it does                                  |
| ---------- | ------------------ | --------------------------------------------- |
| `chat`     | AI assistant       | Full agent loop over the twelve tools          |
| `confirm`  | AI assistant       | Executes a `pending_action` the user approved  |
| `classify` | Bank-SMS import    | Names a spending category for one merchant     |

`classify` (`core/classify.ts`) is the narrow path: one merchant string in,
one category name out. It runs with an **empty tool list**, so both adapters
omit tool configuration entirely and the model has no callable surface — it
cannot read a balance, list a transaction or prepare a write. It sends no
history and no financial data: the client is only ever given the payee, never
the message, the amount, the account or the reference. The answer is matched
against the caller's own category names and discarded if it is not one of
them, so an invented category, a refusal or a sentence all come back as
`null`, and the app falls back to its own catch-all.

It shares this function's authentication and rate limit rather than getting an
endpoint of its own, so there is one door into the AI and one place where the
user's identity is established.

## Limits (see `core/limits.ts`)

1000-char messages, 12 history turns / 6000 chars, 32 KB body, 6 tool
iterations, 25 s per provider call, 60 s per request, 20 requests per user
per 5 minutes. One fallback attempt (Gemini → Groq) for rate limits, outages,
timeouts and unknown models; none for a rejected request or a bad key.

## Tests

No network, no database — the tools run against an in-memory `DbPort` that
behaves like RLS.

```bash
deno test --allow-net=registry.npmjs.org,jsr.io supabase/functions/ai-chat/tests/
```

Type-check the deployable entrypoint:

```bash
deno check supabase/functions/ai-chat/index.ts
```

## Local run against the real project

```bash
deno run --env-file=.env --allow-net --allow-env supabase/functions/ai-chat/index.ts
```

Uses the app's `.env` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`) so requests carry
a real user JWT and hit the real RLS. Without `GEMINI_API_KEY` / `GROQ_API_KEY`
in the environment the chat action answers `503 not_configured`, which is the
correct behaviour, not a bug.
