-- ============================================================================
-- 007: What a statement printed about each imported movement
-- ============================================================================
--
-- Runs on the same Supabase project as mobile/supabase/001–003 and
-- ui/supabase/004–006, after them. Written for the web app; the phone app keeps
-- working unchanged.
--
-- WHY
--   A statement row is more than its date, amount and text. A Paytm UPI
--   statement also prints the UPI reference number (the transaction's unique
--   id across banks), the other side's UPI ID and the time of day; bank
--   statements print their own reference. Until now these could only be kept
--   in the expense's Notes, which is the user's own field. They now have their
--   own place on the movement itself, so:
--     * Notes hold only what the statement calls a note;
--     * a statement imported again — or the same payment arriving from another
--       statement (Paytm and the bank's own) — is recognised by its reference,
--       not just by date, amount and wording.
--
-- SAFETY
--   * Additive only: three nullable columns on account_transactions and one
--     partial index. No DROP, no data rewrite, no policy change. Every
--     existing row keeps NULL in the new columns and reads exactly as before.
--   * Idempotent: ADD COLUMN IF NOT EXISTS / CREATE INDEX IF NOT EXISTS, and
--     the checks are added inside DO blocks that ignore "already exists".
--   * Backward compatible with the phone app, which neither reads nor writes
--     these columns; rows it inserts get NULL. The functions from 005 keep
--     working: they never touch these columns, so a movement keeps its
--     reference when how it is recorded changes.
--   * Row-level security is unchanged: the columns belong to rows the
--     existing account_transactions policies already protect.
--
-- Run this once in the Supabase SQL editor, after 006.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
-- reference  the transaction's reference on the statement it came from: a UPI
--            reference number (12 digits), a bank reference or transaction ID
-- upi_id     the other side's UPI ID (VPA), when the statement printed one
-- txn_time   the time of day the statement printed, if it printed one
alter table public.account_transactions
  add column if not exists reference text,
  add column if not exists upi_id    text,
  add column if not exists txn_time  time;

do $$
begin
  alter table public.account_transactions
    add constraint account_transactions_reference_length
    check (reference is null or char_length(reference) between 1 and 64);
exception
  when duplicate_object then null;
end $$;

do $$
begin
  alter table public.account_transactions
    add constraint account_transactions_upi_id_length
    check (upi_id is null or char_length(upi_id) between 3 and 255);
exception
  when duplicate_object then null;
end $$;


-- ---------------------------------------------------------------------------
-- 2. Finding a movement by its reference
-- ---------------------------------------------------------------------------
-- Duplicate checks read one account's movements and compare references; the
-- index keeps that cheap as the ledger grows. Only rows that have one are indexed.
create index if not exists account_transactions_reference_idx
  on public.account_transactions (account_id, reference)
  where reference is not null;


-- ---------------------------------------------------------------------------
-- Rollback (not run). Removes the details only; every movement, balance,
-- expense and income stays exactly as it is.
--
--   drop index if exists public.account_transactions_reference_idx;
--   alter table public.account_transactions drop constraint if exists account_transactions_upi_id_length;
--   alter table public.account_transactions drop constraint if exists account_transactions_reference_length;
--   alter table public.account_transactions drop column if exists txn_time;
--   alter table public.account_transactions drop column if exists upi_id;
--   alter table public.account_transactions drop column if exists reference;
-- ---------------------------------------------------------------------------
