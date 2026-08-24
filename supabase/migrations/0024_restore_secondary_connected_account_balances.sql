-- SHARED CONNECTED-ACCOUNT BALANCE RESTORE — repairs a silent field-dropping regression in
-- `public.get_secondary_shared_data`.
--
-- ROOT CAUSE (verified by reading all four definitions, not inferred):
--   0016  created the function. `connected_accounts` items carried: plaid_account_id, name, mask.
--   0017  CREATE OR REPLACE'd it to ADD current_balance / available_balance / credit_limit / type /
--         updated_at, so a Secondary's Dashboard card could render the same
--         `PlaidBalanceFormatter.rows(for:)` output the Primary's own card shows. Correct.
--   0018  CREATE OR REPLACE'd it again to add `monthly_savings_shared` — and re-typed the
--         `connected_accounts` object WITHOUT the five fields 0017 had just added, silently
--         reverting that migration's entire purpose.
--   0023  CREATE OR REPLACE'd it again to add `saved_via_transfer_shared`, carrying the loss
--         forward unnoticed.
--
-- LIVE SYMPTOM: a Secondary viewing a shared Connected Account always saw "Balance not refreshed
-- yet", permanently and regardless of how many times the Primary refreshed that account. The
-- Primary's refresh writes `plaid_accounts.current_balance`/`updated_at` correctly and the
-- `get-account-related-options` Edge Function passes `sharedData.connected_accounts` through
-- verbatim (confirmed by reading its source — it is NOT at fault); the fields simply never left
-- this function, so the client decoded `nil` for all of them and rendered its honest
-- never-refreshed empty state. No client change is needed or included.
--
-- SCOPE: exactly one CREATE OR REPLACE of `get_secondary_shared_data`, restoring 0017's five
-- fields on top of 0023's current definition. Everything else in 0023's version — the
-- monthly_plan / monthly_savings / saved_via_transfer flags, the empty-result shape, the
-- authorization path, the SECURITY DEFINER / search_path / grant posture — is reproduced verbatim
-- and unchanged. No schema change: all five columns already exist (current_balance /
-- available_balance / updated_at since 0003, credit_limit since 0004, type since 0003). No new
-- data is exposed that 0017 had not already authorized and shipped.
--
-- AUTHORIZATION IS UNCHANGED: each account is still gated by the same canonical
-- `is_effectively_shared_for_user(..., 'connectedAccounts', pa.id)` evaluator, so only accounts the
-- Primary has explicitly shared with this specific Secondary are returned. Nothing here widens who
-- can see what; it restores which non-secret display fields a already-authorized account carries.
-- Still never exposed: access_token, cursor, item_id, or any institution credential.
--
-- ::text casts on the numeric/timestamp fields are carried over from 0017 deliberately — this
-- project's universal money-as-string wire convention, and it avoids numeric/timestamp JSON
-- encoding ambiguity between Postgres, Deno, and Swift's Decimal decode.

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
    'monthly_plan_shared', false,
    'monthly_savings_shared', false,
    'saved_via_transfer_shared', false
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
        -- BALANCE RESTORE: the five fields migration 0017 added and 0018 dropped. The Swift
        -- `SharedConnectedAccountDTO` has decoded all five since 0017 shipped — they have simply
        -- been arriving absent (hence nil) ever since.
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
    ),
    'monthly_savings_shared', public.is_effectively_shared_for_user(
      v_household_id, v_primary_user_id, p_requesting_user_id, 'monthlySavings', null
    ),
    'saved_via_transfer_shared', public.is_effectively_shared_for_user(
      v_household_id, v_primary_user_id, p_requesting_user_id, 'savedViaTransfer', null
    )
  );
end;
$$;

revoke execute on function public.get_secondary_shared_data(uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_secondary_shared_data(uuid) to service_role;
