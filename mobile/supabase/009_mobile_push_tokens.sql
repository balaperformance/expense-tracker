-- ============================================================================
-- 009: Push notifications on the phone — Firebase Cloud Messaging tokens
-- ============================================================================
--
-- Runs on the same Supabase project, after ui/supabase/008_push_notifications.sql
-- (it needs 008's notification_preferences and low_balance_state).
--
-- The web app receives its notifications through Web Push (008's
-- push_subscriptions). The Android app receives the very same notifications
-- through Firebase Cloud Messaging: the one `push-notify` Edge Function
-- decides what is due for each user and sends it to every device they have —
-- browsers over Web Push, phones over FCM — under ONE event key, so a
-- notification is never sent twice and the four switches are shared.
--
-- SAFETY
--   * Additive only: one new table and one new function. Nothing in 001–008 is
--     altered; the web app keeps working exactly as before.
--   * Idempotent: IF NOT EXISTS / CREATE OR REPLACE / DROP POLICY IF EXISTS.
--   * RLS: a user can read and remove only their own devices. Registration
--     goes through register_mobile_push_token(), which trusts only auth.uid()
--     and moves a token to whoever is signed in on that phone now.
--   * Nothing secret is stored: an FCM registration token only lets the
--     project's own server (which holds the Firebase service account) reach
--     that app install.
--
-- Run this once in the Supabase SQL editor, after 008.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Device tokens
-- ---------------------------------------------------------------------------
create table if not exists public.mobile_push_tokens (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade,
  token        text not null unique check (char_length(token) between 20 and 4096),
  platform     text not null default 'android' check (platform in ('android', 'ios')),
  app_version  text check (app_version is null or char_length(app_version) <= 40),
  device       text check (device is null or char_length(device) <= 120),
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  -- Set by the sender when FCM says the token is gone (UNREGISTERED); revived
  -- if the same install registers again.
  disabled_at  timestamptz
);

create index if not exists mobile_push_tokens_user_idx
  on public.mobile_push_tokens (user_id) where disabled_at is null;

-- No insert/update policy on purpose: registration goes through the function
-- below. A user may read and remove their own devices.
grant select, delete on public.mobile_push_tokens to authenticated;
alter table public.mobile_push_tokens enable row level security;

drop policy if exists mobile_push_tokens_select_own on public.mobile_push_tokens;
create policy mobile_push_tokens_select_own on public.mobile_push_tokens
  for select using (auth.uid() = user_id);

drop policy if exists mobile_push_tokens_delete_own on public.mobile_push_tokens;
create policy mobile_push_tokens_delete_own on public.mobile_push_tokens
  for delete using (auth.uid() = user_id);


-- ---------------------------------------------------------------------------
-- 2. register_mobile_push_token(): one install, one owner
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER so that a token registered earlier by someone else on the
-- same phone moves to the user signed in now (a plain upsert under RLS could
-- not touch the other user's row). It trusts only auth.uid(). Also records the
-- phone's time zone — "10 PM" is decided per user from it — exactly like
-- 008's register_push_subscription().
create or replace function public.register_mobile_push_token(
  p_token       text,
  p_platform    text,
  p_timezone    text,
  p_app_version text,
  p_device      text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_had      boolean;
  v_tz       text := coalesce(nullif(btrim(p_timezone), ''), 'UTC');
  v_platform text := coalesce(nullif(btrim(p_platform), ''), 'android');
begin
  if v_uid is null then
    raise exception 'Not signed in' using errcode = '28000';
  end if;
  if p_token is null or char_length(p_token) not between 20 and 4096 then
    raise exception 'Invalid push token' using errcode = '22023';
  end if;
  if v_platform not in ('android', 'ios') then
    raise exception 'Invalid platform' using errcode = '22023';
  end if;
  if char_length(v_tz) > 64 then
    raise exception 'Invalid time zone' using errcode = '22023';
  end if;

  -- Any device of the user's at all — a browser (008) or a phone.
  select exists (
           select 1 from public.mobile_push_tokens
            where user_id = v_uid and disabled_at is null
         )
      or exists (
           select 1 from public.push_subscriptions
            where user_id = v_uid and disabled_at is null
         )
    into v_had;

  insert into public.mobile_push_tokens as t (user_id, token, platform, app_version, device)
  values (v_uid, p_token, v_platform, left(p_app_version, 40), left(p_device, 120))
  on conflict (token) do update
    set user_id      = v_uid,
        platform     = excluded.platform,
        app_version  = excluded.app_version,
        device       = excluded.device,
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

revoke all on function public.register_mobile_push_token(text, text, text, text, text) from public, anon;
grant execute on function public.register_mobile_push_token(text, text, text, text, text) to authenticated;


-- ---------------------------------------------------------------------------
-- ROLLBACK (manual; nothing else depends on these objects)
-- ---------------------------------------------------------------------------
--   drop function if exists public.register_mobile_push_token(text, text, text, text, text);
--   drop table if exists public.mobile_push_tokens;
