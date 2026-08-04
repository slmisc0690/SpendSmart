-- PHASE B PARITY FIX, STEP 1 — Secondary shared Connected Account informational parity.
--
-- PROBLEM: migration 0016's get_secondary_shared_data deliberately returned only
-- plaid_account_id/name/mask for a shared Connected Account (see that migration's own header:
-- "it never returns transactions, balances, or plan values, only the minimal identity/display
-- metadata"). Real-device testing found this insufficient — a Secondary's Dashboard card for a
-- shared Connected Account cannot show the same balance/last-updated information the Primary's
-- own equivalent card shows, because the data was never queried server-side at all.
--
-- FIX: CREATE OR REPLACE the same function (never edit a deployed migration file in place — this
-- is a new forward migration per this project's own convention), extending only the
-- connected_accounts branch's jsonb_build_object with four already-existing plaid_accounts
-- columns: current_balance, available_balance, credit_limit, type, plus updated_at. No schema
-- change — every one of these columns already exists (current_balance/available_balance/
-- updated_at since migration 0003, credit_limit since migration 0004, type since migration 0003).
-- The manual_accounts and monthly_plan_shared branches, and every other function in this project,
-- are untouched.
--
-- NUMERIC/TIMESTAMP ENCODING: numeric and timestamptz columns are explicitly cast to ::text
-- before entering jsonb_build_object, matching this project's own established convention for
-- every other shared-money-value DTO (see migration 0011's get_manual_account_with_transactions
-- and SharedManualAccountDetailDTO's Decimal(string:)/SharedTimestampDecoding decode path) —
-- avoids any floating-point precision risk in the numeric-to-JSON-number path, and keeps decoding
-- symmetric with every other shared DTO in the app rather than introducing a second convention.
--
-- SECURITY: PERMISSION LOGIC IS NOT CHANGED. The same `is_effectively_shared_for_user` filter in
-- the connected_accounts subquery's WHERE clause (unchanged) still gates every row — an unshared
-- Primary account still cannot appear in the response no matter what columns are selected for the
-- rows that do pass. No Plaid credential or sync-position secret is read or exposed here — only
-- plaid_accounts' own non-secret balance/type/timestamp columns, the same table
-- get-account-related-options' Primary/owner branch already reads from for the owner's own
-- listing. SECURITY DEFINER / search_path / grants are unchanged from migration 0016.
--
-- NOT DEPLOYED BY THIS MIGRATION FILE'S EXISTENCE — authored as source only, per this task's own
-- explicit "do not deploy" instruction. Preview deployment requires separate explicit approval.
create or replace function public.get_secondary_shared_data(
  p_requesting_user_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_primary_user_id uuid;
  v_empty_result jsonb := jsonb_build_object(
    'is_active_secondary', false,
    'primary_user_id', null,
    'connected_accounts', '[]'::jsonb,
    'manual_accounts', '[]'::jsonb,
    'monthly_plan_shared', false
  );
begin
  select hm.household_id
    into v_household_id
    from public.household_members hm
    where hm.user_id = p_requesting_user_id
      and hm.role = 'secondary'
      and hm.status = 'active';

  if not found then
    return v_empty_result;
  end if;

  select h.primary_user_id
    into v_primary_user_id
    from public.households h
    where h.id = v_household_id;

  if v_primary_user_id is null then
    -- Structurally shouldn't happen (households.primary_user_id is NOT NULL, and an active
    -- Secondary's household_id always references a real household) — defensive only, matching
    -- this project's own convention of never assuming an invariant holds without a fallback.
    return v_empty_result;
  end if;

  return jsonb_build_object(
    'is_active_secondary', true,
    'primary_user_id', v_primary_user_id,
    'connected_accounts', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'plaid_account_id', pa.id,
        'name', pa.name,
        'mask', pa.mask,
        -- PHASE B PARITY FIX, STEP 1 — the newly authorized informational fields. All four are
        -- non-secret display data already present on plaid_accounts; nothing here differs from
        -- what the Primary's own list-connections/sync-balances path already exposes to its
        -- owner. ::text avoids any numeric/timestamp JSON-encoding ambiguity (see this
        -- migration's own header).
        'current_balance', pa.current_balance::text,
        'available_balance', pa.available_balance::text,
        'credit_limit', pa.credit_limit::text,
        'type', pa.type,
        'updated_at', pa.updated_at::text
      )), '[]'::jsonb)
      from public.plaid_accounts pa
      join public.plaid_items pi on pi.id = pa.plaid_item_id
      where pi.user_id = v_primary_user_id
        and public.is_effectively_shared_for_user(
          v_household_id, v_primary_user_id, p_requesting_user_id, 'connectedAccounts', pa.id
        )
    ),
    'manual_accounts', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'manual_account_id', ma.id,
        'name', ma.name,
        'account_type', ma.account_type
      )), '[]'::jsonb)
      from public.manual_accounts ma
      where ma.owner_user_id = v_primary_user_id
        and public.is_effectively_shared_for_user(
          v_household_id, v_primary_user_id, p_requesting_user_id, 'manualAccounts', ma.id
        )
    ),
    'monthly_plan_shared', public.is_effectively_shared_for_user(
      v_household_id, v_primary_user_id, p_requesting_user_id, 'monthlyPlan', null
    )
  );
end;
$$;

revoke execute on function public.get_secondary_shared_data(uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_secondary_shared_data(uuid) to service_role;
