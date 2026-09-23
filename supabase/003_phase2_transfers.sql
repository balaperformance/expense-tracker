-- ============================================================================
-- Phase 2 (cont.): Self-account transfers
-- ============================================================================
--
-- SAFETY
--   * Additive only. No DROP, no data rewrite, no policy loosened.
--   * Idempotent: IF NOT EXISTS everywhere, and the CHECK constraints are
--     added inside a DO block that swallows duplicate_object, so re-running
--     the file is harmless.
--   * Existing account_transactions rows all have transfer_group_id NULL and
--     therefore satisfy both new constraints without being touched.
--   * No new RLS policies are needed: transfer legs are ordinary rows in
--     account_transactions, already covered by the auth.uid() = user_id
--     policies created in 002.
--
-- DESIGN
--   A transfer is TWO rows in the existing ledger sharing one
--   transfer_group_id: a debit on the sender and a credit on the receiver.
--   The column was reserved in 002 for exactly this, so no table is added.
--
--   Crucially, a transfer creates NO expenses row and NO income row. The
--   Dashboard, Reports, budgets and spending analytics all read from those
--   two tables and never from the ledger, so moving your own money between
--   your own accounts cannot register as earning or spending. That is a
--   property of the data model, not a filter the UI has to remember to apply.
--
--   "Money Transfer" is deliberately NOT inserted into public.categories.
--   That table drives the expense category picker, the budget category list
--   and the reports breakdown; a transfer must not appear in any of them.
--   The label is derived in the app from transfer_group_id IS NOT NULL.
--
-- Run this once in the Supabase SQL editor, after 002.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. The other side of the transfer
-- ---------------------------------------------------------------------------
-- Storing the counterparty as a foreign key rather than only as text means a
-- statement line can say "Transfer to Savings" using the account's current
-- nickname, and a future GenAI query can join the two legs directly instead
-- of parsing a description string.
--
-- ON DELETE SET NULL, not CASCADE: deleting the *other* account must never
-- delete this account's movement, because that movement really happened and
-- removing it would silently change this account's balance.
alter table public.account_transactions
  add column if not exists counterparty_account_id uuid
    references public.bank_accounts (id) on delete set null;


-- ---------------------------------------------------------------------------
-- 2. Finding both legs of a transfer cheaply
-- ---------------------------------------------------------------------------
create index if not exists account_transactions_transfer_group_idx
  on public.account_transactions (transfer_group_id)
  where transfer_group_id is not null;


-- ---------------------------------------------------------------------------
-- 3. Integrity
-- ---------------------------------------------------------------------------
do $$
begin
  -- A transfer leg is a movement between the user's own accounts. It is never
  -- also an expense or an income document. This is the database-level half of
  -- the "transfers are not spending" guarantee.
  alter table public.account_transactions
    add constraint account_transactions_transfer_not_document
    check (
      transfer_group_id is null
      or (expense_id is null and income_id is null)
    );
exception
  when duplicate_object then null;
end $$;

do $$
begin
  -- Money cannot move from an account to itself.
  alter table public.account_transactions
    add constraint account_transactions_counterparty_differs
    check (
      counterparty_account_id is null
      or counterparty_account_id <> account_id
    );
exception
  when duplicate_object then null;
end $$;
