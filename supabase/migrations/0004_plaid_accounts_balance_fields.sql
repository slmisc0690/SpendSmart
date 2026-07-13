-- Additive only. Three things, none of them destructive to existing data:
--
-- 1. Adds the Plaid balance fields 0003 didn't capture (credit limit, unofficial currency code)
--    plus soft-delete tracking (is_active/removed_at) for accounts Plaid stops returning.
-- 2. Corrects plaid_accounts' uniqueness constraint. Per Plaid's own documented account_id
--    semantics ("Plaid's unique identifier for the account... The account_id can also change if
--    the access_token is deleted and the same credentials are used to generate a new access_token
--    on a later date" — https://plaid.com/docs/api/accounts/), account_id is unique WITHIN AN
--    ITEM, not globally — nothing guarantees two different Items (even at different institutions)
--    never report the same account_id. 0003's bare `account_id text ... unique` constraint was
--    too strict; replaced with a composite (plaid_item_id, account_id) constraint below. This is
--    a schema correction, not a data change — dropping a constraint never touches row data, and
--    the existing single-Sandbox-connection deployment cannot yet have hit the bug this fixes
--    (it would need two Items reporting the same account_id to have failed before now).
-- 3. All new columns are nullable or default to a value describing "nothing has happened yet"
--    (is_active defaults to true — every pre-existing row IS currently active, that's simply true
--    of them, not an assumption).

alter table public.plaid_accounts
  add column if not exists credit_limit numeric,
  add column if not exists unofficial_currency_code text,
  -- Soft-delete, not hard-delete: historical FinanceTransaction rows on the iOS side reference a
  -- Plaid account_id (FinanceTransaction.plaidAccountId) that must keep resolving to a real,
  -- readable plaid_accounts row even after the account itself closes at the institution — hard
  -- deleting would orphan that reference for no benefit (nothing here reads plaid_accounts to
  -- decide whether a transaction is valid).
  add column if not exists is_active boolean not null default true,
  add column if not exists removed_at timestamptz;

comment on column public.plaid_accounts.credit_limit is
  'Plaid''s balances.limit — for credit accounts, the credit limit; for depository accounts, the pre-arranged overdraft limit. Null when Plaid does not report one.';
comment on column public.plaid_accounts.is_active is
  'False once a complete /accounts/get response for this Item stopped including this account_id (closed/removed at the institution). Reactivated (set back to true) automatically if the account_id reappears in a later response — see refreshPlaidAccounts in _shared/plaid.ts.';

create index if not exists plaid_accounts_plaid_item_id_active_idx
  on public.plaid_accounts (plaid_item_id)
  where is_active;

-- Drop the old single-column uniqueness constraint (Postgres's default auto-generated name for
-- an inline `column_name type unique` from a CREATE TABLE) and replace it with the composite
-- constraint that actually matches Plaid's documented guarantee. `if exists` makes this safe to
-- re-run even if the constraint was already renamed/dropped.
alter table public.plaid_accounts drop constraint if exists plaid_accounts_account_id_key;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'plaid_accounts_item_account_unique'
      and conrelid = 'public.plaid_accounts'::regclass
  ) then
    alter table public.plaid_accounts
      add constraint plaid_accounts_item_account_unique unique (plaid_item_id, account_id);
  end if;
end $$;
