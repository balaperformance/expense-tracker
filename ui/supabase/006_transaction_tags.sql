-- ============================================================================
-- 006: Tags on expenses and income
-- ============================================================================
--
-- Runs on the same Supabase project as mobile/supabase/001–003 and
-- ui/supabase/004–005, after them. Written for the web app; the phone app
-- keeps working unchanged.
--
-- SAFETY
--   * Additive only: three new tables, one new unique key on income, one
--     function. No DROP of existing objects, no data rewrite, no policy
--     loosened. Nothing about money (balances, spending, income, transfers,
--     claims) is touched.
--   * Idempotent: IF NOT EXISTS / CREATE OR REPLACE / DROP POLICY IF EXISTS, and
--     the one constraint is added inside a DO block that ignores "already
--     exists", so re-running the file is harmless.
--   * Backward compatible with the phone app, which neither reads nor writes
--     the new tables. Deleting an expense or income from the phone removes its
--     tag links too (ON DELETE CASCADE).
--   * RLS on every new table with the same auth.uid() = user_id rule as
--     002/004/005. Composite foreign keys guarantee a link can only join the
--     SAME user's transaction to the SAME user's tag. The function runs as the
--     caller (SECURITY INVOKER), so RLS applies to every statement inside it.
--
-- DESIGN
--   tags          one row per tag per user. Names are unique per user ignoring
--                 case, so "CarSpending" and "carspending" are the same tag.
--   expense_tags  links an expense to its tags.
--   income_tags   links an income row to its tags.
--
--   set_transaction_tags(kind, id, names) is the only write the app makes. In
--   ONE transaction it finds each named tag or creates it, then makes the
--   transaction's links exactly that set. A tag that no longer has any link
--   after being removed from a transaction is deleted, so a mistyped tag does
--   not linger as a suggestion; a tag still used anywhere is never deleted.
--
-- Run this once in the Supabase SQL editor, after 005.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 0. Ownership key on income
-- ---------------------------------------------------------------------------
-- 004 gave expenses (id, user_id); income has none yet. id is the primary key,
-- so the pair is unique by definition. Declaring it lets a link reference the
-- pair, which makes the database refuse a link to another user's income.
do $$
begin
  alter table public.income
    add constraint income_id_user_key unique (id, user_id);
exception
  when duplicate_table or duplicate_object then null;
end $$;

-- Same for expenses, in case 004 has not been applied (this migration does not
-- need cards, only expenses).
do $$
begin
  alter table public.expenses
    add constraint expenses_id_user_key unique (id, user_id);
exception
  when duplicate_table or duplicate_object then null;
end $$;


-- ---------------------------------------------------------------------------
-- 1. Tags
-- ---------------------------------------------------------------------------
create table if not exists public.tags (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  name       text not null check (name = btrim(name) and char_length(name) between 1 and 40),
  created_at timestamptz not null default now(),
  constraint tags_id_user_key unique (id, user_id)
);

-- One tag per name per user, whatever the letter case.
create unique index if not exists tags_user_name_key
  on public.tags (user_id, lower(name));


-- ---------------------------------------------------------------------------
-- 2. Links
-- ---------------------------------------------------------------------------
create table if not exists public.expense_tags (
  expense_id uuid not null,
  tag_id     uuid not null,
  user_id    uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (expense_id, tag_id),
  constraint expense_tags_expense_fk
    foreign key (expense_id, user_id)
    references public.expenses (id, user_id)
    on delete cascade,
  constraint expense_tags_tag_fk
    foreign key (tag_id, user_id)
    references public.tags (id, user_id)
    on delete cascade
);

create index if not exists expense_tags_tag_idx
  on public.expense_tags (tag_id);

create table if not exists public.income_tags (
  income_id  uuid not null,
  tag_id     uuid not null,
  user_id    uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (income_id, tag_id),
  constraint income_tags_income_fk
    foreign key (income_id, user_id)
    references public.income (id, user_id)
    on delete cascade,
  constraint income_tags_tag_fk
    foreign key (tag_id, user_id)
    references public.tags (id, user_id)
    on delete cascade
);

create index if not exists income_tags_tag_idx
  on public.income_tags (tag_id);


