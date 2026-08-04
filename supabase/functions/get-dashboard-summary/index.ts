// Supabase Edge Function: get-dashboard-summary
//
// USER B DASHBOARD PARITY — AUTHORED, NOT DEPLOYED (see this task's own "PHASE CONTROL" section).
// Structurally identical to get-monthly-savings-summary — see that function's own header for the
// fully-argued trust-boundary/anti-enumeration rationale, repeated only in summary here:
//
// - Caller identity comes ONLY from requireAuthenticatedUserId() — the request body has no
//   recipient/owner-as-caller identity field at all.
// - Authorization is entirely delegated to public.get_shared_dashboard_summary (migration 0019),
//   which itself delegates the actual Secondary-permission decision to the canonical
//   is_effectively_shared_for_user evaluator (migration 0008), always with category =
//   'monthlyPlan' and item_id = NULL — the SAME gate DashboardView's own `secondaryOutlookAuthorized`
//   already uses client-side, so this new aggregate becomes visible under exactly the same
//   "Primary shares Monthly Plan" condition as This Week/Monthly Outlook always have.
// - Anti-enumeration: an owner with no summary row, an unrelated owner, and a genuinely-connected
//   but not-shared owner all produce the identical response — a `summary` of `null`.
// - READ-ONLY: this function performs no write of any kind.
// - AGGREGATE-ONLY: returns exactly the five authorized totals (plus the one optional consistency
//   figure) and `updated_at` — never individual transactions, account identifiers, merchant data,
//   or local per-transaction review/exclusion state.
//
// Request body: { owner_user_id: string (a UUID — whose Dashboard summary to read; the CALLER's
// own identity is separately, independently verified via requireAuthenticatedUserId). }
//
// USER B DASHBOARD PARITY (canonical Monthly Outlook/Week-by-Week, migration 0020) — response
// additionally returns 12 new fields (money as strings, dates as their raw "YYYY-MM-DD" string,
// status/integers as-is), each `null` when the underlying row column is `null` — an older row
// predating this migration, or a Primary upload with no valid current-week comparison. This
// function performs no interpretation/fallback of its own; the iOS client alone decides how to
// present a `null` field (see SharedDashboardSummaryDTO's own header).

import {
  createPrivilegedClient,
  isValidUuid,
  jsonResponse,
  logPlaidOperation,
  logSafeError,
  requireAuthenticatedUserId,
  SafeError,
  UnauthorizedError,
} from "../_shared/plaid.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[get-dashboard-summary] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("get-dashboard-summary auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const { owner_user_id } = await req.json().catch(() => ({}));
  if (!isValidUuid(owner_user_id)) {
    return jsonResponse({ error: "owner_user_id (a valid UUID) is required" }, 400);
  }

  try {
    const { data, error } = await supabase.rpc("get_shared_dashboard_summary", {
      p_caller_user_id: userId,
      p_owner_user_id: owner_user_id,
    });
    if (error) throw error;

    const row = (data as Record<string, unknown>[] | null)?.[0] ?? null;

    logPlaidOperation({
      operation: "get-dashboard-summary",
      outcome: "success",
      accountCount: row ? 1 : 0,
    });

    if (!row) {
      // Never distinguishes "no summary exists" from "exists but not shared with you" — see this
      // file's header.
      return jsonResponse({ summary: null });
    }

    // Money-valued fields as STRINGS, not JSON numbers — same convention as
    // get-monthly-savings-summary and every other money field this project sends to iOS.
    return jsonResponse({
      summary: {
        actual_spent_this_month: row.actual_spent_this_month != null ? String(row.actual_spent_this_month) : null,
        monthly_spend_remaining: row.monthly_spend_remaining != null ? String(row.monthly_spend_remaining) : null,
        weekly_spending_limit: row.weekly_spending_limit != null ? String(row.weekly_spending_limit) : null,
        actual_spent_this_week: row.actual_spent_this_week != null ? String(row.actual_spent_this_week) : null,
        weekly_remaining: row.weekly_remaining != null ? String(row.weekly_remaining) : null,
        monthly_spending_budget: row.monthly_spending_budget != null ? String(row.monthly_spending_budget) : null,
        monthly_outlook_budgeted: row.monthly_outlook_budgeted != null ? String(row.monthly_outlook_budgeted) : null,
        monthly_outlook_actual: row.monthly_outlook_actual != null ? String(row.monthly_outlook_actual) : null,
        monthly_outlook_projected_savings: row.monthly_outlook_projected_savings != null ? String(row.monthly_outlook_projected_savings) : null,
        monthly_outlook_status: row.monthly_outlook_status ?? null,
        current_plan_week_index: row.current_plan_week_index ?? null,
        current_plan_week_number: row.current_plan_week_number ?? null,
        current_plan_week_start_date: row.current_plan_week_start_date ?? null,
        current_plan_week_end_date: row.current_plan_week_end_date ?? null,
        current_plan_week_recommended: row.current_plan_week_recommended != null ? String(row.current_plan_week_recommended) : null,
        current_plan_week_actual: row.current_plan_week_actual != null ? String(row.current_plan_week_actual) : null,
        current_plan_week_remaining: row.current_plan_week_remaining != null ? String(row.current_plan_week_remaining) : null,
        current_plan_week_status: row.current_plan_week_status ?? null,
        updated_at: row.updated_at,
      },
    });
  } catch (error) {
    logSafeError("get-dashboard-summary failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to retrieve dashboard summary" }, 500);
  }
});
