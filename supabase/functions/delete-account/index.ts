// Supabase Edge Function: delete-account
//
// Called by the iOS app's Account screen "Delete Account" action, after a strong, typed
// confirmation in the UI (see AccountView.swift — requires literally typing "DELETE"). Revokes
// every Plaid connection this user has, deletes every row this user owns, then deletes the
// auth.users row itself via the Admin API. Irreversible — there is no soft-delete/undo for this.
//
// AUTH: `verify_jwt = false` at the gateway (same reason as the Plaid functions — see
// ../_shared/plaid.ts's file header: the new sb_publishable_/sb_secret_ key system doesn't work
// with gateway-level verify_jwt). Requires `Authorization: Bearer <user access token>`, validated
// in code via requireAuthenticatedUserId — never a user id from the request body.

import {
  createPrivilegedClient,
  jsonResponse,
  loadPlaidCredentials,
  logPlaidOperation,
  logSafeError,
  plaidFetch,
  requireAuthenticatedUserId,
  SafeError,
  UnauthorizedError,
} from "../_shared/plaid.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[delete-account] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("delete-account auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  try {
    // Revoke every Plaid connection this user has before deleting the rows — a revoke failure
    // never blocks the REST of account deletion (one broken bank connection must never trap a
    // user who wants to leave), but ITEM-LEAK CLOSURE requires that a row is never deleted below
    // without EITHER a confirmed successful /item/remove here, OR a durable orphan record in
    // plaid_item_removal_failures (see that migration's own header). The orphan-insert is a HARD
    // PRECONDITION for an un-revoked item, never best-effort — see the throw inside the loop.
    const { data: items, error: fetchError } = await supabase
      .from("plaid_items")
      .select("item_id, access_token, environment")
      .eq("user_id", userId);
    if (fetchError) throw fetchError;

    let revokedCount = 0;
    let orphanedCount = 0;

    // Read once — an Item created under a different Plaid environment than the one this server is
    // currently active under must never have its access_token sent to the CURRENT host (see
    // assertItemEnvironmentMatches's doc comment).
    const { environment: activeEnvironment } = loadPlaidCredentials();

    for (const item of items ?? []) {
      let revoked = false;
      let reason: "environment_mismatch" | "revoke_failed" | null = null;

      if (item.environment !== activeEnvironment) {
        logSafeError(
          "delete-account: cannot revoke a Plaid item created under a different environment",
          new SafeError(`item environment="${item.environment ?? "unknown"}" active="${activeEnvironment}"`),
        );
        reason = "environment_mismatch";
      } else {
        try {
          await plaidFetch("/item/remove", { access_token: item.access_token });
          revoked = true;
          revokedCount += 1;
        } catch (revokeError) {
          logSafeError("delete-account: failed to revoke a Plaid item", revokeError);
          reason = "revoke_failed";
        }
      }

      if (!revoked) {
        // OUTCOME 2/3 — this item was neither revoked nor is it about to be. Record it BEFORE
        // this loop is allowed to continue toward deleting plaid_items below; if this insert
        // itself fails, abort the ENTIRE request (outcome 3) rather than let the row disappear
        // with zero record anywhere of an Item that may still be billing.
        const { error: orphanInsertError } = await supabase.from("plaid_item_removal_failures").insert({
          item_id: item.item_id,
          access_token: item.access_token,
          environment: item.environment,
          reason,
        });
        if (orphanInsertError) {
          logSafeError("delete-account: failed to record an un-revoked Plaid item; aborting deletion", orphanInsertError);
          throw new SafeError(
            "Could not confirm your connected accounts were safely disconnected. Nothing was deleted — please try again.",
          );
        }
        orphanedCount += 1;
      }
    }

    // plaid_items is the only user-owned table that exists in this project today — the finance
    // tables (accounts, transactions, etc.) haven't been created yet; this project is still
    // Phase 1, local-only SwiftData for finance data (see the migration plan). Extend this list
    // as each new cloud table ships.
    const { error: deleteItemsError } = await supabase.from("plaid_items").delete().eq("user_id", userId);
    if (deleteItemsError) throw deleteItemsError;

    const { error: adminDeleteError } = await supabase.auth.admin.deleteUser(userId);
    if (adminDeleteError) throw adminDeleteError;

    console.log("[delete-account] account deleted:", true);
    logPlaidOperation({
      operation: "delete-account",
      outcome: "success",
      environment: activeEnvironment,
      accountCount: (items ?? []).length,
    });
    console.log("[delete-account] plaid items revoked:", revokedCount, "orphaned (recorded, not revoked):", orphanedCount);

    return jsonResponse({ deleted: true });
  } catch (error) {
    logSafeError("delete-account failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to delete account" }, 500);
  }
});
