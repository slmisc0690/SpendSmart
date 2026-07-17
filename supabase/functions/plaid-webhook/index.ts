// Supabase Edge Function: plaid-webhook
//
// Plaid calls this URL directly (server-to-server) whenever an Item's state changes — new
// transaction data ready, the connection needs re-authentication, a consent window is about to
// expire, new accounts became available at the institution, etc. The iOS app never calls this
// function directly; it's configured as the webhook URL in the Plaid Dashboard / passed to
// `/link/token/create`'s `webhook` param.
//
// AUTH: deliberately NOT authenticated by a Supabase user JWT — Plaid calls this directly,
// server-to-server, with no end-user session to attach. Instead this verifies Plaid's own
// webhook signature (see `verifyPlaidWebhookSignature` in `../_shared/plaid.ts`) BEFORE trusting
// anything in the payload, and once verified, locates the affected `plaid_items` row by Plaid's
// own `item_id` via the privileged client — never by trusting any `user_id` the request claims,
// since there is no authenticated user attached to this call at all.
//
// WHAT THIS DOES NOT DO: it does not call sync-transactions or sync-balances itself. Webhooks
// only flip STATE FLAGS on the affected plaid_items row (requires_reauth,
// pending_expiration_at, new_accounts_available) — the iOS app reads those flags (via whatever
// "list my connections" call it already makes) and decides when to actually prompt the user or
// re-sync. Keeping this function state-only, not action-triggering, means a webhook replay or a
// burst of duplicate webhooks (Plaid explicitly does not guarantee exactly-once delivery) can
// never cause a duplicate sync or a race with a sync already in progress — every handler below is
// a plain idempotent UPDATE.

import {
  computePlaidWebhookUpdates,
  createPrivilegedClient,
  isRecognizedPlaidWebhook,
  jsonResponse,
  logPlaidOperation,
  logSafeError,
  verifyPlaidWebhookSignature,
} from "../_shared/plaid.ts";

interface PlaidWebhookPayload {
  webhook_type?: string;
  webhook_code?: string;
  item_id?: string;
  // Present on PENDING_EXPIRATION — an ISO8601-ish timestamp string per Plaid's docs.
  consent_expiration_time?: string;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  // Read the raw body ONCE, as text — verification needs the exact original bytes (see
  // verifyPlaidWebhookSignature's doc comment for why re-serializing would break the hash check),
  // and the payload is parsed from this same string afterward rather than via req.json() again
  // (a Request body can only be consumed once).
  const rawBody = await req.text();

  // Wrapped explicitly: verifyPlaidWebhookSignature can throw (e.g. a Plaid API/network failure
  // while fetching the verification key, or a malformed JWK Web Crypto rejects) rather than
  // returning false for every failure mode. An uncaught throw here would still never process the
  // payload (Deno.serve just surfaces it as an unhandled 500), so it was never a path to
  // accepting an unverified webhook — but it also isn't a clean, intentional rejection, so treat
  // any thrown error the same as a failed verification: log it, then respond with the same flat
  // 401 as every other verification failure.
  let verified: boolean;
  try {
    verified = await verifyPlaidWebhookSignature(req, rawBody);
  } catch (error) {
    logSafeError("[plaid-webhook] signature verification threw", error);
    verified = false;
  }
  if (!verified) {
    // Never say which check failed (missing header vs bad signature vs stale timestamp vs body
    // mismatch vs a lookup error) — that would help an attacker iterate toward a forged webhook.
    // A flat 401 with no detail either way.
    console.error("[plaid-webhook] signature verification failed");
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  let payload: PlaidWebhookPayload;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return jsonResponse({ error: "Invalid JSON" }, 400);
  }

  const webhookType = typeof payload.webhook_type === "string" ? payload.webhook_type : null;
  const webhookCode = typeof payload.webhook_code === "string" ? payload.webhook_code : null;
  const itemId = typeof payload.item_id === "string" ? payload.item_id : null;

  // Deliberately logs only a small, known-safe summary — never the raw payload, since Plaid
  // webhook bodies aren't guaranteed never to carry anything sensitive in future webhook types.
  // item_id is Plaid's own Item identifier, safe to log (it's how Plaid Support correlates a
  // webhook delivery back to a specific Item) and distinct from any of this project's own
  // internal ids.
  console.log("[plaid-webhook] verified webhook received:", { webhook_type: webhookType, webhook_code: webhookCode, item_id: itemId });

  if (!itemId) {
    // WEBHOOK_UPDATE_ACKNOWLEDGED (sent after you call /webhook/update) and a few other
    // account-level webhook types don't carry an item_id — nothing to look up, just acknowledge.
    console.log("[plaid-webhook] no item_id on this webhook, nothing to update:", { webhook_code: webhookCode });
    return jsonResponse({ received: true });
  }

  const supabase = createPrivilegedClient();

  try {
    // Looked up by Plaid's own item_id, globally unique — no user_id needed or trusted from the
    // payload.
    const { data: item, error: lookupError } = await supabase
      .from("plaid_items")
      .select("id")
      .eq("item_id", itemId)
      .maybeSingle();
    if (lookupError) throw lookupError;

    if (!item) {
      // A webhook for an Item this project doesn't have a row for (already disconnected, or a
      // stale/duplicate delivery after a disconnect) — acknowledge, don't error. Plaid retries on
      // non-2xx, and retrying forever for an Item that will never exist here again helps no one.
      console.log("[plaid-webhook] no matching plaid_items row (already disconnected?):", { item_id: itemId, matched: false });
      return jsonResponse({ received: true });
    }

    const nowIso = new Date().toISOString();
    const updates: Record<string, unknown> = {
      last_webhook_code: webhookCode,
      last_webhook_at: nowIso,
      // See computePlaidWebhookUpdates's own doc comment for the full list of webhook
      // type/codes this handles and why the mapping lives there instead of inline here.
      ...computePlaidWebhookUpdates(webhookType, webhookCode, payload, nowIso),
    };

    if (!isRecognizedPlaidWebhook(webhookType, webhookCode)) {
      // Every other webhook type/code (including the pre-existing SYNC_UPDATES_AVAILABLE, which
      // the app currently discovers via its own polling/pull-to-refresh instead) is logged but
      // not acted on — intentionally conservative: only flip a flag for webhook codes this
      // project has an actual, tested response to.
      console.log("[plaid-webhook] unhandled webhook type/code, logged only:", { webhook_type: webhookType, webhook_code: webhookCode });
    }

    const { error: updateError } = await supabase
      .from("plaid_items")
      .update(updates)
      .eq("id", item.id);
    if (updateError) throw updateError;

    console.log("[plaid-webhook] plaid_items row updated:", true);
    logPlaidOperation({
      operation: "plaid-webhook",
      outcome: "success",
      connectionId: item.id,
      itemId,
      webhookType: webhookType ?? undefined,
      webhookCode: webhookCode ?? undefined,
    });
    return jsonResponse({ received: true });
  } catch (error) {
    logSafeError(`plaid-webhook processing failed item_id=${itemId}`, error);
    // Still 200 — Plaid retries on non-2xx, and a transient Postgres error here shouldn't cause
    // Plaid to hammer this endpoint; the webhook's effect (e.g. reauth prompt) is best-effort,
    // not the sole mechanism the app depends on (the user will also eventually hit a failed sync
    // and can be prompted to reconnect from there).
    return jsonResponse({ received: true });
  }
});
