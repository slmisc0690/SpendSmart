-- ================================================================================================
-- USER B DASHBOARD PARITY — AUTHORITATIVE SHARED DASHBOARD AGGREGATES
-- ================================================================================================
--
-- AUTHORED, NOT DEPLOYED — see this task's own "PHASE CONTROL" instructions: authoring only, no
-- Preview/Production deployment in this phase.
--
-- PROBLEM THIS FIXES: a Secondary's Dashboard previously reconstructed "This Week"/"Monthly
-- Spending" from raw shared Plaid/Manual transactions (`SharedMonthlyOutlookViewModel`), which
-- proved unable to reproduce the Primary's own canonical totals — the Primary's local per-
-- transaction "counts toward spending" classification is genuinely local-only SwiftData state that
-- has no server representation at all (confirmed: neither `plaid_transactions` nor
-- `manual_transactions` carries any such column) and is therefore structurally impossible for a
-- second, independent client-side calculation to ever replicate exactly.
--
-- FIX: mirror the exact `savings_summary` pattern (migration 0018) — the Primary computes the
-- authoritative aggregate LOCALLY, using its own unmodified `MonthlyPlanCalculator`/
-- `BudgetCalculator` formulas (never duplicated here), then pushes ONLY the resulting numbers.
-- The Secondary reads that exact aggregate back — never a second formula, never raw transactions.
--
-- ============================================================================================
-- 1. dashboard_summary — aggregate-only server mirror of Primary-side Dashboard totals
-- ============================================================================================
--
-- Singleton-per-owner, exactly like `savings_summary`/`monthly_plan_settings`: no separate
-- synchronized `id`, ownership is per-user (not per-household). Deliberately carries ONLY the five
-- authorized aggregate figures (plus one optional consistency figure) — never individual
-- transactions, never merchant/account names, never the local per-transaction review/exclusion
-- state that made the prior raw-reconstruction approach unable to guarantee parity. The Primary's
-- own device computes this from ONLY the subset of its local transactions belonging to an
-- explicitly-shared Connected/Manual Account — the privacy filtering happens entirely client-side,
-- before upload, using the exact same sharing-permission evaluation the Account Related Options
-- screen's own toggles already use; this table has no knowledge of "which accounts" at all, only
-- the already-filtered totals.
create table if not exists public.dashboard_summary (
  owner_user_id uuid primary key references auth.users (id),
  actual_spent_this_month numeric not null default 0,
  monthly_spend_remaining numeric not null default 0,
  weekly_spending_limit numeric not null default 0,
  actual_spent_this_week numeric not null default 0,
  weekly_remaining numeric not null default 0,
  -- Optional consistency/debugging figure only — the Monthly Spending Budget the five totals above
  -- were derived from. Never required by any client-side formula (Secondary never recomputes
  -- anything from it), included only so a future debugging session can sanity-check the pushed
  -- totals against the Primary's own Monthly Plan inputs without a second round-trip.
  monthly_spending_budget numeric,
  updated_at timestamptz not null default now()
);

comment on table public.dashboard_summary is
  'Aggregate-only server mirror of five client-computed Dashboard totals (actualSpentThisMonth,
   monthlySpendRemaining, weeklySpendingLimit, actualSpentThisWeek, weeklyRemaining), already
   filtered client-side to only the Primary transactions belonging to an explicitly-shared
   Connected/Manual Account. Never stores individual transactions, account identifiers, merchant
   data, or local per-transaction review/exclusion state. Read-only from every OTHER client''s
   perspective (an authorized Secondary); the owning device''s own local SwiftData/BudgetSettings
   remain authoritative for that owner''s own UI, matching the exact posture already established
   for savings_summary/monthly_plan_settings/manual_accounts.';

alter table public.dashboard_summary enable row level security;
-- Default-deny — no anon/authenticated policy, identical posture to every other table in this
-- schema. All access goes through trusted Edge Functions using the privileged service_role client
-- via the SECURITY DEFINER functions below.

create trigger dashboard_summary_set_updated_at
  before update on public.dashboard_summary
  for each row execute function public.set_updated_at();

