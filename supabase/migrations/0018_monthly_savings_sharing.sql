-- PHASE A — MONTHLY SAVINGS SHARING — BACKEND FOUNDATION. Authored as source only per this
-- phase's own instructions; NOT deployed to Preview or Production in this task.
--
-- PRODUCT DESIGN (locked): `monthlySavings` is a NEW, INDEPENDENT sharing category — explicitly
-- NOT coupled to the existing `monthlyPlan` category (toggling one must never affect the other).
-- Default OFF. When ON, an authorized Secondary may read exactly two Primary-owned aggregate
-- numbers — Saved This Month and Total Savings to Date — and nothing else: never individual
-- `SavingsEntry` rows/history, never the Savings Goal, never transaction/income/bill data. The
-- local-only `SavingsEntry` SwiftData model is untouched by this migration and gets no cloud
-- table — only a server-side AGGREGATE mirror (`savings_summary`, two numbers + a timestamp) is
-- introduced, populated by a future client phase's upload of the same two totals
-- `SavingsCalculator` already computes locally.
--
-- SCOPE: (A) widen `sharing_permissions.category` (and its global-only-category check) to accept
-- `monthlySavings`; (B) create `savings_summary`, an aggregate-only, one-row-per-owner table; (C)
-- enable RLS, default-deny (identical posture to every other Plaid/Manual/Monthly-Plan table in
-- this schema — no anon/authenticated policy, all access via trusted SECURITY DEFINER functions
-- through the service_role Edge Function client); (D) `set_savings_summary`, the sole Primary-
-- authorized write path; (E) `get_shared_monthly_savings_summary`, the sole Secondary-authorized
-- read path, delegating authorization entirely to the existing canonical
-- `is_effectively_shared_for_user` evaluator (migration 0008) — never a second authorization
-- system; (F) `CREATE OR REPLACE` of `set_sharing_permission` (migration 0013) and
-- `get_secondary_shared_data` (migration 0016) to recognize the new category, with every line
-- outside that recognition left byte-identical to the deployed version. No other table, column,
-- index, trigger, or function from any prior migration is touched. `monthlyPlan`'s own behavior,
-- `connectedAccounts`/`manualAccounts` sharing, invitations, household roles, and Primary/
-- Secondary ownership are all unmodified.

-- ============================================================================================
-- 1. sharing_permissions — widen category + global-only-category constraints to add
--    'monthlySavings'
-- ============================================================================================
--
-- 0008 is never edited, per this project's own "never edit an already-shipped migration"
-- discipline — both constraints are ALTERed from this later migration instead. Constraint names
-- are looked up dynamically (matching migration 0015's own `household_invitations.status`
-- precedent) rather than assumed, so this is not silently ineffective if either constraint was
-- ever named explicitly.
do $$
declare
  v_category_constraint_name text;
  v_monthly_plan_global_constraint_name text;
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
    into v_monthly_plan_global_constraint_name
    from pg_constraint
    where conrelid = 'public.sharing_permissions'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%monthlyplan%item_id%';

  if v_monthly_plan_global_constraint_name is not null then
    execute format('alter table public.sharing_permissions drop constraint %I', v_monthly_plan_global_constraint_name);
  end if;
end $$;

alter table public.sharing_permissions
  add constraint sharing_permissions_category_check
  check (category in ('connectedAccounts', 'manualAccounts', 'monthlyPlan', 'monthlySavings'));

-- monthlySavings is global-only, matching monthlyPlan's own posture (a Primary shares it as a
-- whole via a single toggle — this phase's own locked "Primary controls it via a toggle" design;
-- there is no per-item concept for an aggregate).
alter table public.sharing_permissions
  add constraint sharing_permissions_global_only_check
  check (category not in ('monthlyPlan', 'monthlySavings') or item_id is null);

-- ============================================================================================
-- 2. savings_summary — one row per owner, aggregate-only
-- ============================================================================================
--
-- COLUMN SELECTION: exactly the two aggregate numbers this phase's own locked design authorizes
-- (`saved_this_month`, `total_savings_to_date`) plus `updated_at` for freshness — matching this
-- phase's own explicit warning against inventing extra fields. PRIMARY KEY IS owner_user_id
-- itself, not a separate synchronized `id` — same reasoning as `monthly_plan_settings`
-- (migration 0012): this is a singleton-per-owner aggregate with nothing else referencing it by
-- id, so there is no separate client-suppliable id a caller could reuse to target a different
-- owner's row. Explicitly NOT present, per this phase's own "DO NOT CHANGE" list: any
-- SavingsEntry-shaped column, a savings goal column, household_id (ownership is per-user, not
-- per-household, exactly like monthly_plan_settings), or any transaction/income/bill data.
create table if not exists public.savings_summary (
  owner_user_id uuid primary key references auth.users (id),
  saved_this_month numeric not null default 0,
  total_savings_to_date numeric not null default 0,
  updated_at timestamptz not null default now()
);

comment on table public.savings_summary is
  'Aggregate-only server mirror of two client-computed totals (SavingsCalculator.savedThisMonth /
   totalSavingsToDate). Never stores individual SavingsEntry rows or the Savings Goal — the local
   SwiftData SavingsEntry model remains local-only and is never synced. Read-only from every OTHER
   client''s perspective (a future authorized Secondary); the owning device''s own local SwiftData
   store remains authoritative for that owner''s own UI, matching the exact posture already
   established for monthly_plan_settings/manual_accounts.';

