-- SAVED VIA TRANSFER SHARING — BACKEND FOUNDATION. Structurally identical to migration 0018
-- (Monthly Savings Sharing) — see that migration's own header for the fully-argued rationale,
-- repeated only in summary here.
--
-- PRODUCT DESIGN (locked, per Scott's explicit request): `savedViaTransfer` is a NEW, INDEPENDENT
-- sharing category — explicitly NOT coupled to `monthlySavings` or `monthlyPlan` (toggling any one
-- of the three must never affect the others). Default OFF. When ON, an authorized Secondary may
-- read exactly one Primary-owned aggregate number — this month's total of `.transferToSavings`
-- Manual Account entries (`SavedViaTransferCalculator.savedThisMonth`) — and nothing else: never
-- individual transaction rows, never which account(s) the transfers came from/went to, never any
-- other Manual Account data. Reusing `manualAccounts` sharing (which shares actual account
-- balances/transactions) would leak far more than this single number, and reusing `monthlySavings`
-- would conflate two independently-tracked savings concepts Scott has kept deliberately separate —
-- see `SavedViaTransferCalculator`'s own header. This migration introduces only a server-side
-- AGGREGATE mirror (`saved_via_transfer_summary`, one number + a timestamp), populated by a client
-- push of the same total `SavedViaTransferCalculator` already computes locally.
--
-- SCOPE: (A) widen `sharing_permissions.category` (and its global-only-category check) to accept
-- `savedViaTransfer`; (B) create `saved_via_transfer_summary`, an aggregate-only, one-row-per-owner
-- table; (C) enable RLS, default-deny, identical posture to every other table in this schema; (D)
-- `set_saved_via_transfer_summary`, the sole Primary-authorized write path; (E)
-- `get_shared_saved_via_transfer_summary`, the sole Secondary-authorized read path, delegating
-- authorization entirely to the existing canonical `is_effectively_shared_for_user` evaluator
-- (migration 0008); (F) `CREATE OR REPLACE` of `set_sharing_permission` (migration 0013, most
-- recently replaced by 0018) and `get_secondary_shared_data` (migration 0016, most recently
-- replaced by 0018) to recognize the new category, with every line outside that recognition left
-- byte-identical to the deployed version. No other table, column, index, trigger, or function from
-- any prior migration is touched.

-- ============================================================================================
-- 1. sharing_permissions — widen category + global-only-category constraints to add
--    'savedViaTransfer'
-- ============================================================================================
do $$
declare
  v_category_constraint_name text;
  v_global_only_constraint_name text;
begin
  select conname
    into v_category_constraint_name
    from pg_constraint
    where conrelid = 'public.sharing_permissions'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%category%connectedaccounts%manualaccounts%monthlyplan%';

  if v_category_constraint_name is not null then
    execute format('alter table public.sharing_permissions drop constraint %I', v_category_constraint_name);
  end if;

  select conname
    into v_global_only_constraint_name
    from pg_constraint
    where conrelid = 'public.sharing_permissions'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%monthlyplan%item_id%';

  if v_global_only_constraint_name is not null then
    execute format('alter table public.sharing_permissions drop constraint %I', v_global_only_constraint_name);
  end if;
end $$;

alter table public.sharing_permissions
  add constraint sharing_permissions_category_check
  check (category in ('connectedAccounts', 'manualAccounts', 'monthlyPlan', 'monthlySavings', 'savedViaTransfer'));

-- savedViaTransfer is global-only, matching monthlyPlan/monthlySavings' own posture — a single
-- number, shared as a whole via one toggle, no per-item concept.
alter table public.sharing_permissions
  add constraint sharing_permissions_global_only_check
  check (category not in ('monthlyPlan', 'monthlySavings', 'savedViaTransfer') or item_id is null);

-- ============================================================================================
-- 2. saved_via_transfer_summary — one row per owner, aggregate-only
-- ============================================================================================
--
-- COLUMN SELECTION: exactly the one aggregate number this feature's locked design authorizes
-- (`saved_via_transfer_this_month`) plus `updated_at` for freshness. PRIMARY KEY IS owner_user_id
-- itself, matching `savings_summary`/`monthly_plan_settings`'s own singleton-per-owner shape.
-- Explicitly NOT present: any individual transaction row, account reference, or Manual Account
-- data of any kind.
create table if not exists public.saved_via_transfer_summary (
  owner_user_id uuid primary key references auth.users (id),
  saved_via_transfer_this_month numeric not null default 0,
  updated_at timestamptz not null default now()
);

comment on table public.saved_via_transfer_summary is
  'Aggregate-only server mirror of one client-computed total
   (SavedViaTransferCalculator.savedThisMonth, summed over the owner''s own local
   .transferToSavings Manual Account entries). Never stores individual transaction rows or which
   account(s) were involved. Read-only from every OTHER client''s perspective (a future authorized
   Secondary); the owning device''s own local SwiftData store remains authoritative for that
   owner''s own UI.';

alter table public.saved_via_transfer_summary enable row level security;
-- Default-deny — no anon/authenticated policy, identical posture to every other table in this
-- schema. All access goes through trusted Edge Functions using the privileged service_role client
-- via the SECURITY DEFINER functions below.

create trigger saved_via_transfer_summary_set_updated_at
  before update on public.saved_via_transfer_summary
  for each row execute function public.set_updated_at();

-- ============================================================================================
-- 3. set_saved_via_transfer_summary — the sole Primary-authorized write path
-- ============================================================================================
--
-- owner_user_id is ALWAYS p_requesting_user_id itself — identical discipline to
-- set_savings_summary (migration 0018): the caller's identity comes from the Edge Function's own
-- server-verified auth, never a client-supplied body field, so a client can never overwrite
-- another user's summary. Atomic upsert.
create or replace function public.set_saved_via_transfer_summary(
  p_requesting_user_id uuid,
  p_saved_via_transfer_this_month numeric
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.saved_via_transfer_summary (owner_user_id, saved_via_transfer_this_month, updated_at)
  values (p_requesting_user_id, p_saved_via_transfer_this_month, now())
  on conflict (owner_user_id)
  do update set
    saved_via_transfer_this_month = excluded.saved_via_transfer_this_month,
    updated_at = now();
$$;

revoke execute on function public.set_saved_via_transfer_summary(uuid, numeric) from public, anon, authenticated, service_role;
grant execute on function public.set_saved_via_transfer_summary(uuid, numeric) to service_role;

-- ============================================================================================
-- 4. get_shared_saved_via_transfer_summary — the sole Secondary-authorized read path
-- ============================================================================================
--
-- Structurally identical to get_shared_monthly_savings_summary (migration 0018). ANTI-
-- ENUMERATION: an owner with no summary row, an unrelated owner, and a genuinely-connected-but-
-- not-shared owner all return zero rows. Every read is live (no caching) — revocation takes
-- effect on the very next call.
create or replace function public.get_shared_saved_via_transfer_summary(
  p_caller_user_id uuid,
  p_owner_user_id uuid
)
returns table (
  saved_via_transfer_this_month numeric,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_authorized boolean;
begin
  if p_caller_user_id = p_owner_user_id then
    v_authorized := true;
  else
    v_household_id := public.resolve_household_for_owner_and_recipient(p_owner_user_id, p_caller_user_id);
    v_authorized := v_household_id is not null
      and public.is_effectively_shared_for_user(
        v_household_id, p_owner_user_id, p_caller_user_id, 'savedViaTransfer', null
      );
  end if;

  if not coalesce(v_authorized, false) then
    return;
  end if;

  return query
    select svt.saved_via_transfer_this_month, svt.updated_at
    from public.saved_via_transfer_summary svt
    where svt.owner_user_id = p_owner_user_id;
end;
$$;

revoke execute on function public.get_shared_saved_via_transfer_summary(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_shared_saved_via_transfer_summary(uuid, uuid) to service_role;

-- ============================================================================================
-- 5. set_sharing_permission — recognize 'savedViaTransfer' (CREATE OR REPLACE; every line outside
--    the two marked additions is byte-identical to the deployed version)
-- ============================================================================================
create or replace function public.set_sharing_permission(
  p_household_id uuid,
  p_requesting_user_id uuid,
  p_category text,
  p_item_id uuid,
  p_is_shared boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_primary_user_id uuid;
  v_result_id uuid;
begin
  select primary_user_id
    into v_household_primary_user_id
    from public.households
    where id = p_household_id;

  if not found then
    raise exception 'set_sharing_permission: household % does not exist.', p_household_id;
  end if;

  if p_requesting_user_id <> v_household_primary_user_id then
    raise exception 'set_sharing_permission: requesting user is not the Primary for this household.';
  end if;

  if not exists (
    select 1 from public.household_members
    where household_id = p_household_id
      and user_id = p_requesting_user_id
      and role = 'primary'
      and status = 'active'
  ) then
    raise exception 'set_sharing_permission: requesting user does not have an active Primary membership for this household.';
  end if;

  -- SAVED-VIA-TRANSFER ADDITION: 'savedViaTransfer' added to the allowlist.
  if p_category not in ('connectedAccounts', 'manualAccounts', 'monthlyPlan', 'monthlySavings', 'savedViaTransfer') then
    raise exception 'set_sharing_permission: invalid category %.', p_category;
  end if;

  -- SAVED-VIA-TRANSFER ADDITION: 'savedViaTransfer' is global-only, same as 'monthlyPlan'/'monthlySavings'.
  if p_category in ('monthlyPlan', 'monthlySavings', 'savedViaTransfer') and p_item_id is not null then
    raise exception 'set_sharing_permission: % is a global-only category; item_id must be null.', p_category;
  end if;

  -- Per-item ownership re-validation (defense-in-depth — the calling Edge Function is expected
  -- to have already checked this independently).
  if p_item_id is not null then
    if p_category = 'connectedAccounts' then
      if not exists (
        select 1
        from public.plaid_accounts pa
        join public.plaid_items pi on pi.id = pa.plaid_item_id
        where pa.id = p_item_id
          and pi.user_id = p_requesting_user_id
      ) then
        raise exception 'set_sharing_permission: item % is not a Connected Account owned by the requesting user.', p_item_id;
      end if;
    elsif p_category = 'manualAccounts' then
      if not exists (
        select 1
        from public.manual_accounts ma
        where ma.id = p_item_id
          and ma.owner_user_id = p_requesting_user_id
      ) then
        raise exception 'set_sharing_permission: item % is not a Manual Account owned by the requesting user.', p_item_id;
      end if;
    end if;
  end if;

  if p_item_id is null then
    insert into public.sharing_permissions (household_id, owner_user_id, category, item_id, is_shared)
    values (p_household_id, p_requesting_user_id, p_category, null, p_is_shared)
    on conflict (household_id, owner_user_id, category) where item_id is null
    do update set is_shared = excluded.is_shared, updated_at = now()
    returning id into v_result_id;
  else
    insert into public.sharing_permissions (household_id, owner_user_id, category, item_id, is_shared)
    values (p_household_id, p_requesting_user_id, p_category, p_item_id, p_is_shared)
    on conflict (household_id, owner_user_id, category, item_id) where item_id is not null
    do update set is_shared = excluded.is_shared, updated_at = now()
    returning id into v_result_id;
  end if;

  return v_result_id;
end;
$$;

revoke execute on function public.set_sharing_permission(uuid, uuid, text, uuid, boolean) from public, anon, authenticated, service_role;
grant execute on function public.set_sharing_permission(uuid, uuid, text, uuid, boolean) to service_role;

-- ============================================================================================
-- 6. get_secondary_shared_data — add primary_saved_via_transfer_shared (CREATE OR REPLACE; every
--    line outside the two marked additions is byte-identical to the deployed version)
-- ============================================================================================
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
    'saved_via_transfer_shared', false -- SAVED-VIA-TRANSFER ADDITION
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
    ),
    'monthly_savings_shared', public.is_effectively_shared_for_user(
      v_household_id, v_primary_user_id, p_requesting_user_id, 'monthlySavings', null
    ),
    -- SAVED-VIA-TRANSFER ADDITION: independently re-evaluated via the same canonical evaluator,
    -- never derived from monthly_savings_shared above — the two categories are intentionally
    -- uncoupled, per this feature's own locked design.
    'saved_via_transfer_shared', public.is_effectively_shared_for_user(
      v_household_id, v_primary_user_id, p_requesting_user_id, 'savedViaTransfer', null
    )
  );
end;
$$;

revoke execute on function public.get_secondary_shared_data(uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_secondary_shared_data(uuid) to service_role;
