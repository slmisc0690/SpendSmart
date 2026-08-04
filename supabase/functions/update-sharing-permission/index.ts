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
// PHASE 8D — SECONDARY CONNECTED/MANUAL ACCOUNT SHARING: an active Secondary caller may ALSO
// reach this endpoint, but only for category="connectedAccounts" OR category="manualAccounts",
// each with a non-null item_id they themselves own — never a global toggle, never monthlyPlan
// (this phase's own locked "Secondary gets only Share Connected Account + Share Manual Account"
// requirement). Each category is delegated to its own migration-0015 function
// (set_secondary_connected_account_sharing / set_secondary_manual_account_sharing), both of which
// independently re-derive the caller's own household from their ACTIVE SECONDARY membership
// (never trusted from the client) and perform their own item-ownership re-check below — the
// connectedAccounts check mirrors the Primary path's own plaid_accounts/plaid_items join;
// manualAccounts checks manual_accounts.owner_user_id directly, since that table carries its own
// owner column. Every other Secondary request (global, monthlyPlan, or no item_id) is rejected
// with 403, matching the existing Primary-only 403 shape.
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

    if (state?.role === "secondary") {
      // PHASE 8D — the ONLY writes a Secondary may ever make through this endpoint: their own
      // Connected Account or their own Manual Account, per-item, nothing else.
      if (parsed.itemId === null || (parsed.category !== "connectedAccounts" && parsed.category !== "manualAccounts")) {
        return jsonResponse({ error: "A Secondary may only share their own individual Connected or Manual Accounts" }, 403);
      }

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

        const { data: resultId, error: setError } = await supabase.rpc("set_secondary_connected_account_sharing", {
          p_requesting_user_id: userId,
          p_item_id: parsed.itemId,
          p_is_shared: is_shared,
        });
        if (setError) throw setError;

        logPlaidOperation({ operation: "update-sharing-permission", outcome: "secondary_connected_success" });
        return jsonResponse({ sharing_permission_id: resultId });
      }

      // category === "manualAccounts"
      const { data: ownedManualAccount, error: ownedManualAccountError } = await supabase
        .from("manual_accounts")
        .select("id")
        .eq("id", parsed.itemId)
        .eq("owner_user_id", userId)
        .maybeSingle();
      if (ownedManualAccountError) throw ownedManualAccountError;
      if (!ownedManualAccount) {
        return jsonResponse({ error: "item_id is not a Manual Account you own" }, 403);
      }

      const { data: resultId, error: setError } = await supabase.rpc("set_secondary_manual_account_sharing", {
        p_requesting_user_id: userId,
        p_item_id: parsed.itemId,
        p_is_shared: is_shared,
      });
      if (setError) throw setError;

      logPlaidOperation({ operation: "update-sharing-permission", outcome: "secondary_manual_success" });
      return jsonResponse({ sharing_permission_id: resultId });
    }

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
