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
    // Revoke every Plaid connection this user has before deleting the rows — best-effort per
    // item, so one already-invalid token never blocks the rest of account deletion.
    const { data: items, error: fetchError } = await supabase
      .from("plaid_items")
      .select("access_token, environment")
      .eq("user_id", userId);
    if (fetchError) throw fetchError;

    let revokedCount = 0;
    let skippedCount = 0;

    // Read once — an Item created under a different Plaid environment than the one this server is
    // currently active under must never have its access_token sent to the CURRENT host (see
    // assertItemEnvironmentMatches's doc comment). Account deletion itself must still proceed
    // regardless — a mismatched item is skipped here (not revoked at Plaid) exactly like an
    // already-failed revoke is: best-effort, logged, non-fatal to the rest of this function.
    const { environment: activeEnvironment } = loadPlaidCredentials();

    for (const item of items ?? []) {
      if (item.environment !== activeEnvironment) {
        logSafeError(
          "delete-account: skipped revoking a Plaid item created under a different environment",
          new SafeError(`item environment="${item.environment ?? "unknown"}" active="${activeEnvironment}"`),
        );
        skippedCount += 1;
        continue;
      }
      try {
        await plaidFetch("/item/remove", { access_token: item.access_token });
        revokedCount += 1;
      } catch (revokeError) {
        logSafeError("delete-account: failed to revoke a Plaid item", revokeError);
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
    console.log("[delete-account] plaid items revoked:", revokedCount, "skipped (environment mismatch):", skippedCount);

    return jsonResponse({ deleted: true });
  } catch (error) {
    logSafeError("delete-account failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    return jsonResponse({ error: "Failed to delete account" }, 500);
  }
});
