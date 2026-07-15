// Supabase Edge Function: refresh-plaid-accounts
//
// Called by the iOS app right after a Link UPDATE MODE session succeeds (reconnecting an
// existing institution — see create-link-token's connection_id branch), to actually discover any
// account this Item now covers that plaid_accounts doesn't have yet. Before this function
// existed, a successful reconnect only re-ran sync-transactions — it never called Plaid's
// /accounts/get again, so NEW_ACCOUNTS_AVAILABLE's "reconnect to add them" UI prompt led to a
// flow that didn't actually discover anything. This function is the fix: the ONE place that runs
// account discovery for an EXISTING connection, sharing its account-mapping logic with
// exchange-public-token (a NEW connection's discovery) via refreshPlaidAccounts in
// ../_shared/plaid.ts — never duplicated.
//
// ALSO clears plaid_items.requires_reauth AND new_accounts_available, but ONLY on a fully
// successful call, and ONLY together — never speculatively, never based on a client-supplied
// "trust me, Link succeeded" flag. The reasoning: by the time this function's own /accounts/get
// call (inside refreshPlaidAccounts) succeeds, that's already the strongest possible proof the
// Item's access_token is valid again — Plaid rejects /accounts/get for an Item still in
// ITEM_LOGIN_REQUIRED state exactly like it would /transactions/sync, so a successful call here
// could ONLY happen after a genuinely successful reconnect. That makes trusting a client-supplied
// success flag both unnecessary and strictly weaker than what this function already verifies
// server-side. If discovery fails for any reason, this returns an error and leaves BOTH flags
// untouched — the existing Item, its access_token, and every already-synced account/transaction
// are all left exactly as they were; nothing here is destructive on failure.
//
// AUTH: same model as every other user-invoked function — verify_jwt = false at the gateway,
// authenticated in code via requireAuthenticatedUserId, every query scoped by user_id.

import {
  assertItemEnvironmentMatches,
  createPrivilegedClient,
  EnvironmentMismatchError,
  isValidUuid,
  jsonResponse,
  logSafeError,
  refreshPlaidAccounts,
  requireAuthenticatedUserId,
  SafeError,
  UnauthorizedError,
} from "../_shared/plaid.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[refresh-plaid-accounts] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("refresh-plaid-accounts auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const { connection_id } = await req.json().catch(() => ({}));
  if (!isValidUuid(connection_id)) {
    return jsonResponse({ error: "connection_id (a valid UUID) is required" }, 400);
  }

  try {
    const { data: item, error: lookupError } = await supabase
      .from("plaid_items")
      .select("id, access_token, environment")
      .eq("id", connection_id)
      .eq("user_id", userId)
      .maybeSingle();
    if (lookupError) throw lookupError;
    if (!item) {
      return jsonResponse({ error: "No such connection for this account" }, 404);
    }
    // Must be checked BEFORE calling Plaid, unconditionally — unlike the requires_reauth check
    // deliberately skipped just below, an environment mismatch is never something a reconnect can
    // fix by itself; see assertItemEnvironmentMatches's doc comment.
    assertItemEnvironmentMatches(item.environment);

    // Deliberately does NOT check `requires_reauth` before calling this — unlike
    // sync-transactions/sync-balances, THIS function's whole purpose is to be the first call
    // after a reconnect, when requires_reauth may still be true from the caller's last known
    // state. If the reconnect genuinely didn't fix the credentials, Plaid's /accounts/get call
    // inside refreshPlaidAccounts below will itself fail, and that failure is what correctly
    // leaves requires_reauth untouched (see this file's header comment).
    const accountRows = await refreshPlaidAccounts(supabase, item.id, item.access_token);
    console.log("[refresh-plaid-accounts] accounts discovered:", accountRows.length);

    // Only reached if refreshPlaidAccounts fully succeeded — see this file's header comment for
    // why that success is itself sufficient proof to clear both flags together.
    const { error: clearFlagsError } = await supabase
      .from("plaid_items")
      .update({ requires_reauth: false, new_accounts_available: false, updated_at: new Date().toISOString() })
      .eq("id", item.id)
      .eq("user_id", userId);
    if (clearFlagsError) throw clearFlagsError;
    console.log("[refresh-plaid-accounts] requires_reauth/new_accounts_available cleared:", true);

    return jsonResponse({
      connection_id: item.id,
      accounts: accountRows.map((row) => ({
        account_id: row.account_id,
        name: row.name,
        mask: row.mask,
        type: row.type,
        subtype: row.subtype,
      })),
    });
  } catch (error) {
    logSafeError("refresh-plaid-accounts failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof EnvironmentMismatchError) {
      return jsonResponse({ error: error.message, environment_mismatch: true }, 409);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to refresh accounts" }, 500);
  }
});
