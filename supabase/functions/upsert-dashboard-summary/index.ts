// Supabase Edge Function: upsert-dashboard-summary
//
// USER B DASHBOARD PARITY — AUTHORED, NOT DEPLOYED (see this task's own "PHASE CONTROL" section).
// Structurally identical to upsert-savings-summary — see that function's own header for the fully
// argued trust-boundary rationale, repeated only in summary here:
//
// The single trusted write path for dashboard_summary. Caller identity comes ONLY from
// requireAuthenticatedUserId() — the request body carries no owner/self-identity field at all, so
// a client can never spoof `owner_user_id`; `set_dashboard_summary` (migration 0019) always writes
// to `p_requesting_user_id`'s own row. No household/role check is needed: a caller may always
// update their OWN summary regardless of household membership.
//
// Request body: { actual_spent_this_month, monthly_spend_remaining, weekly_spending_limit,
// actual_spent_this_week, weekly_remaining, monthly_spending_budget? } — every money-valued field
// arrives as a STRING (matching this project's universal money-as-string wire convention) and is
// parsed/validated before being forwarded to Postgres as numeric. These are the SAME five (plus
// one optional) totals `MonthlyPlanCalculator`/`BudgetCalculator` already compute on the Primary's
// own device — this function never recomputes or validates the math itself, exactly like
// upsert-savings-summary trusts the client-computed SavingsCalculator totals it receives.
//
// USER B DASHBOARD PARITY (canonical Monthly Outlook/Week-by-Week, migration 0020) — request body
// additionally accepts 12 new OPTIONAL fields: monthly_outlook_budgeted/actual/projected_savings
// (money-as-string), monthly_outlook_status ("good"/"warning"/"over"), current_plan_week_index/
// number (integers), current_plan_week_start_date/end_date (bare "YYYY-MM-DD", validated with the
// SAME isValidBareDate already used by sync-manual-data — never a second date-format formula),
// current_plan_week_recommended/actual/remaining (money-as-string), current_plan_week_status. All
// are forwarded as-is (nullable) to set_dashboard_summary — never recomputed or defaulted here.
// Absent/null fields upload as NULL, matching the client's own "no valid current week → upload
// nothing" behavior.

import {
  createPrivilegedClient,
  jsonResponse,
  logPlaidOperation,
  logSafeError,
  requireAuthenticatedUserId,
  UnauthorizedError,
} from "../_shared/plaid.ts";
import { isValidBareDate } from "../_shared/manual.ts";
import { isValidSpendingStatus } from "../_shared/household.ts";

function parseAmount(value: unknown): number | null {
  const amount = typeof value === "string" ? Number(value) : NaN;
  return Number.isFinite(amount) ? amount : null;
}

function parseOptionalAmount(value: unknown): number | null | undefined {
  if (value === undefined || value === null) return null;
  return parseAmount(value);
}

function parseOptionalInteger(value: unknown): number | null | undefined {
  if (value === undefined || value === null) return null;
  if (typeof value !== "number" || !Number.isInteger(value)) return undefined;
  return value;
}

function parseOptionalBareDate(value: unknown): string | null | undefined {
  if (value === undefined || value === null) return null;
  return isValidBareDate(value) ? value : undefined;
}

