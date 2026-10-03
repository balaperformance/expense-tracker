-- ============================================================================
-- 004: Credit cards
-- ============================================================================
--
-- Runs on the same Supabase project as mobile/supabase/001–003, after them.
-- Written for the web app; the phone app keeps working unchanged.
--
-- SAFETY
--   * Additive only: two new tables, two new nullable columns, constraints
--     every existing row already satisfies, one trigger. No DROP of existing
--     objects, no data rewrite, no policy loosened.
--   * Idempotent: IF NOT EXISTS / CREATE OR REPLACE / DROP ... IF EXISTS, and
--     constraints added inside DO blocks that ignore "already exists", so
--     re-running the file is harmless.
--   * Backward compatible with the phone app, which neither reads nor writes
--     the new columns. Its expense and ledger writes leave them untouched, and
--     every balance it derives stays correct (see DESIGN).
--   * RLS on both new tables with the same auth.uid() = user_id rule as 002.
--     Composite foreign keys also guarantee that a row can only point at the
--     SAME user's card, bank account or expense.
--   * Requires Postgres 15+ for ON DELETE SET NULL (column) (Supabase: 17).
--
-- DESIGN — every money movement is stored exactly once
--   purchase      → an expenses row with credit_card_id set and
--                   bank_account_id NULL: no bank ledger row, so no bank balance
--                   moves. It is still an expense, so Dashboard, Reports and
--                   Budgets count it as spending.
--   bill payment  → ONE account_transactions debit on the paying account with
--   from an         credit_card_id set. That single row lowers the bank balance
--   account         (as every ledger debit already does, on web and phone) and
--                   lowers the card outstanding, so the two sides cannot
--                   disagree. No expenses row: a bill payment is never spending.
--   bill payment  → ONE credit_card_transactions row (kind 'payment'), because
--   in cash         cash is not an account (see 002).
--   refund, cashback, fee, interest, adjustment
--                 → ONE credit_card_transactions row.
--
--   Card outstanding is derived, never stored, exactly like a bank balance:
--     opening_outstanding
--     + purchases                      (expenses.credit_card_id)
--     + credit_card_transactions debits  (fee, interest, debit adjustment)
--     − credit_card_transactions credits (refund, cashback, cash payment, credit adjustment)
--     − account_transactions debits with credit_card_id   (bill payments)
--
--   Reconciliation. A bank-statement import already stores a card bill as a
--   plain ledger debit on the bank account. Recognising it as a bill payment
--   is a single UPDATE of account_transactions.credit_card_id — no new row —
--   and the card statement picks it up at once. issuer, last4 and
--   payment_account_id are what a matcher uses to pick the right card.
--
-- Run this once in the Supabase SQL editor.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 0. Ownership keys
-- ---------------------------------------------------------------------------
-- id is already the primary key, so (id, user_id) is unique by definition.
-- Declaring it lets child rows reference the pair, which makes the database
-- refuse a link to another user's account or expense.
do $$
begin
  alter table public.bank_accounts
    add constraint bank_accounts_id_user_key unique (id, user_id);
exception
  when duplicate_table or duplicate_object then null;
end $$;

do $$
begin
  alter table public.expenses
    add constraint expenses_id_user_key unique (id, user_id);
exception
  when duplicate_table or duplicate_object then null;
end $$;


-- ---------------------------------------------------------------------------
-- 1. Credit cards
-- ---------------------------------------------------------------------------
-- statement_day   — the day of the month the billing cycle closes and the
--                   statement is generated (29–31 mean the month's last day
--                   in shorter months).
-- payment_due_day — the day of the month the bill is due: the first such day
--                   after the statement date.
-- opening_outstanding — what was owed when tracking began (negative for a
--                   credit balance). The only stored money figure besides the
--                   limit; the live outstanding is always derived.
-- payment_account_id — the account the bill is usually paid from (pre-selected
--                   when paying, and a hint for reconciliation). Never debited
--                   by a purchase.
create table if not exists public.credit_cards (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users (id) on delete cascade,
  card_name           text not null check (char_length(btrim(card_name)) > 0),
  issuer              text not null check (char_length(btrim(issuer)) > 0),
  network             text check (network in ('visa', 'mastercard', 'rupay', 'amex', 'diners', 'discover', 'jcb', 'other')),
  last4               text check (last4 ~ '^[0-9]{4}$'),
  credit_limit        numeric(14, 2) not null check (credit_limit >= 0),
  opening_outstanding numeric(14, 2) not null default 0,
  statement_day       smallint not null check (statement_day between 1 and 31),
  payment_due_day     smallint not null check (payment_due_day between 1 and 31),
  payment_account_id  uuid,
  is_active           boolean not null default true,
  notes               text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint credit_cards_id_user_key unique (id, user_id),
  -- Deleting the account only clears the preference; the card stays.
  constraint credit_cards_payment_account_fk
    foreign key (payment_account_id, user_id)
    references public.bank_accounts (id, user_id)
    on delete set null (payment_account_id)
);

