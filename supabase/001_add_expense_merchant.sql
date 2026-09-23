-- Phase 1 migration: add the Merchant field to expenses.
--
-- Additive and non-destructive:
--   * no existing column or row is touched
--   * the column is nullable, so existing rows stay valid
--   * RLS policies are unaffected (they filter on user_id, not columns)
--
-- Run this once in the Supabase SQL editor. Until it is applied the app
-- detects the missing column and simply hides the Merchant field.

alter table public.expenses
  add column if not exists merchant text;
