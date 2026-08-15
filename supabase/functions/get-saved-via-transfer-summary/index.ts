// Supabase Edge Function: get-saved-via-transfer-summary
//
// SAVED VIA TRANSFER SHARING. Structurally identical to get-monthly-savings-summary — see that
// function's own header for the fully-argued trust-boundary/anti-enumeration rationale, repeated
// only in summary here:
//
// - Caller identity comes ONLY from requireAuthenticatedUserId() — the request body has no
//   recipient/owner-as-caller identity field at all.
// - Authorization is entirely delegated to public.get_shared_saved_via_transfer_summary
//   (migration 0023), which itself delegates the actual Secondary-permission decision to the
//   canonical is_effectively_shared_for_user evaluator (migration 0008), always with category =
//   'savedViaTransfer' and item_id = NULL (savedViaTransfer sharing is GLOBAL ONLY) — no
//   permission logic is duplicated here, in SQL, or anywhere else.
// - Anti-enumeration: an owner with no summary row, an unrelated owner, and a genuinely-connected
//   but not-shared owner all produce the identical response — a `summary` of `null`.
// - READ-ONLY: this function performs no write of any kind.
// - AGGREGATE-ONLY: returns exactly the one authorized total (`saved_via_transfer_this_month`)
//   plus `updated_at` — never individual transaction rows, never which account(s) were involved.
//
// Request body: { owner_user_id: string (a UUID — whose Saved-via-Transfer summary to read; the
// CALLER's own identity is separately, independently verified via requireAuthenticatedUserId and
// is never influenced by this field). }

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

  console.log("[get-saved-via-transfer-summary] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("get-saved-via-transfer-summary auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const { owner_user_id } = await req.json().catch(() => ({}));
  if (!isValidUuid(owner_user_id)) {
    return jsonResponse({ error: "owner_user_id (a valid UUID) is required" }, 400);
  }

  try {
    const { data, error } = await supabase.rpc("get_shared_saved_via_transfer_summary", {
      p_caller_user_id: userId,
      p_owner_user_id: owner_user_id,
    });
    if (error) throw error;

    const row = (data as Record<string, unknown>[] | null)?.[0] ?? null;

    logPlaidOperation({
      operation: "get-saved-via-transfer-summary",
      outcome: "success",
      accountCount: row ? 1 : 0,
    });

    if (!row) {
      // Never distinguishes "no summary exists" from "exists but not shared with you" — see this
      // file's header.
      return jsonResponse({ summary: null });
    }

    // Money-valued field as a STRING, not a JSON number — same convention as
    // get-monthly-savings-summary and every other money field this project sends to iOS.
    return jsonResponse({
      summary: {
        saved_via_transfer_this_month: row.saved_via_transfer_this_month != null
          ? String(row.saved_via_transfer_this_month)
          : null,
        updated_at: row.updated_at,
      },
    });
  } catch (error) {
    logSafeError("get-saved-via-transfer-summary failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to retrieve saved-via-transfer summary" }, 500);
  }
});
