-- ============================================================================
-- 005: Transaction treatments — own-account transfers, money lent, loan
--      repayments, and purchases paid on someone else's behalf
-- ============================================================================
--
-- Runs on the same Supabase project as mobile/supabase/001–003 and
-- ui/supabase/004, after them. Written for the web app; the phone app keeps
-- working unchanged.
--
-- SAFETY
--   * Additive only: one new table, one new nullable column, constraints every
--     existing row already satisfies, two guard triggers and two functions.
--     No DROP of existing objects, no data rewrite, no policy loosened.
--   * Idempotent: IF NOT EXISTS / CREATE OR REPLACE / DROP ... IF EXISTS, and
--     constraints added inside DO blocks that ignore "already exists", so
--     re-running the file is harmless.
--   * Backward compatible with the phone app, which neither reads nor writes
--     the new table or column. Every row it writes satisfies the new
--     constraints, and deleting anything from the phone cascades or unlinks
--     cleanly (see DESIGN).
--   * RLS on the new table with the same auth.uid() = user_id rule as 002/004.
--     Composite foreign keys guarantee a link can only point at the SAME
--     user's movement, expense or claim. Both functions run as the caller
--     (SECURITY INVOKER), so RLS applies to every statement inside them.
--   * Requires Postgres 15+ for ON DELETE SET NULL (column) (Supabase: 17).
--
-- DESIGN — every money movement is still stored exactly once
--   Balances keep coming from the ledger (account_transactions), and income
--   and spending keep coming from the income and expenses tables. A treatment
--   only decides which of those a movement is linked to:
--
--   own-account     → two ledger rows sharing transfer_group_id (as in 003): the
--   transfer          debit on one account and the credit on the other. Marking
--                     an imported row as a transfer either adds the other leg or
--                     links a row already on the other account (both
--                     statements imported), so nothing is counted twice. Never
--                     an expense or income.
--   money lent      → ONE plain ledger debit, plus a receivables row (kind
--                     'loan') naming the person. The balance goes down; it is
--                     not spending — it is money owed to you.
--   repayment /     → ONE plain ledger credit with receivable_id set. The
--   reimbursement     balance goes up; it is not income — it reduces what is
--                     owed.
--   paid on someone → the expense stays an expense (so a card's outstanding
--   else's behalf     and a bank balance stay right) plus a receivables row
--                     (kind 'reimbursable'). The web app leaves such expenses
--                     out of personal spending.
--
--   What is owed is derived, never stored:
--     outstanding = the claim's source amount (the lent debit, or the expense)
--                 − SUM(ledger credits whose receivable_id is the claim)
--   so partial repayments, edits and deletions recalculate on their own.
--
--   Deleting things never leaves a broken link:
--     * the lent debit or the reimbursable expense → its claim goes with it
--       (ON DELETE CASCADE); repayments already received stay as plain money in
--       (ON DELETE SET NULL), because that money really arrived;
--     * a repayment → only that credit goes; the claim's outstanding rises.
--
--   Changing a treatment is several writes (remove an expense, add the other
--   transfer leg, create a claim…). apply_bank_treatment() does all of them in
--   ONE transaction, so a failure part-way leaves nothing half-changed.
--
-- Run this once in the Supabase SQL editor, after 004.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 0. Ownership key
-- ---------------------------------------------------------------------------
-- id is already the primary key, so (id, user_id) is unique by definition.
-- Declaring it lets a claim reference the pair, which makes the database
-- refuse a link to another user's movement.
do $$
begin
  alter table public.account_transactions
    add constraint account_transactions_id_user_key unique (id, user_id);
exception
  when duplicate_table or duplicate_object then null;
end $$;


-- ---------------------------------------------------------------------------
-- 1. Receivables: money someone owes you
-- ---------------------------------------------------------------------------
-- kind 'loan'         — you lent money: ledger_entry_id is the debit that paid it.
-- kind 'reimbursable' — you paid for someone (on a card, from an account or in
--                       cash): expense_id is that purchase.
-- Exactly one source, and at most one claim per source. The amount is the
-- source's own amount — never copied here, so it cannot disagree.
create table if not exists public.receivables (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users (id) on delete cascade,
  kind            text not null check (kind in ('loan', 'reimbursable')),
  person          text not null check (char_length(btrim(person)) between 1 and 80),
  ledger_entry_id uuid,
  expense_id      uuid,
  due_date        date,
  note            text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint receivables_id_user_key unique (id, user_id),
  constraint receivables_ledger_entry_key unique (ledger_entry_id),
  constraint receivables_expense_key unique (expense_id),
  -- Deleting the lent debit or the purchase removes the claim with it.
  constraint receivables_ledger_entry_fk
    foreign key (ledger_entry_id, user_id)
    references public.account_transactions (id, user_id)
    on delete cascade,
  constraint receivables_expense_fk
    foreign key (expense_id, user_id)
    references public.expenses (id, user_id)
    on delete cascade,
  constraint receivables_source check (
    (kind = 'loan' and ledger_entry_id is not null and expense_id is null)
    or (kind = 'reimbursable' and expense_id is not null and ledger_entry_id is null)
  )
);

create index if not exists receivables_user_idx
  on public.receivables (user_id);


-- ---------------------------------------------------------------------------
-- 2. Repayments: a ledger credit that names the claim it settles
-- ---------------------------------------------------------------------------
-- NULL for every existing row. ON DELETE SET NULL: removing the claim keeps the
-- credit — the money did arrive — as plain money in.
alter table public.account_transactions
  add column if not exists receivable_id uuid;

do $$
begin
  alter table public.account_transactions
    add constraint account_transactions_receivable_fk
    foreign key (receivable_id, user_id)
    references public.receivables (id, user_id)
    on delete set null (receivable_id);
exception
  when duplicate_object then null;
end $$;

do $$
begin
  -- A repayment is money coming in. It is never an expense, an income, a
  -- transfer leg or a card bill payment at the same time — so it can never
  -- inflate income.
  alter table public.account_transactions
    add constraint account_transactions_settlement_shape
    check (
      receivable_id is null
      or (direction = 'credit' and expense_id is null and income_id is null
          and transfer_group_id is null and credit_card_id is null)
    );
exception
  when duplicate_object then null;
end $$;

create index if not exists account_transactions_receivable_idx
  on public.account_transactions (receivable_id)
  where receivable_id is not null;


-- ---------------------------------------------------------------------------
-- 3. Guards
-- ---------------------------------------------------------------------------
-- Money lent must stay a plain debit: if it also became an expense, a transfer
-- leg or a card payment, the same money would be counted twice.
create or replace function public.receivables_check_source()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.person := btrim(new.person);
  if new.ledger_entry_id is not null
     and (tg_op = 'INSERT' or new.ledger_entry_id is distinct from old.ledger_entry_id) then
    perform 1
      from public.account_transactions t
     where t.id = new.ledger_entry_id
       and t.user_id = new.user_id
       and t.direction = 'debit'
       and t.expense_id is null
       and t.income_id is null
       and t.transfer_group_id is null
       and t.credit_card_id is null;
    if not found then
      raise exception 'Only money going out of an account, not already recorded as something else, can be recorded as money lent.'
        using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists receivables_check_source on public.receivables;
create trigger receivables_check_source
  before insert or update on public.receivables
  for each row execute function public.receivables_check_source();

create or replace function public.account_transactions_keep_loan_shape()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.direction <> 'debit' or new.expense_id is not null or new.income_id is not null
      or new.transfer_group_id is not null or new.credit_card_id is not null)
     and exists (select 1 from public.receivables r where r.ledger_entry_id = new.id) then
    raise exception 'This debit is recorded as money lent. Change how it is recorded from its edit sheet instead.'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

