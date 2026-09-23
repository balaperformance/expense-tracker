-- ============================================================================
-- Phase 2: Bank Accounts & Transaction Statements
-- ============================================================================
--
-- SAFETY
--   * Additive only. No DROP TABLE, no DROP COLUMN, no data rewrite.
--   * Every statement is idempotent (IF NOT EXISTS / DROP POLICY IF EXISTS),
--     so re-running it is harmless.
--   * Existing rows in expenses / income are untouched; the new columns are
--     nullable and default to NULL, which the app reads as "Cash".
--   * RLS is enabled on both new tables with the same auth.uid() = user_id
--     rule the Phase 1 tables use. Nothing is loosened.
--
-- DESIGN
--   account_transactions is the ledger and the single source of truth for
--   account movement. Balances are never stored in a mutable column; a
--   balance is always opening_balance + SUM(credits) - SUM(debits).
--
--   Cash is deliberately NOT a bank account. An expense paid in cash simply
--   has bank_account_id = NULL and produces no ledger row, so cash spending
--   can never move a bank balance.
--
-- Run this once in the Supabase SQL editor.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 0. Phase 1 leftover: the Merchant column (safe to re-run)
-- ---------------------------------------------------------------------------
alter table public.expenses
  add column if not exists merchant text;


-- ---------------------------------------------------------------------------
-- 1. Bank accounts
-- ---------------------------------------------------------------------------
create table if not exists public.bank_accounts (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users (id) on delete cascade,
  bank_name       text not null,
  nickname        text not null,
  last4           text,
  opening_balance numeric(14, 2) not null default 0,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists bank_accounts_user_idx
  on public.bank_accounts (user_id);

alter table public.bank_accounts enable row level security;

drop policy if exists bank_accounts_select_own on public.bank_accounts;
create policy bank_accounts_select_own on public.bank_accounts
  for select using (auth.uid() = user_id);

drop policy if exists bank_accounts_insert_own on public.bank_accounts;
create policy bank_accounts_insert_own on public.bank_accounts
  for insert with check (auth.uid() = user_id);

drop policy if exists bank_accounts_update_own on public.bank_accounts;
create policy bank_accounts_update_own on public.bank_accounts
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists bank_accounts_delete_own on public.bank_accounts;
create policy bank_accounts_delete_own on public.bank_accounts
  for delete using (auth.uid() = user_id);


-- ---------------------------------------------------------------------------
-- 2. Ledger
-- ---------------------------------------------------------------------------
-- transfer_group_id is unused in Phase 2. It exists so a future bank-to-bank
-- transfer can write two rows (one debit, one credit) sharing an id, without
-- another migration.
create table if not exists public.account_transactions (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users (id) on delete cascade,
  account_id        uuid not null
                      references public.bank_accounts (id) on delete cascade,
  direction         text not null check (direction in ('debit', 'credit')),
  amount            numeric(14, 2) not null check (amount > 0),
  txn_date          date not null,
  description       text,
  category_id       uuid references public.categories (id) on delete set null,
  -- ON DELETE CASCADE is the integrity guarantee that matters most: deleting
  -- an expense or income row can never leave an orphaned movement behind,
  -- even if the app crashes between the two calls.
  expense_id        uuid references public.expenses (id) on delete cascade,
  income_id         uuid references public.income (id) on delete cascade,
  transfer_group_id uuid,
  created_at        timestamptz not null default now()
);

create index if not exists account_transactions_account_date_idx
  on public.account_transactions (account_id, txn_date);

create index if not exists account_transactions_user_idx
  on public.account_transactions (user_id);

-- One ledger row per source document, so a retry cannot double-debit.
create unique index if not exists account_transactions_expense_uniq
  on public.account_transactions (expense_id) where expense_id is not null;

create unique index if not exists account_transactions_income_uniq
  on public.account_transactions (income_id) where income_id is not null;

alter table public.account_transactions enable row level security;

drop policy if exists account_transactions_select_own on public.account_transactions;
create policy account_transactions_select_own on public.account_transactions
  for select using (auth.uid() = user_id);

drop policy if exists account_transactions_insert_own on public.account_transactions;
create policy account_transactions_insert_own on public.account_transactions
  for insert with check (auth.uid() = user_id);

drop policy if exists account_transactions_update_own on public.account_transactions;
create policy account_transactions_update_own on public.account_transactions
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists account_transactions_delete_own on public.account_transactions;
create policy account_transactions_delete_own on public.account_transactions
  for delete using (auth.uid() = user_id);


-- ---------------------------------------------------------------------------
-- 3. Link expenses and income to an account
-- ---------------------------------------------------------------------------
-- NULL means Cash for an expense, or "not deposited to a tracked account"
-- for income. Existing rows therefore keep working unchanged.
alter table public.expenses
  add column if not exists bank_account_id uuid
    references public.bank_accounts (id) on delete set null;

alter table public.income
  add column if not exists bank_account_id uuid
    references public.bank_accounts (id) on delete set null;

create index if not exists expenses_bank_account_idx
  on public.expenses (bank_account_id);

create index if not exists income_bank_account_idx
  on public.income (bank_account_id);
