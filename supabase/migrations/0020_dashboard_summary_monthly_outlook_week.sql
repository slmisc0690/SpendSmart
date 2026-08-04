-- ================================================================================================
-- USER B MONTHLY OUTLOOK / CURRENT WEEK-BY-WEEK PARITY — canonical field extension
-- ================================================================================================
--
-- AUTHORED, NOT DEPLOYED — see this task's own "NO DEPLOYMENT" section: authoring only, no
-- Preview/Production deployment in this phase.
--
-- PROBLEM THIS FIXES: a Secondary's "Monthly Outlook"/"Week-by-Week" Dashboard cards previously
-- reconstructed their own independent `MonthlyPlanCalculator.Summary` from raw shared Connected/
-- Manual Account transactions (`SharedMonthlyOutlookViewModel`), inheriting the exact same class of
-- defect already proven and fixed for the `dashboard_summary` aggregate: the Primary's own local
-- per-transaction "counts toward spending" state never leaves the device, so a second, independent
-- reconstruction can never guarantee parity with what the Primary's own Dashboard actually shows.
-- On top of that, the Secondary's Week-by-Week rendered EVERY week in the month as a stacked list
-- with no "current week" concept at all, while the Primary's own Dashboard always shows exactly one
-- selected/current week.
--
-- FIX: extend the existing `dashboard_summary` aggregate-only table (migration 0019) with the
-- additional Monthly Outlook + current-week fields the Primary already computes and displays
-- locally, pushed the SAME way the original five fields already are — never a second formula, never
-- raw transactions, never more than the single current week.
--
-- ============================================================================================
-- 1. dashboard_summary — additive, nullable columns only (forward-only, non-destructive)
-- ============================================================================================
--
-- All new columns are NULLABLE with no default beyond NULL: an existing row written by a client
-- that predates this migration remains fully valid and readable — its new columns simply read as
-- NULL, and the client is expected to show an honest "unavailable" state for those cards rather
-- than any previously-computed (and possibly wrong) reconstructed value. No existing column is
-- renamed, retyped, or reinterpreted — `weekly_spending_limit`/`actual_spent_this_week`/
-- `weekly_remaining` keep their exact existing LOCKED-formula meaning (`monthlySpendRemaining / 4`);
-- the new `current_plan_week_*` columns are a DELIBERATELY SEPARATE concept (the Monthly Plan
-- screen's own week-by-week recommendation, `flexibleSpendingAvailable / spendingWeeksInMonth`) and
-- must never be confused with or derived from the existing three.
alter table public.dashboard_summary
  add column if not exists monthly_outlook_budgeted numeric,
  add column if not exists monthly_outlook_actual numeric,
  add column if not exists monthly_outlook_projected_savings numeric,
  add column if not exists monthly_outlook_status text,
  add column if not exists current_plan_week_index integer,
  add column if not exists current_plan_week_number integer,
  add column if not exists current_plan_week_start_date date,
  add column if not exists current_plan_week_end_date date,
  add column if not exists current_plan_week_recommended numeric,
  add column if not exists current_plan_week_actual numeric,
  add column if not exists current_plan_week_remaining numeric,
  add column if not exists current_plan_week_status text;

comment on column public.dashboard_summary.monthly_outlook_budgeted is
  'Primary''s displayed Monthly Outlook "Budgeted" figure — BudgetSettings.monthlyGoal (the Monthly
   Savings Goal), NOT flexibleSpendingAvailable/monthly_spending_budget. A distinct concept from the
   existing monthly_spending_budget column.';
comment on column public.dashboard_summary.current_plan_week_status is
  'One of ''good''/''warning''/''over'', mirroring SpendingStatus. NULL when no current-plan-week
   data is available (never defaulted to a guessed status).';

-- No RLS/policy change: this table already has row level security enabled with zero policies
-- (default-deny) since migration 0019 — all access continues to go through the same trusted
-- SECURITY DEFINER functions below, via service_role only.