alter table public.savings_summary enable row level security;
-- Default-deny — no anon/authenticated policy, identical posture to every other Plaid/Manual/
-- Monthly-Plan/sharing table in this schema. All access goes through trusted Edge Functions using
-- the privileged service_role client via the SECURITY DEFINER functions below.

create trigger savings_summary_set_updated_at
  before update on public.savings_summary
  for each row execute function public.set_updated_at();

-- ============================================================================================
-- 3. set_savings_summary — the sole Primary-authorized write path
-- ============================================================================================
--
-- owner_user_id is ALWAYS p_requesting_user_id itself — identical discipline to
-- set_sharing_permission (migration 0013) and every sync write path in this project: the caller's
-- identity comes from the Edge Function's own server-verified auth (never a client-supplied body
-- field), and there is no separate owner parameter to (mis)trust, so a client can never overwrite
-- another user's summary, and no household/role check is needed beyond "this is always my own
-- row" — the exact same posture already established for monthly_plan_settings' own owner-keyed
-- upsert (no household-membership requirement to sync one's own data). Atomic upsert, matching
-- this project's universal claim-with-conflict-resolution convention (single INSERT ... ON
-- CONFLICT ... DO UPDATE, never a separate SELECT-then-decide race).
create or replace function public.set_savings_summary(
  p_requesting_user_id uuid,
  p_saved_this_month numeric,
  p_total_savings_to_date numeric
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.savings_summary (owner_user_id, saved_this_month, total_savings_to_date, updated_at)
  values (p_requesting_user_id, p_saved_this_month, p_total_savings_to_date, now())
  on conflict (owner_user_id)
  do update set
    saved_this_month = excluded.saved_this_month,
    total_savings_to_date = excluded.total_savings_to_date,
    updated_at = now();
$$;

revoke execute on function public.set_savings_summary(uuid, numeric, numeric) from public, anon, authenticated, service_role;
grant execute on function public.set_savings_summary(uuid, numeric, numeric) to service_role;

-- ============================================================================================
-- 4. get_shared_monthly_savings_summary — the sole Secondary-authorized read path
-- ============================================================================================
--
-- Structurally identical to get_monthly_plan_with_sources (migration 0012): self-access is always
-- authorized (an owner reading their own summary); cross-user access is authorized ONLY via the
-- canonical is_effectively_shared_for_user evaluator (migration 0008), category = 'monthlySavings',
-- item_id always null (global-only, per section 1 above) — no permission logic is duplicated here
-- or anywhere else. ANTI-ENUMERATION: an owner with no summary row, an unrelated owner, and a
-- genuinely-connected-but-not-shared owner all return zero rows — the identical empty result,
-- exactly matching get_monthly_plan_with_sources' own `return;` early-exit shape. Every read is
-- live (no caching, no invalidation step) — revocation takes effect on the very next call, the
-- same "authorization is re-evaluated on every read" posture this project relies on everywhere
-- else for instant, code-free revocation.
create or replace function public.get_shared_monthly_savings_summary(
  p_caller_user_id uuid,
  p_owner_user_id uuid
)
returns table (
  saved_this_month numeric,
  total_savings_to_date numeric,
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
        v_household_id, p_owner_user_id, p_caller_user_id, 'monthlySavings', null
      );
  end if;

  if not coalesce(v_authorized, false) then
    return;
  end if;

  return query
    select ss.saved_this_month, ss.total_savings_to_date, ss.updated_at
    from public.savings_summary ss
    where ss.owner_user_id = p_owner_user_id;
end;
$$;

revoke execute on function public.get_shared_monthly_savings_summary(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_shared_monthly_savings_summary(uuid, uuid) to service_role;

-- ============================================================================================
-- 5. set_sharing_permission — recognize 'monthlySavings' (CREATE OR REPLACE of migration 0013's
--    function; every line outside the two marked additions is byte-identical to the deployed
--    version)
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

  -- PHASE A ADDITION: 'monthlySavings' added to the allowlist.
  if p_category not in ('connectedAccounts', 'manualAccounts', 'monthlyPlan', 'monthlySavings') then
    raise exception 'set_sharing_permission: invalid category %.', p_category;
  end if;

  -- PHASE A ADDITION: 'monthlySavings' is global-only, same as 'monthlyPlan'.
  if p_category in ('monthlyPlan', 'monthlySavings') and p_item_id is not null then
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
-- 6. get_secondary_shared_data — add primary_monthly_savings_shared (CREATE OR REPLACE of
--    migration 0016's function; every line outside the two marked additions is byte-identical to
--    the deployed version)
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
    'monthly_savings_shared', false -- PHASE A ADDITION
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
    ),
    -- PHASE A ADDITION: independently re-evaluated via the same canonical evaluator, never
    -- derived from monthly_plan_shared above — the two categories are intentionally uncoupled.
    'monthly_savings_shared', public.is_effectively_shared_for_user(
      v_household_id, v_primary_user_id, p_requesting_user_id, 'monthlySavings', null
    )
  );
end;
$$;

revoke execute on function public.get_secondary_shared_data(uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_secondary_shared_data(uuid) to service_role;