drop trigger if exists account_transactions_keep_loan_shape on public.account_transactions;
create trigger account_transactions_keep_loan_shape
  before update of direction, expense_id, income_id, transfer_group_id, credit_card_id on public.account_transactions
  for each row execute function public.account_transactions_keep_loan_shape();


-- ---------------------------------------------------------------------------
-- 4. Applying a treatment — atomically
-- ---------------------------------------------------------------------------
-- p_treatment is a JSON object. "type" is one of:
--   plain        balance only (refund, cash withdrawal, cash deposit…)
--   expense      category_id (required), merchant, expense_description, notes,
--                payment_method_id, and reimbursable_person (+ due_date, note):
--                a person marks it paid on their behalf, null clears that
--   income       source, income_description
--   transfer     counterparty_account_id (required); match_entry_id links a row
--                already on that account instead of adding one;
--                counterpart_description labels an added leg
--   card_payment credit_card_id (required)
--   loan         person (required), due_date, note — money lent
--   settlement   receivable_id, or settle_entry_id (a lent debit or an
--                expense-backed debit), or settle_expense_id (+ person to mark
--                that purchase as paid for them) — a repayment / reimbursement
-- Optional on every type: amount, date, description (the movement's own text).
-- keep_previous_counterpart: when a transfer stops being one (or moves to
-- another account), keep the old other leg as a plain movement instead of
-- deleting it — for a leg that is really on that account's statement.
--
-- Errors are raised as P0001 with a message written for the user.
create or replace function public.apply_bank_treatment(p_entry_id uuid, p_treatment jsonb)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid           uuid := auth.uid();
  v_type          text := coalesce(p_treatment ->> 'type', '');
  e               public.account_transactions%rowtype;
  m               public.account_transactions%rowtype;
  v_partner       public.account_transactions%rowtype;
  v_has_partner   boolean := false;
  v_keep_transfer boolean := false;
  v_amount        numeric(14, 2);
  v_date          date;
  v_desc          text;
  v_loan_id       uuid;
  v_target        uuid;
  v_match         uuid;
  v_doc           uuid;
  v_category      uuid;
  v_card          uuid;
  v_person        text;
  v_receivable    uuid;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '42501';
  end if;
  if v_type not in ('plain', 'expense', 'income', 'transfer', 'card_payment', 'loan', 'settlement') then
    raise exception 'Choose how to record this transaction.' using errcode = 'P0001';
  end if;

  select * into e
    from public.account_transactions
   where id = p_entry_id and user_id = v_uid
   for update;
  if not found then
    raise exception 'That transaction no longer exists. Refresh and try again.' using errcode = 'P0001';
  end if;

  -- The movement's own figures.
  v_amount := coalesce((p_treatment ->> 'amount')::numeric(14, 2), e.amount);
  v_date := coalesce((p_treatment ->> 'date')::date, e.txn_date);
  v_desc := case
              when p_treatment ? 'description' then nullif(btrim(p_treatment ->> 'description'), '')
              else e.description
            end;
  if v_amount is null or v_amount <= 0 then
    raise exception 'Enter an amount greater than 0.' using errcode = 'P0001';
  end if;

  -- The direction is what the bank printed; a treatment must fit it.
  if v_type = 'expense' and e.direction <> 'debit' then
    raise exception 'Money coming in cannot be an expense.' using errcode = 'P0001';
  elsif v_type = 'income' and e.direction <> 'credit' then
    raise exception 'Money going out cannot be income.' using errcode = 'P0001';
  elsif v_type = 'card_payment' and e.direction <> 'debit' then
    raise exception 'Only money going out can pay a card bill.' using errcode = 'P0001';
  elsif v_type = 'loan' and e.direction <> 'debit' then
    raise exception 'Only money going out can be recorded as money lent.' using errcode = 'P0001';
  elsif v_type = 'settlement' and e.direction <> 'credit' then
    raise exception 'Only money coming in can repay a loan or reimburse you.' using errcode = 'P0001';
  end if;

  -- What it is now.
  select id into v_loan_id from public.receivables where ledger_entry_id = e.id and user_id = v_uid for update;
  if e.transfer_group_id is not null then
    select * into v_partner
      from public.account_transactions
     where transfer_group_id = e.transfer_group_id and id <> e.id and user_id = v_uid
     for update;
    v_has_partner := found;
  end if;

  if v_type = 'transfer' then
    v_target := nullif(p_treatment ->> 'counterparty_account_id', '')::uuid;
    v_match := nullif(p_treatment ->> 'match_entry_id', '')::uuid;
    if v_target is null then
      raise exception 'Choose the account on the other side of the transfer.' using errcode = 'P0001';
    end if;
    if v_target = e.account_id then
      raise exception 'Pick a different account. Money cannot move to the account it came from.' using errcode = 'P0001';
    end if;
    perform 1 from public.bank_accounts where id = v_target and user_id = v_uid;
    if not found then
      raise exception 'That account no longer exists. Refresh and try again.' using errcode = 'P0001';
    end if;
    -- Same other account and no different match: the transfer stays, only its figures change.
    v_keep_transfer := v_has_partner and v_partner.account_id = v_target and (v_match is null or v_match = v_partner.id);
  end if;

  -- 1. Undo what it is now, unless it stays that.

  if e.expense_id is not null and v_type <> 'expense' then
    v_doc := e.expense_id;
    -- Unlink first: the expense's ON DELETE CASCADE would otherwise take this movement with it.
    update public.account_transactions set expense_id = null, category_id = null where id = e.id;
    delete from public.expenses where id = v_doc and user_id = v_uid;
    e.expense_id := null;
    e.category_id := null;
  end if;

  if e.income_id is not null and v_type <> 'income' then
    v_doc := e.income_id;
    update public.account_transactions set income_id = null where id = e.id;
    delete from public.income where id = v_doc and user_id = v_uid;
    e.income_id := null;
  end if;

  if e.transfer_group_id is not null and not v_keep_transfer then
    if v_has_partner then
      if coalesce((p_treatment ->> 'keep_previous_counterpart')::boolean, false) then
        update public.account_transactions
           set transfer_group_id = null, counterparty_account_id = null
         where id = v_partner.id;
      else
        delete from public.account_transactions where id = v_partner.id;
      end if;
    end if;
    update public.account_transactions
       set transfer_group_id = null, counterparty_account_id = null
     where id = e.id;
    e.transfer_group_id := null;
    e.counterparty_account_id := null;
  end if;

  if e.credit_card_id is not null
     and (v_type <> 'card_payment' or nullif(p_treatment ->> 'credit_card_id', '')::uuid is distinct from e.credit_card_id) then
    update public.account_transactions set credit_card_id = null where id = e.id;
    e.credit_card_id := null;
  end if;

  if e.receivable_id is not null and v_type <> 'settlement' then
    update public.account_transactions set receivable_id = null where id = e.id;
    e.receivable_id := null;
  end if;

  if v_loan_id is not null and v_type <> 'loan' then
    -- Repayments already received stay as plain money in (ON DELETE SET NULL).
    delete from public.receivables where id = v_loan_id;
    v_loan_id := null;
  end if;

  -- 2. Make it what it should be.

  if v_type = 'expense' then
    v_category := nullif(p_treatment ->> 'category_id', '')::uuid;
    if v_category is null then
      raise exception 'Choose a category for this expense.' using errcode = 'P0001';
    end if;
    perform 1 from public.categories where id = v_category and user_id = v_uid;
    if not found then
      raise exception 'That category no longer exists. Refresh and try again.' using errcode = 'P0001';
    end if;
    if e.expense_id is not null then
      update public.expenses
         set amount = v_amount,
             expense_date = v_date,
             category_id = v_category,
             bank_account_id = e.account_id,
             merchant = case when p_treatment ? 'merchant' then nullif(btrim(p_treatment ->> 'merchant'), '') else merchant end,
             description = case when p_treatment ? 'expense_description' then nullif(btrim(p_treatment ->> 'expense_description'), '') else description end,
             notes = case when p_treatment ? 'notes' then nullif(btrim(p_treatment ->> 'notes'), '') else notes end,
             payment_method_id = case when p_treatment ? 'payment_method_id' then nullif(p_treatment ->> 'payment_method_id', '')::uuid else payment_method_id end,
             updated_at = now()
       where id = e.expense_id and user_id = v_uid;
    else
      insert into public.expenses (user_id, amount, expense_date, category_id, payment_method_id, bank_account_id, merchant, description, notes)
      values (
        v_uid, v_amount, v_date, v_category,
        nullif(p_treatment ->> 'payment_method_id', '')::uuid,
        e.account_id,
        nullif(btrim(p_treatment ->> 'merchant'), ''),
        nullif(btrim(p_treatment ->> 'expense_description'), ''),
        nullif(btrim(p_treatment ->> 'notes'), '')
      )
      returning id into v_doc;
      e.expense_id := v_doc;
    end if;
    e.category_id := v_category;

    if p_treatment ? 'reimbursable_person' then
      v_person := nullif(btrim(p_treatment ->> 'reimbursable_person'), '');
      if v_person is null then
        delete from public.receivables where expense_id = e.expense_id and user_id = v_uid;
      else
        insert into public.receivables (user_id, kind, person, expense_id, due_date, note)
        values (v_uid, 'reimbursable', v_person, e.expense_id,
                nullif(p_treatment ->> 'due_date', '')::date, nullif(btrim(p_treatment ->> 'note'), ''))
        on conflict (expense_id) do update
          set person = excluded.person, due_date = excluded.due_date, note = excluded.note, updated_at = now();
      end if;
    end if;

  elsif v_type = 'income' then
    if e.income_id is not null then
      update public.income
         set amount = v_amount,
             income_date = v_date,
             bank_account_id = e.account_id,
             source = case when p_treatment ? 'source' then nullif(btrim(p_treatment ->> 'source'), '') else source end,
             description = case when p_treatment ? 'income_description' then nullif(btrim(p_treatment ->> 'income_description'), '') else description end
       where id = e.income_id and user_id = v_uid;
    else
      insert into public.income (user_id, amount, income_date, source, description, bank_account_id)
      values (v_uid, v_amount, v_date,
              nullif(btrim(p_treatment ->> 'source'), ''),
              nullif(btrim(p_treatment ->> 'income_description'), ''),
              e.account_id)
      returning id into v_doc;
      e.income_id := v_doc;
    end if;

  elsif v_type = 'transfer' then
    if v_keep_transfer then
      -- Both legs always carry the same amount.
      if v_partner.amount <> v_amount then
        update public.account_transactions set amount = v_amount where id = v_partner.id;
      end if;
    else
      e.transfer_group_id := gen_random_uuid();
      e.counterparty_account_id := v_target;
      if v_match is not null then
        select * into m
          from public.account_transactions
         where id = v_match and user_id = v_uid
         for update;
        if not found or m.id = e.id or m.account_id <> v_target or m.direction = e.direction then
          raise exception 'The matching transaction on the other account is no longer available. Refresh and try again.' using errcode = 'P0001';
        end if;
        if m.transfer_group_id is not null or m.credit_card_id is not null or m.receivable_id is not null
           or exists (select 1 from public.receivables r where r.ledger_entry_id = m.id) then
          raise exception 'The matching transaction on the other account is already linked to something else.' using errcode = 'P0001';
        end if;
        if m.amount <> v_amount then
          raise exception 'The matching transaction on the other account is for a different amount.' using errcode = 'P0001';
        end if;
        -- It was recorded as spending or income; as a transfer leg it is neither.
        if m.expense_id is not null then
          v_doc := m.expense_id;
          update public.account_transactions set expense_id = null, category_id = null where id = m.id;
          delete from public.expenses where id = v_doc and user_id = v_uid;
        end if;
        if m.income_id is not null then
          v_doc := m.income_id;
          update public.account_transactions set income_id = null where id = m.id;
          delete from public.income where id = v_doc and user_id = v_uid;
        end if;
        update public.account_transactions
           set transfer_group_id = e.transfer_group_id, counterparty_account_id = e.account_id
         where id = m.id;
      else
        insert into public.account_transactions
          (user_id, account_id, direction, amount, txn_date, description, transfer_group_id, counterparty_account_id)
        values (
          v_uid, v_target,
          case when e.direction = 'debit' then 'credit' else 'debit' end,
          v_amount, v_date,
          nullif(btrim(p_treatment ->> 'counterpart_description'), ''),
          e.transfer_group_id, e.account_id
        );
      end if;
    end if;

  elsif v_type = 'card_payment' then
    v_card := nullif(p_treatment ->> 'credit_card_id', '')::uuid;
    if v_card is null then
      raise exception 'Choose the card this paid.' using errcode = 'P0001';
    end if;
    perform 1 from public.credit_cards where id = v_card and user_id = v_uid;
    if not found then
      raise exception 'That card no longer exists. Refresh and try again.' using errcode = 'P0001';
    end if;
    e.credit_card_id := v_card;

  elsif v_type = 'loan' then
    v_person := nullif(btrim(p_treatment ->> 'person'), '');
    if v_person is null then
      raise exception 'Add who you lent the money to.' using errcode = 'P0001';
    end if;
    if v_loan_id is not null then
      update public.receivables
         set person = v_person,
             due_date = nullif(p_treatment ->> 'due_date', '')::date,
             note = nullif(btrim(p_treatment ->> 'note'), ''),
             updated_at = now()
       where id = v_loan_id;
    else
      -- The movement is a plain debit by now (step 1), which the claim's guard requires.
      insert into public.receivables (user_id, kind, person, ledger_entry_id, due_date, note)
      values (v_uid, 'loan', v_person, e.id,
              nullif(p_treatment ->> 'due_date', '')::date, nullif(btrim(p_treatment ->> 'note'), ''));
    end if;

  elsif v_type = 'settlement' then
    v_receivable := nullif(p_treatment ->> 'receivable_id', '')::uuid;
    if v_receivable is null and nullif(p_treatment ->> 'settle_entry_id', '') is not null then
      -- A movement recorded moments ago (same import): the loan it is, or its expense's claim.
      select r.id into v_receivable
        from public.account_transactions s
        join public.receivables r
          on r.ledger_entry_id = s.id or (s.expense_id is not null and r.expense_id = s.expense_id)
       where s.id = (p_treatment ->> 'settle_entry_id')::uuid and s.user_id = v_uid and r.user_id = v_uid
       limit 1;
    end if;
    if v_receivable is null and nullif(p_treatment ->> 'settle_expense_id', '') is not null then
      v_doc := (p_treatment ->> 'settle_expense_id')::uuid;
      select id into v_receivable from public.receivables where expense_id = v_doc and user_id = v_uid;
      if v_receivable is null then
        -- First money back for this purchase: it was paid on their behalf.
        v_person := nullif(btrim(p_treatment ->> 'person'), '');
        if v_person is null then
          raise exception 'Add who is paying you back.' using errcode = 'P0001';
        end if;
        perform 1 from public.expenses where id = v_doc and user_id = v_uid;
        if not found then
          raise exception 'That purchase no longer exists. Refresh and try again.' using errcode = 'P0001';
        end if;
        insert into public.receivables (user_id, kind, person, expense_id)
        values (v_uid, 'reimbursable', v_person, v_doc)
        returning id into v_receivable;
      end if;
    end if;
    if v_receivable is null then
      raise exception 'Choose the loan or purchase this pays back.' using errcode = 'P0001';
    end if;
    perform 1 from public.receivables where id = v_receivable and user_id = v_uid;
    if not found then
      raise exception 'That loan or purchase is no longer available. Refresh and try again.' using errcode = 'P0001';
    end if;
    e.receivable_id := v_receivable;
  end if;

  -- 3. The movement's final shape, in one write.
  update public.account_transactions
     set amount = v_amount,
         txn_date = v_date,
         description = v_desc,
         category_id = e.category_id,
         expense_id = e.expense_id,
         income_id = e.income_id,
         transfer_group_id = e.transfer_group_id,
         counterparty_account_id = e.counterparty_account_id,
         credit_card_id = e.credit_card_id,
         receivable_id = e.receivable_id
   where id = e.id;

  return e.id;
end;
$$;

-- A new movement and its treatment, in one transaction: a statement import
-- can never leave a transfer with one leg, or money lent without its claim.
create or replace function public.record_bank_movement(
  p_account_id  uuid,
  p_direction   text,
  p_amount      numeric,
  p_date        date,
  p_description text,
  p_treatment   jsonb
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id  uuid;
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '42501';
  end if;
  perform 1 from public.bank_accounts where id = p_account_id and user_id = v_uid;
  if not found then
    raise exception 'That account no longer exists. Refresh and try again.' using errcode = 'P0001';
  end if;
  insert into public.account_transactions (user_id, account_id, direction, amount, txn_date, description)
  values (v_uid, p_account_id, p_direction, p_amount, p_date, nullif(btrim(p_description), ''))
  returning id into v_id;
  return public.apply_bank_treatment(v_id, p_treatment);
end;
$$;


-- ---------------------------------------------------------------------------
-- 5. Access: signed-in users only, and only their own rows
-- ---------------------------------------------------------------------------
grant select, insert, update, delete on public.receivables to authenticated;

revoke all on function public.apply_bank_treatment(uuid, jsonb) from public, anon;
grant execute on function public.apply_bank_treatment(uuid, jsonb) to authenticated;
revoke all on function public.record_bank_movement(uuid, text, numeric, date, text, jsonb) from public, anon;
grant execute on function public.record_bank_movement(uuid, text, numeric, date, text, jsonb) to authenticated;

alter table public.receivables enable row level security;

drop policy if exists receivables_select_own on public.receivables;
create policy receivables_select_own on public.receivables
  for select using (auth.uid() = user_id);

drop policy if exists receivables_insert_own on public.receivables;
create policy receivables_insert_own on public.receivables
  for insert with check (auth.uid() = user_id);

drop policy if exists receivables_update_own on public.receivables;
create policy receivables_update_own on public.receivables
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists receivables_delete_own on public.receivables;
create policy receivables_delete_own on public.receivables
  for delete using (auth.uid() = user_id);


-- ---------------------------------------------------------------------------
-- Rollback (not run). Only if you want to remove the feature and its data:
-- claims disappear, repayments stay as plain money in and transfers stay
-- transfers, so no bank balance changes.
--
--   drop function if exists public.record_bank_movement(uuid, text, numeric, date, text, jsonb);
--   drop function if exists public.apply_bank_treatment(uuid, jsonb);
--   drop trigger if exists account_transactions_keep_loan_shape on public.account_transactions;
--   drop function if exists public.account_transactions_keep_loan_shape();
--   alter table public.account_transactions drop constraint if exists account_transactions_settlement_shape;
--   alter table public.account_transactions drop constraint if exists account_transactions_receivable_fk;
--   alter table public.account_transactions drop column if exists receivable_id;
--   drop table if exists public.receivables;   -- also drops its trigger
--   drop function if exists public.receivables_check_source();
--   alter table public.account_transactions drop constraint if exists account_transactions_id_user_key;
-- ---------------------------------------------------------------------------
