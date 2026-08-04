// Supabase Edge Function: upsert-savings-summary
//
// PHASE A — MONTHLY SAVINGS SHARING BACKEND FOUNDATION. Authored as backend foundation work; NOT
// deployed, NOT wired into any iOS UI in this phase (the client-side trigger that computes these
// two totals via SavingsCalculator and calls this endpoint is a FUTURE phase's work).
//
// The single trusted write path for savings_summary. Caller identity comes ONLY from
// requireAuthenticatedUserId() — the request body carries no owner/self-identity field at all, so
// a client can never spoof `owner_user_id`; `set_savings_summary` (migration 0018) always writes
// to `p_requesting_user_id`'s own row, immutably, exactly mirroring set_sharing_permission's own
// "owner is always the requesting user, never a separate trusted parameter" discipline. This
// endpoint requires no household/role check: a caller may always update their OWN summary
// regardless of household membership — the same posture already established for
// monthly_plan_settings' own owner-keyed sync path. There is no cross-user write surface of any
// kind here: nothing this function does can ever target another user's row.
//
// Request body: { saved_this_month: string, total_savings_to_date: string } — both money-valued
// fields arrive as STRINGS (matching this project's universal money-as-string wire convention)
// and are parsed/validated before being forwarded to Postgres as numeric.

import {
  createPrivilegedClient,
  jsonResponse,
  logPlaidOperation,
  logSafeError,
  requireAuthenticatedUserId,
  UnauthorizedError,
} from "../_shared/plaid.ts";

function parseAmount(value: unknown): number | null {
  const amount = typeof value === "string" ? Number(value) : NaN;
  return Number.isFinite(amount) ? amount : null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[upsert-savings-summary] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("upsert-savings-summary auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const body = await req.json().catch(() => ({}));
  const savedThisMonth = parseAmount(body.saved_this_month);
  const totalSavingsToDate = parseAmount(body.total_savings_to_date);

  if (savedThisMonth === null) {
    return jsonResponse({ error: "saved_this_month (a numeric string) is required" }, 400);
  }
  if (totalSavingsToDate === null) {
    return jsonResponse({ error: "total_savings_to_date (a numeric string) is required" }, 400);
  }

  try {
    const { error: rpcError } = await supabase.rpc("set_savings_summary", {
      p_requesting_user_id: userId,
      p_saved_this_month: savedThisMonth,
      p_total_savings_to_date: totalSavingsToDate,
    });
    if (rpcError) throw rpcError;

    logPlaidOperation({ operation: "upsert-savings-summary", outcome: "success" });
    return jsonResponse({ ok: true });
  } catch (error) {
    logSafeError("upsert-savings-summary failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    return jsonResponse({ error: "Failed to update savings summary" }, 400);
  }
});
