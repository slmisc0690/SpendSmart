// Supabase Edge Function: get-connected-account-transactions
//
// PHASE 4 — CONNECTED ACCOUNT CLOUD-SHARING FOUNDATION. Authored as part of this phase's backend
// foundation work; NOT deployed, NOT wired into any iOS UI (see this phase's own scope — Secondary
// shared-data UI is explicitly out of scope). Demonstrates the trusted read path end-to-end: a
// caller (eventually a Secondary, in a future phase) retrieves READ-ONLY transaction data for ONE
// Connected Account, gated entirely by the database's own canonical permission evaluator.
//
// TRUST BOUNDARY: iOS -> this function -> requireAuthenticatedUserId() -> server-verified caller
// identity -> public.get_connected_account_transactions(...), via this function's own privileged
// (service_role) client. The request body's caller identity is NEVER trusted — there is no
// "recipient_user_id" field in the request body at all, specifically so a client can never spoof
// another user's identity for permission-evaluation purposes (see migration
// 0010_plaid_transactions_normalized.sql's own comment on why get_connected_account_transactions
// is granted to service_role only, never to `authenticated`).
//
// Request body: { plaid_account_id: string (a UUID — public.plaid_accounts.id, NEVER
// plaid_items.id, per this project's locked sharing-key semantics for the 'connectedAccounts'
// category), limit?: number }.
//
// AUTHORIZATION: entirely delegated to public.get_connected_account_transactions — this function
// contains NO permission logic of its own (no owner check, no household check, no
// sharing_permissions read). Per this phase's explicit instruction ("Do not duplicate permission
// logic in TypeScript"), the database evaluator is the single, authoritative decision-maker; this
// function only verifies WHO is calling, never WHETHER they're allowed to see this data.
//
// ANTI-ENUMERATION: an unknown account id, an account belonging to someone the caller has no
// household relationship with, and an account that exists and IS connected but isn't shared all
// produce the exact same response — an empty `transactions` array, HTTP 200 — never a 403/404 that
// would let a caller distinguish "doesn't exist" from "exists but not shared with you." This
// mirrors the SQL function's own anti-enumeration stance (see its doc comment in the migration).
//
// READ-ONLY: this function performs no write of any kind — it is the read half of Phase 4's
// foundation only. No editing/deleting/refreshing/disconnecting/permission-changing path exists
// here or is reachable through here.
//
// AUTH: verify_jwt = false at the gateway (same reason as every other user-invoked function in
// this project — see ../_shared/plaid.ts's file header) — this function performs its own auth
// check in code via requireAuthenticatedUserId, never trusting the gateway to have done it.

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

const DEFAULT_LIMIT = 200;
const MAX_LIMIT = 500;

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[get-connected-account-transactions] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("get-connected-account-transactions auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const { plaid_account_id, limit } = await req.json().catch(() => ({}));
  if (!isValidUuid(plaid_account_id)) {
    return jsonResponse({ error: "plaid_account_id (a valid UUID) is required" }, 400);
  }
  // Never trust a caller-supplied limit unbounded — the SQL function itself re-clamps this too
  // (defense in depth, since this function is not the only conceivable caller of that RPC in the
  // future), but validating/clamping here as well means a malformed value never even reaches the
  // database call.
  const requestedLimit = typeof limit === "number" && Number.isFinite(limit) ? Math.trunc(limit) : DEFAULT_LIMIT;
  const clampedLimit = Math.min(Math.max(requestedLimit, 1), MAX_LIMIT);

  try {
    const { data, error } = await supabase.rpc("get_connected_account_transactions", {
      p_caller_user_id: userId,
      p_plaid_account_id: plaid_account_id,
      p_limit: clampedLimit,
    });
    if (error) throw error;

    const rows = (data as Record<string, unknown>[] | null) ?? [];

    logPlaidOperation({
      operation: "get-connected-account-transactions",
      outcome: "success",
      accountCount: rows.length,
    });

    // Passed through verbatim — the SQL function's own RETURNS TABLE column list is already the
    // exact, narrow, non-sensitive shape this response should carry (see migration 0010's doc
    // comment on get_connected_account_transactions): never plaid_account_id, never owner_user_id,
    // never anything from plaid_items/plaid_accounts, never an access_token or any credential.
    // Money-valued (`amount`) as a STRING, not the JSON number Postgres/PostgREST would otherwise
    // serialize it as — same reasoning as every other money field this project sends to iOS
    // (sync-transactions/refresh-connected-account): a JSON number round-trips through Double
    // before an iOS JSONDecoder ever sees it, which can silently corrupt exact cent values.
    return jsonResponse({
      transactions: rows.map((row) => ({
        id: row.id,
        transaction_id: row.transaction_id,
        pending_transaction_id: row.pending_transaction_id,
        original_description: row.original_description,
        merchant_name: row.merchant_name,
        amount: row.amount != null ? String(row.amount) : null,
        authorized_date: row.authorized_date,
        posted_date: row.posted_date,
        transaction_date: row.transaction_date,
        is_pending: row.is_pending,
        created_at: row.created_at,
        updated_at: row.updated_at,
      })),
    });
  } catch (error) {
    logSafeError("get-connected-account-transactions failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to retrieve transactions" }, 500);
  }
});
