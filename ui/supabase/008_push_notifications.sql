-- ============================================================================
-- 008: Web push notifications — subscriptions, the four on/off preferences,
--      de-duplication, and the schedule that wakes the sender
-- ============================================================================
--
-- Runs on the same Supabase project as mobile/supabase/001–003 and
-- ui/supabase/004–007, after them. Written for the web app; the phone app
-- neither reads nor writes any of this and keeps working unchanged.
--
-- SAFETY
--   * Additive only: four new tables, three new functions, one cron job. No
--     existing table, column, policy or row is touched.
--   * Idempotent: IF NOT EXISTS / CREATE OR REPLACE / DROP POLICY IF EXISTS,
--     and the cron job is replaced by name, so re-running is harmless.
--   * RLS on every table. The browser can read and delete only its own
--     subscriptions and read and write only its own preferences. The two
--     tables the sender keeps for itself (notification_log, low_balance_state)
--     have RLS on and NO policy: only the service role, which bypasses RLS,
--     can touch them.
--
-- DESIGN
--   push_subscriptions      One row per browser/device that said yes. Written
--                           only by register_push_subscription() so a device
--                           that changes hands moves to the user now signed in.
--   notification_preferences  The four switches, plus the user's time zone —
--                           the sender decides "10 PM" per user from it. A
--                           missing row means "all on"; nothing is sent to a
--                           device that has not subscribed, so on-by-default
--                           changes nothing for anyone until they opt in.
--   notification_log        One row per notification sent, keyed
--                           (user_id, event_key) — e.g. daily:2026-10-03,
--                           card:<card>:<due date>. The key is claimed with an
--                           insert BEFORE sending, so overlapping runs and
--                           retries can never send the same event twice.
--   low_balance_state       Whether each account was already below the
--                           threshold at the last check, so only the move from
--                           "at or above" to "below" notifies — and again only
--                           after it has recovered.
--
--   The sender is the `push-notify` Edge Function. pg_cron calls it every
--   15 minutes through pg_net; it works out each user's local time, so one
--   schedule serves every time zone (including half-hour ones).
--
-- BEFORE THE SCHEDULE DOES ANYTHING (once per project)
--   1. Enable the pg_cron and pg_net extensions (Database → Extensions).
--   2. Store two Vault secrets (SQL editor; values are yours to choose):
--        select vault.create_secret('https://<project-ref>.supabase.co/functions/v1/push-notify', 'push_notify_url');
--        select vault.create_secret('<a long random string>', 'push_notify_secret');
--      and give the SAME random string to the function:
--        supabase secrets set PUSH_NOTIFY_SECRET=<that string>
--   See ui/supabase/functions/push-notify/README.md for the whole setup.
--
-- Run this once in the Supabase SQL editor, after 007.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Preferences
-- ---------------------------------------------------------------------------
create table if not exists public.notification_preferences (
  user_id          uuid primary key references auth.users (id) on delete cascade,
  daily_reminder   boolean not null default true,
  spending_summary boolean not null default true,
  low_balance      boolean not null default true,
  card_due         boolean not null default true,
  -- An IANA name such as Asia/Kolkata; refreshed by the app whenever it opens.
  timezone         text not null default 'UTC' check (char_length(timezone) between 1 and 64),
  updated_at       timestamptz not null default now()
);

grant select, insert, update on public.notification_preferences to authenticated;
alter table public.notification_preferences enable row level security;

drop policy if exists notification_preferences_select_own on public.notification_preferences;
create policy notification_preferences_select_own on public.notification_preferences
  for select using (auth.uid() = user_id);

drop policy if exists notification_preferences_insert_own on public.notification_preferences;
create policy notification_preferences_insert_own on public.notification_preferences
  for insert with check (auth.uid() = user_id);

drop policy if exists notification_preferences_update_own on public.notification_preferences;
create policy notification_preferences_update_own on public.notification_preferences
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);


-- ---------------------------------------------------------------------------
-- 2. Subscriptions
-- ---------------------------------------------------------------------------
create table if not exists public.push_subscriptions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade,
  endpoint     text not null unique check (endpoint like 'https://%' and char_length(endpoint) <= 2048),
  p256dh       text not null check (char_length(p256dh) between 1 and 256),
  auth         text not null check (char_length(auth) between 1 and 256),
  user_agent   text check (user_agent is null or char_length(user_agent) <= 400),
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  -- Set by the sender when the push service says the subscription is gone
  -- (404/410); the row is kept so it is clear why a device went quiet, and is
  -- revived if the same browser registers again.
  disabled_at  timestamptz
);

create index if not exists push_subscriptions_user_idx
  on public.push_subscriptions (user_id) where disabled_at is null;

-- No insert/update policy on purpose: registration goes through the function
-- below, which can move an endpoint between users. A user may read and remove
-- their own devices.
grant select, delete on public.push_subscriptions to authenticated;
alter table public.push_subscriptions enable row level security;

drop policy if exists push_subscriptions_select_own on public.push_subscriptions;
create policy push_subscriptions_select_own on public.push_subscriptions
  for select using (auth.uid() = user_id);

