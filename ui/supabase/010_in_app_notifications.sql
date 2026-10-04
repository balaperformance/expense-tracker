-- ============================================================================
-- 010: In-app notification history — what each push said, and whether the
--      user has read it in the app
-- ============================================================================
--
-- Runs after 008 (web push); 009 (mobile push tokens) is not needed. The web app shows
-- every notification the sender produced under a bell in its header, so the
-- history is there whether or not a device was open, subscribed or online.
--
-- DESIGN
--   No new table. notification_log (008) already holds one row per
--   notification the sender produced, keyed (user_id, event_key) and written
--   by the push-notify Edge Function before it sends. This adds what the
--   message said and when the user read it:
--     title, body, url   written by the sender just before it sends
--     read_at            set by the user from the app; null means unread
--   Rows written before this migration have no text; the app labels them by
--   their kind. Rows are pruned by the sender after 120 days, as before.
--
-- SAFETY
--   * Additive only: four nullable columns, one index, two policies, grants.
--     Delivery, de-duplication and the schedule are unchanged.
--   * Idempotent: IF NOT EXISTS / DROP POLICY IF EXISTS, so re-running is
--     harmless.
--   * RLS stays on. A user can read only their own rows, and can change only
--     read_at on them (a column-level grant): never the text, the kind, the
--     key or the owner. Inserts and deletes remain the service role's alone.
--   * The phone app neither reads nor writes any of this.
--
-- Run this once in the Supabase SQL editor, after 008. Then redeploy push-notify.
-- ============================================================================

alter table public.notification_log
  add column if not exists title   text check (title is null or char_length(title) <= 200),
  add column if not exists body    text check (body is null or char_length(body) <= 1000),
  -- A path inside the app, never another site.
  add column if not exists url     text check (url is null or (url like '/%' and url not like '//%' and char_length(url) <= 200)),
  add column if not exists read_at timestamptz;

-- The bell lists a user's newest first.
create index if not exists notification_log_user_sent_idx
  on public.notification_log (user_id, sent_at desc);

-- Read their own history; mark it read. Nothing else.
grant select on public.notification_log to authenticated;
revoke insert, update, delete on public.notification_log from authenticated;
grant update (read_at) on public.notification_log to authenticated;

drop policy if exists notification_log_select_own on public.notification_log;
create policy notification_log_select_own on public.notification_log
  for select using (auth.uid() = user_id);

drop policy if exists notification_log_update_own on public.notification_log;
create policy notification_log_update_own on public.notification_log
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);


-- ---------------------------------------------------------------------------
-- ROLLBACK (manual)
-- ---------------------------------------------------------------------------
--   drop policy if exists notification_log_update_own on public.notification_log;
--   drop policy if exists notification_log_select_own on public.notification_log;
--   revoke select, update on public.notification_log from authenticated;
--   drop index if exists public.notification_log_user_sent_idx;
--   alter table public.notification_log
--     drop column if exists read_at, drop column if exists url,
--     drop column if exists body, drop column if exists title;
