-- ================================================================================================
-- SHARED USER QUICK STATS PARITY — canonical field extension
-- ================================================================================================
--
-- PROBLEM THIS FIXES: a Secondary's Dashboard Quick Stats tiles (Planned Weekly Spending, Spent
-- This Week, Planned Monthly Spending, Projected Available After Spend) all read $0, because
-- `quickStatsSection` in `DashboardView.swift` reads local `@Query`-backed properties
-- (`monthlyPlanSummary`, built from this device's own `incomeSources`/`recurringExpenses`/
-- `transactions`) unconditionally — a Secondary has none of that data locally by design. Three of
-- the four tiles can already be sourced from `dashboard_summary` columns migrations 0019/0020
-- already push (`weekly_spending_limit`, `actual_spent_this_week`, `monthly_outlook_budgeted`); the
-- fourth — "Projected Available After Spend" (`MonthlyPlanCalculator.additionalPlannedSavings`,
-- flexibleSpendingAvailable minus plannedMonthlySpending) — has no equivalent column today.
--
-- FIX: one additive, nullable column, pushed the SAME way every other `dashboard_summary` field
-- already is — never a second formula, never raw transactions.
--
-- ============================================================================================
-- 1. dashboard_summary — one additive, nullable column
-- ============================================================================================
alter table public.dashboard_summary
  add column if not exists additional_planned_savings numeric;

comment on column public.dashboard_summary.additional_planned_savings is
  'Primary''s MonthlyPlanCalculator.additionalPlannedSavings (flexibleSpendingAvailable minus
   plannedMonthlySpending) — feeds the Secondary''s "Projected Available After Spend" Quick Stat.
   NULL for a row written before this migration.';

-- ============================================================================================
-- 2. set_dashboard_summary — extended to accept the new optional field
-- ============================================================================================
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
  p_current_plan_week_status text default null,
  p_additional_planned_savings numeric default null
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
    additional_planned_savings,
    updated_at
  )
  values (
    p_requesting_user_id, p_actual_spent_this_month, p_monthly_spend_remaining, p_weekly_spending_limit,
    p_actual_spent_this_week, p_weekly_remaining, p_monthly_spending_budget,
    p_monthly_outlook_budgeted, p_monthly_outlook_actual, p_monthly_outlook_projected_savings, p_monthly_outlook_status,
    p_current_plan_week_index, p_current_plan_week_number, p_current_plan_week_start_date, p_current_plan_week_end_date,
    p_current_plan_week_recommended, p_current_plan_week_actual, p_current_plan_week_remaining, p_current_plan_week_status,
    p_additional_planned_savings,
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
    additional_planned_savings = excluded.additional_planned_savings,
    updated_at = now();
$$;

drop function if exists public.set_dashboard_summary(
  uuid, numeric, numeric, numeric, numeric, numeric, numeric,
  numeric, numeric, numeric, text,
  integer, integer, date, date, numeric, numeric, numeric, text
);

revoke execute on function public.set_dashboard_summary(
  uuid, numeric, numeric, numeric, numeric, numeric, numeric,
  numeric, numeric, numeric, text,
  integer, integer, date, date, numeric, numeric, numeric, text,
  numeric
) from public, anon, authenticated, service_role;
grant execute on function public.set_dashboard_summary(
  uuid, numeric, numeric, numeric, numeric, numeric, numeric,
  numeric, numeric, numeric, text,
  integer, integer, date, date, numeric, numeric, numeric, text,
  numeric
) to service_role;

-- ============================================================================================
-- 3. get_shared_dashboard_summary — extended to return the new field
-- ============================================================================================
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
  additional_planned_savings numeric,
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
      ds.additional_planned_savings,
      ds.updated_at
    from public.dashboard_summary ds
    where ds.owner_user_id = p_owner_user_id;
end;
$$;

revoke execute on function public.get_shared_dashboard_summary(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_shared_dashboard_summary(uuid, uuid) to service_role;