drop policy if exists push_subscriptions_delete_own on public.push_subscriptions;
create policy push_subscriptions_delete_own on public.push_subscriptions
  for delete using (auth.uid() = user_id);


-- ---------------------------------------------------------------------------
-- 3. The sender's own bookkeeping (service role only)
-- ---------------------------------------------------------------------------
create table if not exists public.notification_log (
  user_id   uuid not null references auth.users (id) on delete cascade,
  event_key text not null check (char_length(event_key) between 1 and 200),
  kind      text not null,
  sent_at   timestamptz not null default now(),
  primary key (user_id, event_key)
);

create index if not exists notification_log_sent_idx on public.notification_log (sent_at);
alter table public.notification_log enable row level security;

create table if not exists public.low_balance_state (
  account_id uuid primary key references public.bank_accounts (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  is_low     boolean not null,
  -- Counts the times the balance has dropped below the threshold; part of the
  -- event key, so each drop is its own event and a repeat check is not.
  episode    integer not null default 0,
  updated_at timestamptz not null default now()
);

create index if not exists low_balance_state_user_idx on public.low_balance_state (user_id);
alter table public.low_balance_state enable row level security;


-- ---------------------------------------------------------------------------
-- 4. register_push_subscription(): one device, one owner
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER so that an endpoint registered earlier by someone else on a
-- shared browser moves to the user who is signed in now (a plain upsert under
-- RLS could not touch the other user's row). It trusts only auth.uid().
create or replace function public.register_push_subscription(
  p_endpoint   text,
  p_p256dh     text,
  p_auth       text,
  p_user_agent text,
  p_timezone   text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_had boolean;
  v_tz  text := coalesce(nullif(btrim(p_timezone), ''), 'UTC');
begin
  if v_uid is null then
    raise exception 'Not signed in' using errcode = '28000';
  end if;
  if p_endpoint is null or p_endpoint not like 'https://%' or char_length(p_endpoint) > 2048 then
    raise exception 'Invalid push endpoint' using errcode = '22023';
  end if;
  if p_p256dh is null or p_auth is null then
    raise exception 'Invalid push keys' using errcode = '22023';
  end if;
  if char_length(v_tz) > 64 then
    raise exception 'Invalid time zone' using errcode = '22023';
  end if;

  select exists (
    select 1 from public.push_subscriptions where user_id = v_uid and disabled_at is null
  ) into v_had;

  insert into public.push_subscriptions as s (user_id, endpoint, p256dh, auth, user_agent)
  values (v_uid, p_endpoint, p_p256dh, p_auth, left(p_user_agent, 400))
  on conflict (endpoint) do update
    set user_id      = v_uid,
        p256dh       = excluded.p256dh,
        auth         = excluded.auth,
        user_agent   = excluded.user_agent,
        last_seen_at = now(),
        disabled_at  = null;

  insert into public.notification_preferences (user_id, timezone)
  values (v_uid, v_tz)
  on conflict (user_id) do update
    set timezone = excluded.timezone, updated_at = now();

  -- A first device starts the low-balance watch from the balances as they are
  -- now: nothing is reported until an account actually falls below.
  if not v_had then
    delete from public.low_balance_state where user_id = v_uid;
  end if;
end;
$$;

revoke all on function public.register_push_subscription(text, text, text, text, text) from public, anon;
grant execute on function public.register_push_subscription(text, text, text, text, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. The schedule: every 15 minutes, call the Edge Function
-- ---------------------------------------------------------------------------
-- The function decides what is due for each user's own clock; running often
-- only bounds how late a notification can be. Reads the URL and the shared
-- secret from Vault, so neither is in this file or in git.
create or replace function public.invoke_push_notify()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url    text;
  v_secret text;
begin
  select decrypted_secret into v_url    from vault.decrypted_secrets where name = 'push_notify_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_notify_secret';
  if v_url is null or v_secret is null then
    raise notice 'push_notify_url / push_notify_secret are not in Vault yet; nothing sent';
    return;
  end if;

  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  );
end;
$$;

revoke all on function public.invoke_push_notify() from public, anon, authenticated;

do $$
begin
  begin
    create extension if not exists pg_cron;
    create extension if not exists pg_net;
  exception when others then
    raise notice 'Could not enable pg_cron / pg_net here (%). Enable them under Database → Extensions and run this file again.', sqlerrm;
  end;

  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'push-notify';
    perform cron.schedule('push-notify', '*/15 * * * *', 'select public.invoke_push_notify()');
  else
    raise notice 'pg_cron is not enabled, so the push-notify schedule was not created.';
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- ROLLBACK (manual; nothing else depends on these objects)
-- ---------------------------------------------------------------------------
--   select cron.unschedule(jobid) from cron.job where jobname = 'push-notify';
--   drop function if exists public.invoke_push_notify();
--   drop function if exists public.register_push_subscription(text, text, text, text, text);
--   drop table if exists public.low_balance_state, public.notification_log,
--     public.push_subscriptions, public.notification_preferences;