-- ---------------------------------------------------------------------------
-- 3. Setting a transaction's tags — atomically
-- ---------------------------------------------------------------------------
-- p_kind  'expense' or 'income'
-- p_names the complete list of tag names the transaction should have. Names are
--         cleaned the way the app cleans them (a leading # is dropped, runs of
--         spaces collapse, blanks and repeats are ignored; repeats are matched
--         ignoring case). A name that matches an existing tag reuses it, with
--         that tag's own spelling; any other name creates a new tag.
--
-- Errors are raised as P0001 with a message written for the user.
create or replace function public.set_transaction_tags(p_kind text, p_id uuid, p_names text[])
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_names   text[];
  v_name    text;
  v_tag     uuid;
  v_ids     uuid[] := '{}';
  v_removed uuid[];
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '42501';
  end if;
  if p_kind not in ('expense', 'income') then
    raise exception 'Tags can only be added to expenses and income.' using errcode = 'P0001';
  end if;

  if p_kind = 'expense' then
    perform 1 from public.expenses where id = p_id and user_id = v_uid;
  else
    perform 1 from public.income where id = p_id and user_id = v_uid;
  end if;
  if not found then
    raise exception 'That transaction no longer exists. Refresh and try again.' using errcode = 'P0001';
  end if;

  -- Clean, drop blanks, and keep the first of any repeats (case-insensitively), in order.
  select coalesce(array_agg(c.name order by c.pos), '{}')
    into v_names
    from (
      select distinct on (lower(x.name)) x.name, x.pos
        from (
          select btrim(regexp_replace(regexp_replace(t.raw, '^\s*#+', ''), '\s+', ' ', 'g')) as name,
                 t.pos
            from unnest(coalesce(p_names, '{}'::text[])) with ordinality as t(raw, pos)
        ) x
       where x.name <> ''
       order by lower(x.name), x.pos
    ) c;

  if coalesce(array_length(v_names, 1), 0) > 20 then
    raise exception 'A transaction can have up to 20 tags.' using errcode = 'P0001';
  end if;

  foreach v_name in array v_names loop
    if char_length(v_name) > 40 then
      raise exception 'A tag can be at most 40 characters.' using errcode = 'P0001';
    end if;
    select g.id into v_tag from public.tags g where g.user_id = v_uid and lower(g.name) = lower(v_name);
    if v_tag is null then
      insert into public.tags (user_id, name)
      values (v_uid, v_name)
      on conflict (user_id, lower(name)) do nothing
      returning id into v_tag;
      if v_tag is null then
        -- Created by a request that ran at the same moment.
        select g.id into v_tag from public.tags g where g.user_id = v_uid and lower(g.name) = lower(v_name);
      end if;
    end if;
    v_ids := v_ids || v_tag;
  end loop;

  if p_kind = 'expense' then
    with gone as (
      delete from public.expense_tags l
       where l.expense_id = p_id and l.user_id = v_uid and l.tag_id <> all (v_ids)
      returning l.tag_id
    )
    select array_agg(gone.tag_id) into v_removed from gone;

    insert into public.expense_tags (expense_id, tag_id, user_id)
    select p_id, t.tag_id, v_uid from unnest(v_ids) as t(tag_id)
    on conflict do nothing;
  else
    with gone as (
      delete from public.income_tags l
       where l.income_id = p_id and l.user_id = v_uid and l.tag_id <> all (v_ids)
      returning l.tag_id
    )
    select array_agg(gone.tag_id) into v_removed from gone;

    insert into public.income_tags (income_id, tag_id, user_id)
    select p_id, t.tag_id, v_uid from unnest(v_ids) as t(tag_id)
    on conflict do nothing;
  end if;

  -- A tag taken off this transaction that nothing else uses is dropped.
  if v_removed is not null then
    delete from public.tags g
     where g.user_id = v_uid
       and g.id = any (v_removed)
       and not exists (select 1 from public.expense_tags l where l.tag_id = g.id)
       and not exists (select 1 from public.income_tags l where l.tag_id = g.id);
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- 4. Access: signed-in users only, and only their own rows
-- ---------------------------------------------------------------------------
grant select, insert, update, delete on public.tags to authenticated;
grant select, insert, update, delete on public.expense_tags to authenticated;
grant select, insert, update, delete on public.income_tags to authenticated;

revoke all on function public.set_transaction_tags(text, uuid, text[]) from public, anon;
grant execute on function public.set_transaction_tags(text, uuid, text[]) to authenticated;

alter table public.tags enable row level security;
alter table public.expense_tags enable row level security;
alter table public.income_tags enable row level security;

drop policy if exists tags_select_own on public.tags;
create policy tags_select_own on public.tags
  for select using (auth.uid() = user_id);

drop policy if exists tags_insert_own on public.tags;
create policy tags_insert_own on public.tags
  for insert with check (auth.uid() = user_id);

drop policy if exists tags_update_own on public.tags;
create policy tags_update_own on public.tags
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists tags_delete_own on public.tags;
create policy tags_delete_own on public.tags
  for delete using (auth.uid() = user_id);

drop policy if exists expense_tags_select_own on public.expense_tags;
create policy expense_tags_select_own on public.expense_tags
  for select using (auth.uid() = user_id);

drop policy if exists expense_tags_insert_own on public.expense_tags;
create policy expense_tags_insert_own on public.expense_tags
  for insert with check (auth.uid() = user_id);

drop policy if exists expense_tags_delete_own on public.expense_tags;
create policy expense_tags_delete_own on public.expense_tags
  for delete using (auth.uid() = user_id);

drop policy if exists income_tags_select_own on public.income_tags;
create policy income_tags_select_own on public.income_tags
  for select using (auth.uid() = user_id);

drop policy if exists income_tags_insert_own on public.income_tags;
create policy income_tags_insert_own on public.income_tags
  for insert with check (auth.uid() = user_id);

drop policy if exists income_tags_delete_own on public.income_tags;
create policy income_tags_delete_own on public.income_tags
  for delete using (auth.uid() = user_id);


-- ---------------------------------------------------------------------------
-- Rollback (not run). Removes the feature and its data; expenses, income and
-- every balance are unchanged. The unique keys added to expenses/income are
-- harmless and may stay.
--
--   drop function if exists public.set_transaction_tags(text, uuid, text[]);
--   drop table if exists public.expense_tags;
--   drop table if exists public.income_tags;
--   drop table if exists public.tags;
-- ---------------------------------------------------------------------------
