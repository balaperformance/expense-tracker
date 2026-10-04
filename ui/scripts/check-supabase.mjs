#!/usr/bin/env node
/**
 * Read-only connectivity check against the project's Supabase backend, using
 * only the public anon key from .env.local (never a service key). It writes
 * nothing. It verifies:
 *
 *   1. the auth service is reachable,
 *   2. every table the app uses exists and exposes the columns it selects,
 *   3. an anonymous caller sees zero rows (row-level security isolation),
 *   4. the `ai-chat` Edge Function answers CORS preflight for this web origin
 *      and refuses a call without a user session.
 */
import { readFileSync, existsSync } from 'node:fs';

function loadEnv() {
  const env = { ...process.env };
  for (const file of ['.env.local', '.env']) {
    if (!existsSync(file)) continue;
    for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) {
      const match = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
      if (match && !(match[1] in env)) env[match[1]] = match[2].replace(/^['"]|['"]$/g, '');
    }
  }
  return env;
}

const env = loadEnv();
const url = (env.VITE_SUPABASE_URL ?? '').replace(/\/$/, '');
const key = env.VITE_SUPABASE_ANON_KEY ?? '';
if (!url || !key) {
  console.error('✗ VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY are not set (.env.local).');
  process.exit(1);
}
if (key.startsWith('sb_secret_')) {
  console.error('✗ The configured key is a secret key. Use the anon / publishable key.');
  process.exit(1);
}

const headers = { apikey: key, Authorization: `Bearer ${key}` };
let failures = 0;
const ok = (message) => console.log(`✓ ${message}`);
const fail = (message) => {
  failures += 1;
  console.log(`✗ ${message}`);
};
const warn = (message) => console.log(`! ${message}`);

async function request(path, init = {}) {
  const response = await fetch(`${url}${path}`, { ...init, headers: { ...headers, ...(init.headers ?? {}) } });
  let body;
  const text = await response.text();
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  return { status: response.status, headers: response.headers, body };
}

console.log(`Supabase project: ${new URL(url).host}\n`);

// 1. Auth
{
  const health = await request('/auth/v1/health');
  if (health.status === 200) ok('Auth service reachable');
  else fail(`Auth health returned ${health.status}`);
  const settings = await request('/auth/v1/settings');
  if (settings.status === 200 && settings.body && typeof settings.body === 'object') {
    ok(`Email sign-in ${settings.body.external?.email ? 'enabled' : 'DISABLED'}; confirmation ${settings.body.mailer_autoconfirm ? 'off (auto-confirm)' : 'required'}`);
  }
}

// 2 + 3. Tables, columns and RLS
const TABLES = {
  profiles: 'id, full_name, currency',
  categories: 'id, user_id, name, icon, color, is_default',
  payment_methods: 'id, user_id, name',
  expenses: 'id, user_id, amount, category_id, payment_method_id, expense_date, description, notes',
  income: 'id, user_id, amount, source, income_date, description',
  budgets: 'id, user_id, amount, category_id, month',
  bank_accounts: 'id, user_id, bank_name, nickname, last4, opening_balance, is_active',
  account_transactions: 'id, user_id, account_id, direction, amount, txn_date, expense_id, income_id, transfer_group_id',
};
for (const [table, columns] of Object.entries(TABLES)) {
  const result = await request(`/rest/v1/${table}?select=${encodeURIComponent(columns)}&limit=1`, {
    headers: { Prefer: 'count=exact' },
  });
  if (result.status === 200 || result.status === 206) {
    const range = result.headers.get('content-range') ?? '';
    const visible = Array.isArray(result.body) ? result.body.length : 0;
    if (visible === 0) ok(`${table}: reachable, anonymous caller sees 0 rows (${range || 'no range'}) — RLS isolation holds`);
    else fail(`${table}: an anonymous caller can read ${visible} row(s) — check RLS`);
  } else {
    fail(`${table}: HTTP ${result.status} ${JSON.stringify(result.body).slice(0, 160)}`);
  }
}

// Optional tables and columns the app probes for (migrations 001–010).
const OPTIONAL = [
  ['expenses', 'merchant'],
  ['expenses', 'bank_account_id'],
  ['income', 'bank_account_id'],
  ['account_transactions', 'counterparty_account_id'],
  ['credit_cards', 'id, user_id, card_name, issuer, credit_limit, statement_day, payment_due_day'],
  ['credit_card_transactions', 'id, user_id, card_id, kind, direction, amount, txn_date'],
  ['expenses', 'credit_card_id'],
  ['account_transactions', 'credit_card_id'],
  ['receivables', 'id, user_id, kind, person, ledger_entry_id, expense_id, due_date, note'],
  ['account_transactions', 'receivable_id'],
  ['tags', 'id, user_id, name'],
  ['expense_tags', 'expense_id, tag_id, user_id'],
  ['income_tags', 'income_id, tag_id, user_id'],
  ['account_transactions', 'reference, upi_id, txn_time'],
  ['notification_preferences', 'user_id, daily_reminder, spending_summary, low_balance, card_due, timezone'],
  ['push_subscriptions', 'id, user_id, endpoint, disabled_at'],
  // 009 (mobile/supabase): the Android app's push tokens.
  ['mobile_push_tokens', 'id, user_id, token, platform, disabled_at'],
  // 010: the in-app notification history under the header bell.
  ['notification_log', 'event_key, kind, sent_at, title, body, url, read_at'],
];
for (const [table, column] of OPTIONAL) {
  const result = await request(`/rest/v1/${table}?select=${encodeURIComponent(column)}&limit=1`);
  const name = column.includes(',') ? table : `${table}.${column}`;
  if (result.status !== 200) {
    warn(`${name} missing (HTTP ${result.status}) — the app hides the dependent feature`);
  } else if (Array.isArray(result.body) && result.body.length > 0) {
    fail(`${name}: an anonymous caller can read ${result.body.length} row(s) — check RLS`);
  } else {
    ok(`${name} present`);
  }
}

// 4. Edge Function
{
  const origin = 'https://expense-tracker.pages.dev';
  const preflight = await fetch(`${url}/functions/v1/ai-chat`, {
    method: 'OPTIONS',
    headers: {
      Origin: origin,
      'Access-Control-Request-Method': 'POST',
      'Access-Control-Request-Headers': 'authorization, x-client-info, apikey, content-type',
    },
  });
  const allowOrigin = preflight.headers.get('access-control-allow-origin');
  if (preflight.status < 300 && (allowOrigin === '*' || allowOrigin === origin)) ok(`ai-chat CORS preflight OK (${preflight.status}, allow-origin ${allowOrigin})`);
  else fail(`ai-chat preflight returned ${preflight.status}, allow-origin ${allowOrigin}`);

  const anonymous = await request('/functions/v1/ai-chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action: 'chat', message: 'ping' }),
  });
  if (anonymous.status === 401) ok('ai-chat refuses a call without a user session (401)');
  else if (anonymous.status === 404) fail('ai-chat is not deployed (404)');
  else fail(`ai-chat answered an anonymous call with ${anonymous.status}`);
}

// 5. Push notification sender (optional: only if notifications were set up)
{
  const anonymous = await request('/functions/v1/push-notify', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: '{}',
  });
  if (anonymous.status === 401) ok('push-notify refuses a call without the schedule secret (401)');
  else if (anonymous.status === 404) warn('push-notify is not deployed (404) — push notifications are off');
  else if (anonymous.status === 503) warn('push-notify is deployed but not configured (503) — set its secrets');
  else fail(`push-notify answered an anonymous call with ${anonymous.status}`);
}

console.log(failures ? `\n${failures} check(s) failed.` : '\nAll Supabase checks passed.');
process.exit(failures ? 1 : 0);
