// Supabase Edge Function: upsert-saved-via-transfer-summary
//
// SAVED VIA TRANSFER SHARING. The single trusted write path for saved_via_transfer_summary.
// Caller identity comes ONLY from requireAuthenticatedUserId() — the request body carries no
// owner/self-identity field at all, so a client can never spoof `owner_user_id`;
// `set_saved_via_transfer_summary` (migration 0023) always writes to `p_requesting_user_id`'s own
// row, immutably, exactly mirroring upsert-savings-summary's own discipline. This endpoint
// requires no household/role check: a caller may always update their OWN summary regardless of
// household membership. There is no cross-user write surface of any kind here.
//
// Request body: { saved_via_transfer_this_month: string } — a money-valued field arriving as a
// STRING (matching this project's universal money-as-string wire convention), parsed/validated
// before being forwarded to Postgres as numeric.

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

  console.log("[upsert-saved-via-transfer-summary] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("upsert-saved-via-transfer-summary auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const body = await req.json().catch(() => ({}));
  const savedViaTransferThisMonth = parseAmount(body.saved_via_transfer_this_month);

  if (savedViaTransferThisMonth === null) {
    return jsonResponse({ error: "saved_via_transfer_this_month (a numeric string) is required" }, 400);
  }

  try {
    const { error: rpcError } = await supabase.rpc("set_saved_via_transfer_summary", {
      p_requesting_user_id: userId,
      p_saved_via_transfer_this_month: savedViaTransferThisMonth,
    });
    if (rpcError) throw rpcError;

    logPlaidOperation({ operation: "upsert-saved-via-transfer-summary", outcome: "success" });
    return jsonResponse({ ok: true });
  } catch (error) {
    logSafeError("upsert-saved-via-transfer-summary failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    return jsonResponse({ error: "Failed to update saved-via-transfer summary" }, 400);
  }
});