create index if not exists credit_cards_user_idx
  on public.credit_cards (user_id);


-- ---------------------------------------------------------------------------
-- 2. Card-only movements
-- ---------------------------------------------------------------------------
-- Everything on a card that is neither a purchase (an expense) nor a bill
-- payment from a tracked account (a bank ledger row).
--   direction 'debit'  raises the outstanding (fee, interest),
--   direction 'credit' lowers it (refund, cashback, cash payment).
-- A refund may name the purchase it reverses; it is not income and does not
-- reduce the expense, matching how the app already treats bank refunds.
-- reference holds the issuer's transaction id when known, for matching a
-- future card-statement import.
create table if not exists public.credit_card_transactions (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users (id) on delete cascade,
  card_id             uuid not null,
  kind                text not null check (kind in ('refund', 'cashback', 'payment', 'fee', 'interest', 'adjustment')),
  direction           text not null check (direction in ('debit', 'credit')),
  amount              numeric(14, 2) not null check (amount > 0),
  txn_date            date not null,
  description         text,
  reference           text,
  original_expense_id uuid,
  created_at          timestamptz not null default now(),
  constraint credit_card_transactions_card_fk
    foreign key (card_id, user_id)
    references public.credit_cards (id, user_id)
    on delete cascade,
  -- Deleting the purchase must not delete the refund: the money came back.
  constraint credit_card_transactions_expense_fk
    foreign key (original_expense_id, user_id)
    references public.expenses (id, user_id)
    on delete set null (original_expense_id),
  constraint credit_card_transactions_kind_direction check (
    (kind in ('refund', 'cashback', 'payment') and direction = 'credit')
    or (kind in ('fee', 'interest') and direction = 'debit')
    or kind = 'adjustment'
  ),
  constraint credit_card_transactions_refund_link check (
    original_expense_id is null or kind = 'refund'
  )
);

create index if not exists credit_card_transactions_card_date_idx
  on public.credit_card_transactions (card_id, txn_date);

create index if not exists credit_card_transactions_user_idx
  on public.credit_card_transactions (user_id);


-- ---------------------------------------------------------------------------
-- 3. Purchases: expenses paid with a card
-- ---------------------------------------------------------------------------
-- NULL for every existing row: cash and bank-funded expenses are unchanged.
-- Deleting a card reverts its purchases to Cash, as deleting a bank account
-- already does for bank-funded expenses.
alter table public.expenses
  add column if not exists credit_card_id uuid;

do $$
begin
  alter table public.expenses
    add constraint expenses_credit_card_fk
    foreign key (credit_card_id, user_id)
    references public.credit_cards (id, user_id)
    on delete set null (credit_card_id);
exception
  when duplicate_object then null;
end $$;

create index if not exists expenses_credit_card_idx
  on public.expenses (credit_card_id)
  where credit_card_id is not null;

-- An expense is paid from ONE place. If both were set, the bank ledger debit
-- and the card charge would count the same purchase twice.
--
-- The phone app does not know about cards, so when someone edits a card
-- purchase there and picks a bank account, its update sets bank_account_id
-- and leaves credit_card_id as it was. That newer choice wins: the trigger
-- clears the card, and the phone then writes the bank debit as usual. Any
-- other attempt to set both is refused.
create or replace function public.expenses_single_funding_source()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.bank_account_id is not null and new.credit_card_id is not null then
    if tg_op = 'UPDATE' and new.credit_card_id is not distinct from old.credit_card_id then
      new.credit_card_id := null;
    else
      raise exception 'An expense is paid from a bank account or a credit card, not both.'
        using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists expenses_single_funding_source on public.expenses;
create trigger expenses_single_funding_source
  before insert or update of bank_account_id, credit_card_id on public.expenses
  for each row execute function public.expenses_single_funding_source();

do $$
begin
  alter table public.expenses
    add constraint expenses_single_funding_source_check
    check (bank_account_id is null or credit_card_id is null);
exception
  when duplicate_object then null;
end $$;


