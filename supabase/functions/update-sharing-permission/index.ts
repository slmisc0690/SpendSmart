// Supabase Edge Function: update-sharing-permission
//
// PHASE 7 — ACCOUNT RELATED OPTIONS / PRIMARY SHARING CONTROLS. Authored as backend foundation
// work; NOT deployed in this task.
//
// The single trusted write path for sharing_permissions (both global and per-item rows, all three
// categories) — never allows the client to write a sharing_permissions row directly, per this
// phase's own "Do NOT allow the client to directly write arbitrary sharing_permissions rows"
// requirement. household_id is resolved SERVER-SIDE from the caller's own active Primary
// membership (via get_household_state) — never trusted from the request body — so a client cannot
// even attempt to target a household it doesn't own.
//
// OWNERSHIP RE-CHECK (Phase 5B lesson, applied proactively — see migration 0011's header): before
// ever calling set_sharing_permission, this function independently re-verifies that a non-null
// item_id belongs to the caller (plaid_accounts joined through plaid_items.user_id for
// connectedAccounts, manual_accounts.owner_user_id for manualAccounts) — the SAME check migration
// 0013's set_sharing_permission also performs at the database level, so a foreign item_id is
// rejected at BOTH layers independently, never relying on either alone.
//
// Request body: { category: "connectedAccounts"|"manualAccounts"|"monthlyPlan",
//                  item_id: string|null, is_shared: boolean }

import {
  createPrivilegedClient,
  isValidUuid,
  jsonResponse,
  logPlaidOperation,
  logSafeError,
  requireAuthenticatedUserId,
  UnauthorizedError,
} from "../_shared/plaid.ts";
import { isValidSharingPermissionRequest } from "../_shared/household.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[update-sharing-permission] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("update-sharing-permission auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const body = await req.json().catch(() => ({}));
  const { is_shared } = body;

  const parsed = isValidSharingPermissionRequest(body.category, body.item_id ?? null);
  if (!parsed.valid) {
    return jsonResponse({ error: parsed.reason }, 400);
  }
  if (typeof is_shared !== "boolean") {
    return jsonResponse({ error: "is_shared (boolean) is required" }, 400);
  }
  if (parsed.itemId !== null && !isValidUuid(parsed.itemId)) {
    return jsonResponse({ error: "item_id must be a valid UUID or null" }, 400);
  }

  try {
    const { data: stateData, error: stateError } = await supabase.rpc("get_household_state", {
      p_requesting_user_id: userId,
    });
    if (stateError) throw stateError;

    const state = stateData as Record<string, unknown> | null;
    if (!state?.household_id || state.role !== "primary") {
      return jsonResponse({ error: "Only an active household Primary may update sharing permissions" }, 403);
    }
    const householdId = state.household_id as string;

    if (parsed.itemId !== null) {
      if (parsed.category === "connectedAccounts") {
        const { data: ownedAccount, error: ownedAccountError } = await supabase
          .from("plaid_accounts")
          .select("id, plaid_items!inner(user_id)")
          .eq("id", parsed.itemId)
          .eq("plaid_items.user_id", userId)
          .maybeSingle();
        if (ownedAccountError) throw ownedAccountError;
        if (!ownedAccount) {
          return jsonResponse({ error: "item_id is not a Connected Account you own" }, 403);
        }
      } else if (parsed.category === "manualAccounts") {
        const { data: ownedAccount, error: ownedAccountError } = await supabase
          .from("manual_accounts")
          .select("id")
          .eq("id", parsed.itemId)
          .eq("owner_user_id", userId)
          .maybeSingle();
        if (ownedAccountError) throw ownedAccountError;
        if (!ownedAccount) {
          return jsonResponse({ error: "item_id is not a Manual Account you own" }, 403);
        }
      }
    }

    const { data: resultId, error: setError } = await supabase.rpc("set_sharing_permission", {
      p_household_id: householdId,
      p_requesting_user_id: userId,
      p_category: parsed.category,
      p_item_id: parsed.itemId,
      p_is_shared: is_shared,
    });
    if (setError) throw setError;

    logPlaidOperation({ operation: "update-sharing-permission", outcome: "success" });
    return jsonResponse({ sharing_permission_id: resultId });
  } catch (error) {
    logSafeError("update-sharing-permission failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    return jsonResponse({ error: "Failed to update sharing permission" }, 400);
  }
});
