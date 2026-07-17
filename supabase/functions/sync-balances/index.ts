// Supabase Edge Function: sync-balances
//
// Called by the iOS app to refresh account balances for ONE linked institution. Separate from
// sync-transactions deliberately — balances and transactions are different Plaid calls
// (`/accounts/get` vs `/transactions/sync`) with different natural refresh cadences (a user might
// want to pull-to-refresh balances far more often than they resync the full transaction diff),
// and keeping them as two small, single-purpose functions keeps each one's failure mode isolated
// (a balance-fetch failure should never block or partially corrupt a transaction sync, or vice
// versa).
//
// Requires `connection_id` — same multi-institution reasoning as sync-transactions: there is no
// longer a single well-defined "the" plaid_items row for a user_id to assume.
//
// Account mapping/upsert/reactivate/soft-delete all happen inside the shared
// `refreshPlaidAccounts` helper (see ../_shared/plaid.ts) — this function's only job is the
// auth/lookup/response shape around that one shared call, so the account-mapping logic itself
// lives in exactly one place across this whole project.
//
// Returns only non-sensitive per-account fields (never access_token, never full Plaid response).

import {
  assertItemEnvironmentMatches,
  createPrivilegedClient,
  EnvironmentMismatchError,
  isValidUuid,
  jsonResponse,
  logPlaidOperation,
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

  console.log("[sync-balances] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("sync-balances auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const { connection_id } = await req.json().catch(() => ({}));
  if (!isValidUuid(connection_id)) {
    return jsonResponse({ error: "connection_id (a valid UUID) is required" }, 400);
  }

  try {
    const { data: item, error: lookupError } = await supabase
      .from("plaid_items")
      .select("id, access_token, requires_reauth, environment")
      .eq("id", connection_id)
      .eq("user_id", userId)
      .maybeSingle();

    if (lookupError) throw lookupError;
    if (!item) {
      return jsonResponse({ error: "No such connection for this account" }, 404);
    }
    // Must be checked BEFORE calling Plaid — see assertItemEnvironmentMatches's doc comment.
    assertItemEnvironmentMatches(item.environment);
    if (item.requires_reauth) {
      return jsonResponse({ error: "This connection needs to be reconnected", requires_reauth: true }, 409);
    }

    const accountRows = await refreshPlaidAccounts(supabase, item.id, item.access_token);
    console.log("[sync-balances] plaid_accounts rows saved:", accountRows.length);
    logPlaidOperation({
      operation: "sync-balances",
      outcome: "success",
      connectionId: item.id,
      accountCount: accountRows.length,
    });

    // Sanitized response — account identifiers + balances only, never access_token. Money-valued
    // fields (balances AND credit_limit) are sent as STRINGS, not JSON numbers — same reasoning
    // as sync-transactions' `amount` field: the iOS app decodes these into `Decimal` directly
    // from the string, sidestepping the JSONDecoder-through-Double precision loss a JSON number
    // literal would risk.
    return jsonResponse({
      connection_id: item.id,
      accounts: accountRows.map((row) => ({
        account_id: row.account_id,
        name: row.name,
        official_name: row.official_name,
        mask: row.mask,
        type: row.type,
        subtype: row.subtype,
        current_balance: row.current_balance != null ? String(row.current_balance) : null,
        available_balance: row.available_balance != null ? String(row.available_balance) : null,
        credit_limit: row.credit_limit != null ? String(row.credit_limit) : null,
        iso_currency_code: row.iso_currency_code,
        unofficial_currency_code: row.unofficial_currency_code,
      })),
    });
  } catch (error) {
    logSafeError(`sync-balances failed connection_id=${typeof connection_id === "string" ? connection_id : "unknown"}`, error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof EnvironmentMismatchError) {
      return jsonResponse({ error: error.message, environment_mismatch: true }, 409);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to sync balances" }, 500);
  }
});
