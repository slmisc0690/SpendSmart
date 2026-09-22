// Supabase Edge Function: ack-transactions-sync
//
// CLIENT-CONFIRMED DELIVERY WATERMARK — closes a real data-loss bug found 2026-09-16: this
// project's `plaid_items.last_transactions_ack_at` watermark used to be advanced by
// `sync-transactions` itself, the INSTANT that function sent its HTTP response — regardless of
// whether the iOS client ever actually received that response or successfully persisted it into
// SwiftData. If the app was backgrounded/killed mid-request, the network dropped after the
// response left the server, or `ModelContext.save()` failed on-device for any reason, the server
// had already marked that batch "delivered" and would never include it in a future
// `sync-transactions` response (which only returns rows changed SINCE the watermark) — the
// transactions were sitting correctly in `plaid_transactions` the whole time, but permanently
// invisible to that user's Activity screen. Two real Production accounts (Wells Fargo, American
// Express) were found stuck this way; their watermarks were reset by hand as a one-time recovery
// (see the incident notes in CLAUDE.md), which only works because `PlaidTransactionImportService`'s
// import is idempotent (upsert by `external_transaction_id`) — safe to redeliver an already-known
// transaction, never a duplicate.
//
// THE FIX: `sync-transactions` no longer advances the watermark itself — it returns a `sync_token`
// (the exact instant its own query snapshot was taken) alongside the data. The iOS client calls
// THIS function, separately, only AFTER `PlaidTransactionImportService.applySync`'s
// `ModelContext.save()` has actually succeeded (see `PlaidConnectionManager.pullSyncedTransactions`).
// If that ack call itself fails (network drop, app killed before the call fires), nothing is lost:
// the watermark simply stays where it was, and the NEXT `sync-transactions` pull re-requests and
// re-receives the exact same (already-idempotent) batch. This is a strictly safer failure mode —
// "redeliver, never lose" — than the previous "acknowledge on send, never lose... unless the client
// never actually got it" design.
//
// WHY A SEPARATE FUNCTION RATHER THAN A FIELD ON THE NEXT sync-transactions CALL: the ack must
// happen exactly once, right after a successful local save, independent of whenever the next pull
// happens to occur (which could be much later, or never, if the user doesn't reopen the app) — and
// it must be safe to skip/retry on its own, without re-running the (potentially large) transaction
// query sync-transactions performs. Keeping it a tiny, single-purpose call keeps that failure mode
// isolated to exactly the one write it's responsible for.
//
// MONOTONIC GUARD: only ever advances `last_transactions_ack_at` FORWARD. A stale/duplicate/
// out-of-order ack call (e.g. a retried request arriving after a newer one already landed) is a
// safe no-op, never a regression back to an earlier watermark.
//
// AUTH: verify_jwt = false at the gateway, same as every other user-invoked function in this
// project — see ../_shared/plaid.ts's file header. This function performs its own auth check via
// requireAuthenticatedUserId, never trusting the gateway alone.
import {
  createPrivilegedClient,
  isValidUuid,
  jsonResponse,
  logSafeError,
  requireAuthenticatedUserId,
  SafeError,
  UnauthorizedError,
} from "../_shared/plaid.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[ack-transactions-sync] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("ack-transactions-sync auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const { connection_id, sync_token } = await req.json().catch(() => ({}));
  if (!isValidUuid(connection_id)) {
    return jsonResponse({ error: "connection_id (a valid UUID) is required" }, 400);
  }
  if (typeof sync_token !== "string" || sync_token.length === 0 || Number.isNaN(new Date(sync_token).getTime())) {
    return jsonResponse({ error: "sync_token (a valid ISO 8601 timestamp) is required" }, 400);
  }

  try {
    // Ownership check — same reused pattern as every other per-connection Plaid Edge Function in
    // this project: the connection must belong to THIS verified caller, never trusted from the
    // request body alone.
    const { data: item, error: lookupError } = await supabase
      .from("plaid_items")
      .select("id, last_transactions_ack_at")
      .eq("id", connection_id)
      .eq("user_id", userId)
      .maybeSingle();
    if (lookupError) throw lookupError;
    if (!item) {
      return jsonResponse({ error: "No such connection for this account" }, 404);
    }

    // MONOTONIC GUARD — see this file's own header. ISO 8601 UTC timestamps of the same format
    // sort identically as strings and as instants, so a plain string comparison is exact here
    // (both values are always produced by `Date#toISOString()`, either server-side by
    // sync-transactions or by this same comparison already having run once).
    const currentAck = item.last_transactions_ack_at as string | null;
    const isNewer = currentAck === null || sync_token > currentAck;

    if (isNewer) {
      const { error: updateError } = await supabase
        .from("plaid_items")
        .update({ last_transactions_ack_at: sync_token, updated_at: new Date().toISOString() })
        .eq("id", item.id)
        .eq("user_id", userId);
      if (updateError) throw updateError;
    }

    console.log("[ack-transactions-sync] watermark advanced:", isNewer);
    return jsonResponse({ acknowledged: true, advanced: isNewer });
  } catch (error) {
    logSafeError(`ack-transactions-sync failed connection_id=${typeof connection_id === "string" ? connection_id : "unknown"}`, error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to acknowledge transactions sync" }, 500);
  }
});
