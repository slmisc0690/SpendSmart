// Supabase Edge Function: get-monthly-plan-data
//
// PHASE 6 — MONTHLY PLAN CLOUD SYNCHRONIZATION FOUNDATION. Authored as backend foundation work;
// NOT deployed, NOT wired into any iOS UI (Secondary shared-data UI is explicitly out of scope
// this phase). Structurally identical to get-connected-account-transactions (Phase 4) and
// get-manual-account-data (Phase 5) — see those functions' own headers for the fully-argued
// trust-boundary/anti-enumeration rationale, repeated only in summary here:
//
// - Caller identity comes ONLY from requireAuthenticatedUserId() — the request body has no
//   recipient/owner-as-caller identity field at all.
// - Authorization is entirely delegated to public.get_monthly_plan_with_sources (migration 0012),
//   which itself delegates the actual Secondary-permission decision to the canonical
//   is_effectively_shared_for_user evaluator (migration 0008), always with item_id = NULL (Monthly
//   Plan sharing is GLOBAL ONLY — see that migration's own header) — no permission logic is
//   duplicated here, in SQL, or anywhere else.
// - Anti-enumeration: an owner with no settings row, an unrelated owner, and a genuinely-connected
//   but not-shared owner all produce the identical response — a `plan` of `null`.
// - READ-ONLY: this function performs no write of any kind.
// - NO CALCULATED VALUES: returns only the raw synchronized settings/income-source/
//   recurring-expense rows — never a recomputed estimatedMonthlyIncome/recommendedWeeklyLimit/
//   etc. A future Secondary UI feeds this exact data into the SAME MonthlyPlanCalculator the
//   owner's own app already uses (see migration 0012's own header for why this is deliberate).
//
// Request body: { owner_user_id: string (a UUID — whose Monthly Plan to read; the CALLER's own
// identity is separately, independently verified via requireAuthenticatedUserId and is never
// influenced by this field, which only selects WHOSE plan is being requested, exactly like
// manual_account_id/plaid_account_id do in the prior two phases' equivalent functions) }.

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

  console.log("[get-monthly-plan-data] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("get-monthly-plan-data auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const { owner_user_id } = await req.json().catch(() => ({}));
  if (!isValidUuid(owner_user_id)) {
    return jsonResponse({ error: "owner_user_id (a valid UUID) is required" }, 400);
  }

  try {
    const { data, error } = await supabase.rpc("get_monthly_plan_with_sources", {
      p_caller_user_id: userId,
      p_owner_user_id: owner_user_id,
    });
    if (error) throw error;

    const row = (data as Record<string, unknown>[] | null)?.[0] ?? null;

    logPlaidOperation({
      operation: "get-monthly-plan-data",
      outcome: "success",
      accountCount: row ? 1 : 0,
    });

    if (!row) {
      // Never distinguishes "no plan exists" from "exists but not shared with you" — see this
      // file's header.
      return jsonResponse({ plan: null });
    }

    const incomeSources = (row.income_sources as Record<string, unknown>[] | null) ?? [];
    const recurringExpenses = (row.recurring_expenses as Record<string, unknown>[] | null) ?? [];

    // Passed through from the SQL function's own narrow, non-sensitive RETURNS TABLE shape —
    // never owner_user_id. Money-valued fields as STRINGS, not JSON numbers — same reasoning as
    // every other money field this project sends to iOS.
    return jsonResponse({
      plan: {
        monthly_savings_goal: row.monthly_savings_goal != null ? String(row.monthly_savings_goal) : null,
        buffer_amount: row.buffer_amount != null ? String(row.buffer_amount) : null,
        auto_update_weekly_budget_from_plan: row.auto_update_weekly_budget_from_plan,
        updated_at: row.updated_at,
        income_sources: incomeSources.map((s) => ({
          id: s.id,
          name: s.name,
          amount: s.amount != null ? String(s.amount) : null,
          frequency: s.frequency,
          is_active: s.is_active,
          next_pay_date: s.next_pay_date,
          note: s.note,
        })),
        recurring_expenses: recurringExpenses.map((e) => ({
          id: e.id,
          name: e.name,
          amount: e.amount != null ? String(e.amount) : null,
          frequency: e.frequency,
          is_active: e.is_active,
          due_date: e.due_date,
          is_essential: e.is_essential,
          category_name: e.category_name,
          note: e.note,
        })),
      },
    });
  } catch (error) {
    logSafeError("get-monthly-plan-data failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to retrieve monthly plan data" }, 500);
  }
});