-- ============================================================================================
-- 2. set_dashboard_summary — extended to accept the new optional fields
-- ============================================================================================
--
-- Same discipline as migration 0019's original: owner_user_id is ALWAYS p_requesting_user_id
-- itself, sourced from the Edge Function's own server-verified auth, never a client-supplied body
-- field — a client can never overwrite another user's summary. All new parameters default to NULL
-- so existing callers (and any not-yet-updated client) continue to work unchanged.
create or replace function public.set_dashboard_summary(
  p_requesting_user_id uuid,
  p_actual_spent_this_month numeric,
  p_monthly_spend_remaining numeric,
  p_weekly_spending_limit numeric,
  p_actual_spent_this_week numeric,
  p_weekly_remaining numeric,
  p_monthly_spending_budget numeric default null,
  p_monthly_outlook_budgeted numeric default null,
  p_monthly_outlook_actual numeric default null,
  p_monthly_outlook_projected_savings numeric default null,
  p_monthly_outlook_status text default null,
  p_current_plan_week_index integer default null,
  p_current_plan_week_number integer default null,
  p_current_plan_week_start_date date default null,
  p_current_plan_week_end_date date default null,
  p_current_plan_week_recommended numeric default null,
  p_current_plan_week_actual numeric default null,
  p_current_plan_week_remaining numeric default null,
  p_current_plan_week_status text default null
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.dashboard_summary (
    owner_user_id, actual_spent_this_month, monthly_spend_remaining, weekly_spending_limit,
    actual_spent_this_week, weekly_remaining, monthly_spending_budget,
    monthly_outlook_budgeted, monthly_outlook_actual, monthly_outlook_projected_savings, monthly_outlook_status,
    current_plan_week_index, current_plan_week_number, current_plan_week_start_date, current_plan_week_end_date,
    current_plan_week_recommended, current_plan_week_actual, current_plan_week_remaining, current_plan_week_status,
    updated_at
  )
  values (
    p_requesting_user_id, p_actual_spent_this_month, p_monthly_spend_remaining, p_weekly_spending_limit,
    p_actual_spent_this_week, p_weekly_remaining, p_monthly_spending_budget,
    p_monthly_outlook_budgeted, p_monthly_outlook_actual, p_monthly_outlook_projected_savings, p_monthly_outlook_status,
    p_current_plan_week_index, p_current_plan_week_number, p_current_plan_week_start_date, p_current_plan_week_end_date,
    p_current_plan_week_recommended, p_current_plan_week_actual, p_current_plan_week_remaining, p_current_plan_week_status,
    now()
  )
  on conflict (owner_user_id)
  do update set
    actual_spent_this_month = excluded.actual_spent_this_month,
    monthly_spend_remaining = excluded.monthly_spend_remaining,
    weekly_spending_limit = excluded.weekly_spending_limit,
    actual_spent_this_week = excluded.actual_spent_this_week,
    weekly_remaining = excluded.weekly_remaining,
    monthly_spending_budget = excluded.monthly_spending_budget,
    monthly_outlook_budgeted = excluded.monthly_outlook_budgeted,
    monthly_outlook_actual = excluded.monthly_outlook_actual,
    monthly_outlook_projected_savings = excluded.monthly_outlook_projected_savings,
    monthly_outlook_status = excluded.monthly_outlook_status,
    current_plan_week_index = excluded.current_plan_week_index,
    current_plan_week_number = excluded.current_plan_week_number,
    current_plan_week_start_date = excluded.current_plan_week_start_date,
    current_plan_week_end_date = excluded.current_plan_week_end_date,
    current_plan_week_recommended = excluded.current_plan_week_recommended,
    current_plan_week_actual = excluded.current_plan_week_actual,
    current_plan_week_remaining = excluded.current_plan_week_remaining,
    current_plan_week_status = excluded.current_plan_week_status,
    updated_at = now();
$$;

-- Signature changed (new trailing default params) — drop the old narrower overload explicitly so
-- exactly one `set_dashboard_summary` definition exists, then re-apply the same revoke/grant
-- discipline as every other privileged function in this schema.
drop function if exists public.set_dashboard_summary(uuid, numeric, numeric, numeric, numeric, numeric, numeric);

revoke execute on function public.set_dashboard_summary(
  uuid, numeric, numeric, numeric, numeric, numeric, numeric,
  numeric, numeric, numeric, text,
  integer, integer, date, date, numeric, numeric, numeric, text
) from public, anon, authenticated, service_role;
grant execute on function public.set_dashboard_summary(
  uuid, numeric, numeric, numeric, numeric, numeric, numeric,
  numeric, numeric, numeric, text,
  integer, integer, date, date, numeric, numeric, numeric, text
) to service_role;

-- ============================================================================================
-- 3. get_shared_dashboard_summary — extended to return the new fields
-- ============================================================================================
--
-- Authorization logic is completely unchanged from migration 0019 (self-access always authorized;
-- cross-user access via the same canonical is_effectively_shared_for_user evaluator, category =
-- 'monthlyPlan', item_id null) — only the returned column set grows. Anti-enumeration behavior is
-- unchanged: an unauthorized/unrelated/not-yet-shared caller still receives zero rows.
--
-- Postgres cannot CREATE OR REPLACE a function whose RETURNS TABLE shape changes — the return type
-- itself is changing (new output columns), so the prior definition must be dropped first.
drop function if exists public.get_shared_dashboard_summary(uuid, uuid);

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
  monthly_outlook_budgeted numeric,
  monthly_outlook_actual numeric,
  monthly_outlook_projected_savings numeric,
  monthly_outlook_status text,
  current_plan_week_index integer,
  current_plan_week_number integer,
  current_plan_week_start_date date,
  current_plan_week_end_date date,
  current_plan_week_recommended numeric,
  current_plan_week_actual numeric,
  current_plan_week_remaining numeric,
  current_plan_week_status text,
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
      ds.actual_spent_this_week, ds.weekly_remaining, ds.monthly_spending_budget,
      ds.monthly_outlook_budgeted, ds.monthly_outlook_actual, ds.monthly_outlook_projected_savings, ds.monthly_outlook_status,
      ds.current_plan_week_index, ds.current_plan_week_number, ds.current_plan_week_start_date, ds.current_plan_week_end_date,
      ds.current_plan_week_recommended, ds.current_plan_week_actual, ds.current_plan_week_remaining, ds.current_plan_week_status,
      ds.updated_at
    from public.dashboard_summary ds
    where ds.owner_user_id = p_owner_user_id;
end;
$$;

revoke execute on function public.get_shared_dashboard_summary(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_shared_dashboard_summary(uuid, uuid) to service_role;