-- ============================================================================================
-- 2. set_dashboard_summary — the sole Primary-authorized write path
-- ============================================================================================
--
-- Identical discipline to set_savings_summary (migration 0018): owner_user_id is ALWAYS
-- p_requesting_user_id itself — the caller's identity comes from the Edge Function's own
-- server-verified auth (never a client-supplied body field), so a client can never overwrite
-- another user's summary. No household/role check needed: a caller may always update their OWN
-- summary regardless of household membership, same posture as monthly_plan_settings/
-- savings_summary's own owner-keyed upserts. Atomic upsert (single INSERT ... ON CONFLICT ... DO
-- UPDATE), matching this project's universal claim-with-conflict-resolution convention.
create or replace function public.set_dashboard_summary(
  p_requesting_user_id uuid,
  p_actual_spent_this_month numeric,
  p_monthly_spend_remaining numeric,
  p_weekly_spending_limit numeric,
  p_actual_spent_this_week numeric,
  p_weekly_remaining numeric,
  p_monthly_spending_budget numeric default null
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.dashboard_summary (
    owner_user_id, actual_spent_this_month, monthly_spend_remaining, weekly_spending_limit,
    actual_spent_this_week, weekly_remaining, monthly_spending_budget, updated_at
  )
  values (
    p_requesting_user_id, p_actual_spent_this_month, p_monthly_spend_remaining, p_weekly_spending_limit,
    p_actual_spent_this_week, p_weekly_remaining, p_monthly_spending_budget, now()
  )
  on conflict (owner_user_id)
  do update set
    actual_spent_this_month = excluded.actual_spent_this_month,
    monthly_spend_remaining = excluded.monthly_spend_remaining,
    weekly_spending_limit = excluded.weekly_spending_limit,
    actual_spent_this_week = excluded.actual_spent_this_week,
    weekly_remaining = excluded.weekly_remaining,
    monthly_spending_budget = excluded.monthly_spending_budget,
    updated_at = now();
$$;

revoke execute on function public.set_dashboard_summary(uuid, numeric, numeric, numeric, numeric, numeric, numeric) from public, anon, authenticated, service_role;
grant execute on function public.set_dashboard_summary(uuid, numeric, numeric, numeric, numeric, numeric, numeric) to service_role;

-- ============================================================================================
-- 3. get_shared_dashboard_summary — the sole Secondary-authorized read path
-- ============================================================================================
--
-- Structurally identical to get_shared_monthly_savings_summary (migration 0018): self-access is
-- always authorized; cross-user access is authorized ONLY via the canonical
-- is_effectively_shared_for_user evaluator (migration 0008), category = 'monthlyPlan', item_id
-- always null — the SAME authorization gate DashboardView's own `secondaryOutlookAuthorized`
-- already uses client-side for This Week/Monthly Outlook, so a Secondary sees this new
-- authoritative aggregate under EXACTLY the same "Primary shares Monthly Plan" condition as
-- before, never a new/different toggle. ANTI-ENUMERATION: an owner with no summary row, an
-- unrelated owner, and a genuinely-connected-but-not-shared owner all return zero rows. Every read
-- is live — revocation takes effect on the very next call.
create or replace function public.get_shared_dashboard_summary(
  p_caller_user_id uuid,
  p_owner_user_id uuid
)
returns table (
  actual_spent_this_month numeric,
  monthly_spend_remaining numeric,
  weekly_spending_limit numeric,
  actual_spent_this_week numeric,
  weekly_remaining numeric,
  monthly_spending_budget numeric,
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
        v_household_id, p_owner_user_id, p_caller_user_id, 'monthlyPlan', null
      );
  end if;

  if not coalesce(v_authorized, false) then
    return;
  end if;

  return query
    select
      ds.actual_spent_this_month, ds.monthly_spend_remaining, ds.weekly_spending_limit,
      ds.actual_spent_this_week, ds.weekly_remaining, ds.monthly_spending_budget, ds.updated_at
    from public.dashboard_summary ds
    where ds.owner_user_id = p_owner_user_id;
end;
$$;

revoke execute on function public.get_shared_dashboard_summary(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_shared_dashboard_summary(uuid, uuid) to service_role;
