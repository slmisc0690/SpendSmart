// Supabase Edge Function: get-monthly-savings-summary
//
// PHASE A — MONTHLY SAVINGS SHARING BACKEND FOUNDATION. Authored as backend foundation work; NOT
// deployed, NOT wired into any iOS UI in this phase. Structurally identical to
// get-monthly-plan-data (Phase 6) — see that function's own header for the fully-argued trust-
// boundary/anti-enumeration rationale, repeated only in summary here:
//
// - Caller identity comes ONLY from requireAuthenticatedUserId() — the request body has no
//   recipient/owner-as-caller identity field at all.
// - Authorization is entirely delegated to public.get_shared_monthly_savings_summary (migration
//   0018), which itself delegates the actual Secondary-permission decision to the canonical
//   is_effectively_shared_for_user evaluator (migration 0008), always with category =
//   'monthlySavings' and item_id = NULL (monthlySavings sharing is GLOBAL ONLY — see that
//   migration's own header) — no permission logic is duplicated here, in SQL, or anywhere else.
// - Anti-enumeration: an owner with no summary row, an unrelated owner, and a genuinely-connected
//   but not-shared owner all produce the identical response — a `summary` of `null`.
// - READ-ONLY: this function performs no write of any kind.
// - AGGREGATE-ONLY: returns exactly the two authorized totals (`saved_this_month`,
//   `total_savings_to_date`) plus `updated_at` — never SavingsEntry history, never the Savings
//   Goal, never income/bill/transaction data. This is a deliberate divergence from
//   get-monthly-plan-data's own "raw synchronized rows, no calculated values" philosophy: this
//   phase's own locked product design explicitly wants pre-computed AGGREGATES sent to a
//   Secondary, not raw entries — the local-only SavingsEntry model is never synced at all.
//
// Request body: { owner_user_id: string (a UUID — whose Monthly Savings summary to read; the
// CALLER's own identity is separately, independently verified via requireAuthenticatedUserId and
// is never influenced by this field, which only selects WHOSE summary is being requested, exactly
// like owner_user_id does in get-monthly-plan-data). }

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

  console.log("[get-monthly-savings-summary] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("get-monthly-savings-summary auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const { owner_user_id } = await req.json().catch(() => ({}));
  if (!isValidUuid(owner_user_id)) {
    return jsonResponse({ error: "owner_user_id (a valid UUID) is required" }, 400);
  }

  try {
    const { data, error } = await supabase.rpc("get_shared_monthly_savings_summary", {
      p_caller_user_id: userId,
      p_owner_user_id: owner_user_id,
    });
    if (error) throw error;

    const row = (data as Record<string, unknown>[] | null)?.[0] ?? null;

    logPlaidOperation({
      operation: "get-monthly-savings-summary",
      outcome: "success",
      accountCount: row ? 1 : 0,
    });

    if (!row) {
      // Never distinguishes "no summary exists" from "exists but not shared with you" — see this
      // file's header.
      return jsonResponse({ summary: null });
    }

    // Money-valued fields as STRINGS, not JSON numbers — same convention as get-monthly-plan-data
    // and every other money field this project sends to iOS.
    return jsonResponse({
      summary: {
        saved_this_month: row.saved_this_month != null ? String(row.saved_this_month) : null,
        total_savings_to_date: row.total_savings_to_date != null ? String(row.total_savings_to_date) : null,
        updated_at: row.updated_at,
      },
    });
  } catch (error) {
    logSafeError("get-monthly-savings-summary failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to retrieve monthly savings summary" }, 500);
  }
});