function parseOptionalSpendingStatus(value: unknown): string | null | undefined {
  if (value === undefined || value === null) return null;
  return isValidSpendingStatus(value) ? value : undefined;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[upsert-dashboard-summary] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("upsert-dashboard-summary auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const body = await req.json().catch(() => ({}));
  const actualSpentThisMonth = parseAmount(body.actual_spent_this_month);
  const monthlySpendRemaining = parseAmount(body.monthly_spend_remaining);
  const weeklySpendingLimit = parseAmount(body.weekly_spending_limit);
  const actualSpentThisWeek = parseAmount(body.actual_spent_this_week);
  const weeklyRemaining = parseAmount(body.weekly_remaining);
  const monthlySpendingBudget = parseOptionalAmount(body.monthly_spending_budget);

  const monthlyOutlookBudgeted = parseOptionalAmount(body.monthly_outlook_budgeted);
  const monthlyOutlookActual = parseOptionalAmount(body.monthly_outlook_actual);
  const monthlyOutlookProjectedSavings = parseOptionalAmount(body.monthly_outlook_projected_savings);
  const monthlyOutlookStatus = parseOptionalSpendingStatus(body.monthly_outlook_status);
  const currentPlanWeekIndex = parseOptionalInteger(body.current_plan_week_index);
  const currentPlanWeekNumber = parseOptionalInteger(body.current_plan_week_number);
  const currentPlanWeekStartDate = parseOptionalBareDate(body.current_plan_week_start_date);
  const currentPlanWeekEndDate = parseOptionalBareDate(body.current_plan_week_end_date);
  const currentPlanWeekRecommended = parseOptionalAmount(body.current_plan_week_recommended);
  const currentPlanWeekActual = parseOptionalAmount(body.current_plan_week_actual);
  const currentPlanWeekRemaining = parseOptionalAmount(body.current_plan_week_remaining);
  const currentPlanWeekStatus = parseOptionalSpendingStatus(body.current_plan_week_status);

  if (actualSpentThisMonth === null) {
    return jsonResponse({ error: "actual_spent_this_month (a numeric string) is required" }, 400);
  }
  if (monthlySpendRemaining === null) {
    return jsonResponse({ error: "monthly_spend_remaining (a numeric string) is required" }, 400);
  }
  if (weeklySpendingLimit === null) {
    return jsonResponse({ error: "weekly_spending_limit (a numeric string) is required" }, 400);
  }
  if (actualSpentThisWeek === null) {
    return jsonResponse({ error: "actual_spent_this_week (a numeric string) is required" }, 400);
  }
  if (weeklyRemaining === null) {
    return jsonResponse({ error: "weekly_remaining (a numeric string) is required" }, 400);
  }
  if (monthlyOutlookBudgeted === undefined) {
    return jsonResponse({ error: "monthly_outlook_budgeted must be a numeric string, or omitted" }, 400);
  }
  if (monthlyOutlookActual === undefined) {
    return jsonResponse({ error: "monthly_outlook_actual must be a numeric string, or omitted" }, 400);
  }
  if (monthlyOutlookProjectedSavings === undefined) {
    return jsonResponse({ error: "monthly_outlook_projected_savings must be a numeric string, or omitted" }, 400);
  }
  if (monthlyOutlookStatus === undefined) {
    return jsonResponse({ error: "monthly_outlook_status must be one of good/warning/over, or omitted" }, 400);
  }
  if (currentPlanWeekIndex === undefined) {
    return jsonResponse({ error: "current_plan_week_index must be an integer, or omitted" }, 400);
  }
  if (currentPlanWeekNumber === undefined) {
    return jsonResponse({ error: "current_plan_week_number must be an integer, or omitted" }, 400);
  }
  if (currentPlanWeekStartDate === undefined) {
    return jsonResponse({ error: "current_plan_week_start_date must be a bare YYYY-MM-DD date, or omitted" }, 400);
  }
  if (currentPlanWeekEndDate === undefined) {
    return jsonResponse({ error: "current_plan_week_end_date must be a bare YYYY-MM-DD date, or omitted" }, 400);
  }
  if (currentPlanWeekRecommended === undefined) {
    return jsonResponse({ error: "current_plan_week_recommended must be a numeric string, or omitted" }, 400);
  }
  if (currentPlanWeekActual === undefined) {
    return jsonResponse({ error: "current_plan_week_actual must be a numeric string, or omitted" }, 400);
  }
  if (currentPlanWeekRemaining === undefined) {
    return jsonResponse({ error: "current_plan_week_remaining must be a numeric string, or omitted" }, 400);
  }
  if (currentPlanWeekStatus === undefined) {
    return jsonResponse({ error: "current_plan_week_status must be one of good/warning/over, or omitted" }, 400);
  }

  try {
    const { error: rpcError } = await supabase.rpc("set_dashboard_summary", {
      p_requesting_user_id: userId,
      p_actual_spent_this_month: actualSpentThisMonth,
      p_monthly_spend_remaining: monthlySpendRemaining,
      p_weekly_spending_limit: weeklySpendingLimit,
      p_actual_spent_this_week: actualSpentThisWeek,
      p_weekly_remaining: weeklyRemaining,
      p_monthly_spending_budget: monthlySpendingBudget ?? null,
      p_monthly_outlook_budgeted: monthlyOutlookBudgeted ?? null,
      p_monthly_outlook_actual: monthlyOutlookActual ?? null,
      p_monthly_outlook_projected_savings: monthlyOutlookProjectedSavings ?? null,
      p_monthly_outlook_status: monthlyOutlookStatus ?? null,
      p_current_plan_week_index: currentPlanWeekIndex ?? null,
      p_current_plan_week_number: currentPlanWeekNumber ?? null,
      p_current_plan_week_start_date: currentPlanWeekStartDate ?? null,
      p_current_plan_week_end_date: currentPlanWeekEndDate ?? null,
      p_current_plan_week_recommended: currentPlanWeekRecommended ?? null,
      p_current_plan_week_actual: currentPlanWeekActual ?? null,
      p_current_plan_week_remaining: currentPlanWeekRemaining ?? null,
      p_current_plan_week_status: currentPlanWeekStatus ?? null,
    });
    if (rpcError) throw rpcError;

    logPlaidOperation({ operation: "upsert-dashboard-summary", outcome: "success" });
    return jsonResponse({ ok: true });
  } catch (error) {
    logSafeError("upsert-dashboard-summary failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    return jsonResponse({ error: "Failed to update dashboard summary" }, 400);
  }
});
