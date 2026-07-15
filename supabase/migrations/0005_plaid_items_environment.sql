-- Adds an explicit Plaid environment marker to plaid_items, so a row can never again be
-- ambiguous about whether it was created against Plaid Sandbox, Development, or Production.
-- Additive only — no existing column is altered or dropped, and no existing row's other fields
-- are touched.
--
-- Backfill: every plaid_items row that exists as of this migration was necessarily created while
-- PLAID_ENV=production was hard-blocked in code (see loadPlaidCredentials in
-- ../functions/_shared/plaid.ts, prior to the change that accompanies this migration) — so every
-- existing row is safely backfilled as 'sandbox', this project's actual default and the only
-- environment any row could have been created under so far.
--
-- No default is set on the column itself: every insert path (exchange-public-token) is updated
-- to always supply `environment` explicitly, so a future insert that omits it fails loudly
-- (not-null violation) rather than silently guessing.
--
-- No index is added — every query that will filter by environment does so in application code
-- after an existing primary-key/user_id-scoped lookup, not via a standalone WHERE environment=...
-- query.

alter table public.plaid_items
  add column if not exists environment text;

update public.plaid_items
  set environment = 'sandbox'
  where environment is null;

alter table public.plaid_items
  alter column environment set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'plaid_items_environment_check'
      and conrelid = 'public.plaid_items'::regclass
  ) then
    alter table public.plaid_items
      add constraint plaid_items_environment_check
      check (environment in ('sandbox', 'development', 'production'));
  end if;
end $$;

comment on column public.plaid_items.environment is
  'Which Plaid environment (sandbox/development/production) this Item''s access_token was issued under. Set at exchange-public-token time from the server''s active PLAID_ENV, never client-supplied. Every Plaid call reusing this Item must verify this still matches the server''s current PLAID_ENV before calling Plaid — see assertItemEnvironmentMatches in _shared/plaid.ts.';
