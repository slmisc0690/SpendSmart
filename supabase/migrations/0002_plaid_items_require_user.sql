-- Every Edge Function now scopes every plaid_items read/write to a server-side user id — either
-- PLAID_SANDBOX_USER_ID (this project's current single-user Sandbox setup) or, once SpendSmart
-- adds Supabase Auth, the authenticated caller's own id. Enforce that at the schema level too, not
-- just in application code.
--
-- Safe to run as a plain ALTER on this project: this is a brand-new SpendSmart Supabase project
-- with an empty plaid_items table, so there are no existing null user_id rows to backfill.
alter table public.plaid_items
  alter column user_id set not null;