-- ---------------------------------------------------------------------------
-- 4. Bill payments: a bank ledger debit that names the card it paid
-- ---------------------------------------------------------------------------
-- ON DELETE SET NULL: deleting the card must never delete the bank movement —
-- the money really left the account — so it stays as a plain debit.
alter table public.account_transactions
  add column if not exists credit_card_id uuid;

do $$
begin
  alter table public.account_transactions
    add constraint account_transactions_credit_card_fk
    foreign key (credit_card_id, user_id)
    references public.credit_cards (id, user_id)
    on delete set null (credit_card_id);
exception
  when duplicate_object then null;
end $$;

do $$
begin
  -- A bill payment is money leaving the account. It is never an expense, an
  -- income or a transfer leg at the same time.
  alter table public.account_transactions
    add constraint account_transactions_card_payment_shape
    check (
      credit_card_id is null
      or (direction = 'debit' and expense_id is null and income_id is null and transfer_group_id is null)
    );
exception
  when duplicate_object then null;
end $$;

create index if not exists account_transactions_credit_card_idx
  on public.account_transactions (credit_card_id)
  where credit_card_id is not null;

-- A ledger row — and so a bill payment — can only sit on the SAME user's
-- account. RLS already keeps every row private to its owner; this closes the
-- remaining gap of a row pointing at an account id that belongs to someone
-- else. NOT VALID: enforced for every new or changed row, existing rows are
-- not re-checked (the apps only ever write the user's own accounts, so the
-- phone app is unaffected). Same cascade as the existing account_id key.
do $$
begin
  alter table public.account_transactions
    add constraint account_transactions_account_owner_fk
    foreign key (account_id, user_id)
    references public.bank_accounts (id, user_id)
    on delete cascade
    not valid;
exception
  when duplicate_object then null;
end $$;


-- ---------------------------------------------------------------------------
-- 5. Access: signed-in users only, and only their own rows
-- ---------------------------------------------------------------------------
-- Explicit, in case the project does not expose new tables to the API by
-- default. Signed-in users only — never anon — and RLS below still decides
-- which rows they see. GRANT is idempotent.
grant select, insert, update, delete on public.credit_cards to authenticated;
grant select, insert, update, delete on public.credit_card_transactions to authenticated;

alter table public.credit_cards enable row level security;

drop policy if exists credit_cards_select_own on public.credit_cards;
create policy credit_cards_select_own on public.credit_cards
  for select using (auth.uid() = user_id);

drop policy if exists credit_cards_insert_own on public.credit_cards;
create policy credit_cards_insert_own on public.credit_cards
  for insert with check (auth.uid() = user_id);

drop policy if exists credit_cards_update_own on public.credit_cards;
create policy credit_cards_update_own on public.credit_cards
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists credit_cards_delete_own on public.credit_cards;
create policy credit_cards_delete_own on public.credit_cards
  for delete using (auth.uid() = user_id);

alter table public.credit_card_transactions enable row level security;

drop policy if exists credit_card_transactions_select_own on public.credit_card_transactions;
create policy credit_card_transactions_select_own on public.credit_card_transactions
  for select using (auth.uid() = user_id);

drop policy if exists credit_card_transactions_insert_own on public.credit_card_transactions;
create policy credit_card_transactions_insert_own on public.credit_card_transactions
  for insert with check (auth.uid() = user_id);

drop policy if exists credit_card_transactions_update_own on public.credit_card_transactions;
create policy credit_card_transactions_update_own on public.credit_card_transactions
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists credit_card_transactions_delete_own on public.credit_card_transactions;
create policy credit_card_transactions_delete_own on public.credit_card_transactions
  for delete using (auth.uid() = user_id);


-- ---------------------------------------------------------------------------
-- Rollback (not run). Only if you want to remove the feature and its data:
-- card purchases revert to Cash expenses and bill payments stay as plain bank
-- debits, so no balance changes except the card figures themselves.
--
--   drop trigger if exists expenses_single_funding_source on public.expenses;
--   drop function if exists public.expenses_single_funding_source();
--   alter table public.expenses drop constraint if exists expenses_single_funding_source_check;
--   alter table public.expenses drop column if exists credit_card_id;
--   alter table public.account_transactions drop constraint if exists account_transactions_account_owner_fk;
--   alter table public.account_transactions drop constraint if exists account_transactions_card_payment_shape;
--   alter table public.account_transactions drop column if exists credit_card_id;
--   drop table if exists public.credit_card_transactions;
--   drop table if exists public.credit_cards;
--   alter table public.expenses drop constraint if exists expenses_id_user_key;
--   alter table public.bank_accounts drop constraint if exists bank_accounts_id_user_key;
-- ---------------------------------------------------------------------------
