// Supabase Edge Function: sync-item-transactions
//
// The user-triggered ("force a real check with the institution now") counterpart to the
// webhook-triggered background sync — both ultimately call the exact same shared engine,
// syncItemTransactionsForItem (../_shared/itemTransactionSync.ts), so there is only ever ONE
// Item-level /transactions/sync implementation in this project, never two parallel copies.
//
// WHO CALLS THIS: the iOS app's manual Dashboard/Connected-Accounts "Refresh" buttons and the
// post-Link/post-reconnect flows (see PlaidConnectionManager.syncAndImportTransactions) — the
// SAME call sites that, before this phase, called sync-transactions directly to reach Plaid. This
// function now owns that "reach Plaid" responsibility; sync-transactions itself no longer calls
// Plaid at all (see that file's own updated header) — the app calls THIS function first to force a
// real attempt, then calls sync-transactions to pull whatever this function (or a prior webhook)
// already reconciled into plaid_transactions/plaid_transaction_removals.
//
// RATE LIMIT: intentionally NONE — this preserves sync-transactions' own pre-existing behavior
// exactly (confirmed by this project's own Phase 0 cost audit: transaction sync has never been
// subject to the Dashboard's separate 2/account/day BALANCE limit, and this phase was never asked
// to introduce a new one). This function only relocates WHERE the existing, already-uncapped Plaid
// call physically happens — it does not change whether or how often it can be called.
//
// CONCURRENCY: if a webhook-triggered sync for the same Item is already in flight when this is
// called, syncItemTransactionsForItem's own atomic claim makes this call a safe, fast no-op
// (`skipped: true`) rather than a race — the in-flight sync's own results are what the app's
// immediately-following sync-transactions pull will see.
import {
  createPrivilegedClient,
  EnvironmentMismatchError,
  isValidUuid,
  jsonResponse,
  logSafeError,
  requireAuthenticatedUserId,
  SafeError,
  UnauthorizedError,
} from "../_shared/plaid.ts";
import { syncItemTransactionsForItem } from "../_shared/itemTransactionSync.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[sync-item-transactions] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("sync-item-transactions auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const { connection_id } = await req.json().catch(() => ({}));
  if (!isValidUuid(connection_id)) {
    return jsonResponse({ error: "connection_id (a valid UUID) is required" }, 400);
  }

  try {
    // Ownership check — same reused pattern as every other per-connection Plaid Edge Function in
    // this project: the connection must belong to THIS verified caller, never trusted from the
    // request body alone.
    const { data: item, error: lookupError } = await supabase
      .from("plaid_items")
      .select("id, requires_reauth, environment")
      .eq("id", connection_id)
      .eq("user_id", userId)
      .maybeSingle();
    if (lookupError) throw lookupError;
    if (!item) {
      return jsonResponse({ error: "No such connection for this account" }, 404);
    }
    if (item.requires_reauth) {
      return jsonResponse({ error: "This connection needs to be reconnected", requires_reauth: true }, 409);
    }

    const outcome = await syncItemTransactionsForItem(supabase, item.id);
    if (!outcome.success) {
      // syncItemTransactionsForItem already logged the specific cause safely; this function has
      // nothing further to add and must not guess at (or expose) what went wrong beyond a generic
      // failure — matching this project's established anti-leak convention for every other
      // Plaid-adjacent error path.
      return jsonResponse({ error: "Failed to sync transactions" }, 500);
    }

    return jsonResponse({
      connection_id: item.id,
      skipped: outcome.skipped,
      added_count: outcome.addedCount,
      modified_count: outcome.modifiedCount,
      removed_count: outcome.removedCount,
      balance_refresh_succeeded: outcome.balanceRefreshSucceeded,
    });
  } catch (error) {
    logSafeError(`sync-item-transactions failed connection_id=${typeof connection_id === "string" ? connection_id : "unknown"}`, error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof EnvironmentMismatchError) {
      return jsonResponse({ error: error.message, environment_mismatch: true }, 409);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to sync transactions" }, 500);
  }
});
