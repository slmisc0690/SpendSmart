-- PHASE 9 BACKEND PREREQUISITE — Secondary shared-data discovery.
--
-- PROBLEM: the three existing Secondary-facing read endpoints (get-connected-account-transactions,
-- get-manual-account-data, get-monthly-plan-data — migrations 0010/0011/0012) all require the
-- caller to already know WHICH plaid_account_id / manual_account_id / owner_user_id to ask for.
-- Nothing deployed before this migration ever told an active Secondary which of those exist, what
-- they're called, or even what the Primary's own user_id is — get_household_state's Secondary
-- branch (migration 0013) returns only {household_id, role, status}, and
-- get-account-related-options' Secondary branch (migration 0015) returns only the Secondary's OWN
-- accounts (for share-back), never the Primary's. This migration adds exactly the missing
-- discovery step — it is NOT a new data-read path: it never returns transactions, balances, or
-- plan values, only the minimal identity/display metadata needed to then call the three existing,
-- UNMODIFIED read endpoints above. Authored as source only per this phase's own instructions — NOT
-- deployed in this task.
--
-- PERMISSION: not duplicated. Every returned Connected/Manual Account is independently
-- re-evaluated against the SAME canonical is_effectively_shared_for_user evaluator (migration
-- 0008) already used by every other sharing decision in this project — no permission logic is
-- reimplemented here. An item this function did not itself verify as effectively shared can never
-- appear in its response.
--
-- ANTI-ENUMERATION: a caller with no active Secondary membership at all gets the exact same empty/
-- false shape as an active Secondary for whom the Primary currently shares nothing — never a
-- distinguishing error, matching this project's established convention (see
-- find_pending_invitation_for_email's own header, migration 0015).
--
-- NO SCHEMA CHANGE: this migration adds exactly one new function. No table, column, index,
-- trigger, or existing function from any prior migration is touched.
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
        'mask', pa.mask
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
