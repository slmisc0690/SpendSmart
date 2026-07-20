// Supabase Edge Function: refresh-connected-account
//
// Called by the iOS Dashboard's per-account "Refresh" button — refreshes ONE connected account's
// balance, gated by a server-enforced maximum of 2 manual refreshes per account per UTC calendar
// day (see migration 0009_connected_account_refresh_log.sql). Deliberately a NEW, separate
// function rather than adding this to sync-balances/refresh-plaid-accounts: those two are
// whole-connection (whole plaid_items Item) operations with no rate limit at all, and this one is
// specifically account-scoped and rate-limited — keeping them separate means neither an existing
// working function nor its own tests need to change, and this function's own failure mode stays
// isolated.
//
// IMPORTANT PLAID ARCHITECTURE CONSTRAINT (confirmed by reading this project's existing code, not
// assumed): Plaid's `/accounts/get` — the only account-balance endpoint this project uses — has no
// `account_ids` filter parameter at all (only `/accounts/balance/get` supports that, and this
// project never calls it). A single Plaid call therefore always returns EVERY account under the
// requested Item, via the existing shared `refreshPlaidAccounts` helper, completely unmodified
// here. This function still enforces the rate limit and returns data scoped to exactly the one
// requested account: if two accounts happen to share the same institution/Item, refreshing one
// harmlessly also re-fetches its sibling's balance as an unavoidable side effect of Plaid's own
// API shape, but the daily counter and the response returned to the client are scoped only to the
// specific `account_id` the caller asked for. Different institutions are always separate
// `plaid_items` rows, so refreshing one institution's account never touches another institution's
// data at all.
//
// Request body: { connection_id: string (plaid_items.id, a UUID), account_id: string (Plaid's own
// account_id, not this project's plaid_accounts.id) } — both already available to the iOS client
// today via PlaidConnectionManager, with no need to expose plaid_accounts.id (the internal server
// primary key) to the client at all.
//
// RATE-LIMIT CONSUMPTION DESIGN (stated explicitly, not left ambiguous): the atomic claim
// (claim_connected_account_refresh) is attempted BEFORE calling Plaid — this is what keeps the
// check race-safe: calling Plaid first and recording the attempt afterward would let two
// simultaneous requests both reach Plaid before either recorded anything, bypassing the limit
// entirely. If the claim is rejected (today's 2 refreshes already used), Plaid is never called and
// nothing is consumed.
//
// If the claim succeeds, the Plaid call (refreshPlaidAccounts, which wraps the actual
// `/accounts/get` HTTP call — the genuinely billable operation) is then attempted. A user must not
// lose one of today's 2 refreshes for an attempt that never actually delivered fresh data, so if
// THAT call itself throws (network failure before reaching Plaid, or Plaid's own API call
// returning an error), the claim is released via `release_connected_account_refresh` before the
// error propagates — this specific request never reached a successful, billed Plaid round-trip.
// The claim is NOT released if `refreshPlaidAccounts` succeeds but the specific requested account
// simply isn't in Plaid's response (see the 404 branch below) — Plaid genuinely answered and that
// round-trip was really billed, it just didn't happen to include this one account. Releasing is a
// plain relative decrement gated to today's row, safe to interleave with any concurrent claim on
// the same row (see the SQL function's own doc comment) — it can only ever give back a slot for an
// attempt that didn't complete, never let more than 2 successful refreshes happen in one UTC day.
//
// Returns only non-sensitive fields for the ONE requested account — never access_token, never
// other accounts' data, never the internal plaid_accounts.id.

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

  console.log("[refresh-connected-account] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("refresh-connected-account auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const { connection_id, account_id } = await req.json().catch(() => ({}));
  if (!isValidUuid(connection_id)) {
    return jsonResponse({ error: "connection_id (a valid UUID) is required" }, 400);
  }
  if (typeof account_id !== "string" || account_id.length === 0) {
    return jsonResponse({ error: "account_id is required" }, 400);
  }

  try {
    // Ownership step 1 — same reused pattern as sync-balances: the connection must belong to
    // THIS verified caller, never trusted from the request body.
    const { data: item, error: itemLookupError } = await supabase
      .from("plaid_items")
      .select("id, access_token, requires_reauth, environment")
      .eq("id", connection_id)
      .eq("user_id", userId)
      .maybeSingle();

    if (itemLookupError) throw itemLookupError;
    if (!item) {
      return jsonResponse({ error: "No such connection for this account" }, 404);
    }
    // Must be checked BEFORE calling Plaid — see assertItemEnvironmentMatches's doc comment.
    assertItemEnvironmentMatches(item.environment);
    if (item.requires_reauth) {
      return jsonResponse({ error: "This connection needs to be reconnected", requires_reauth: true }, 409);
    }

    // Ownership step 2 — resolve THIS account's own plaid_accounts.id, scoped to the
    // already-verified connection above (never a bare account_id lookup with no connection
    // filter, which could otherwise match a different user's account that happens to reuse the
    // same Plaid account_id string — Plaid documents account_id as unique only WITHIN an Item,
    // never globally). plaid_accounts.id itself is never returned to the client — it exists only
    // as the rate-limit table's foreign key.
    const { data: account, error: accountLookupError } = await supabase
      .from("plaid_accounts")
      .select("id")
      .eq("plaid_item_id", item.id)
      .eq("account_id", account_id)
      .maybeSingle();

    if (accountLookupError) throw accountLookupError;
    if (!account) {
      return jsonResponse({ error: "No such account for this connection" }, 404);
    }

    // Atomic claim — BEFORE calling Plaid (see this file's header comment for why).
    const { data: claimedCount, error: claimError } = await supabase.rpc(
      "claim_connected_account_refresh",
      { p_user_id: userId, p_plaid_account_id: account.id },
    );
    if (claimError) throw claimError;

    if (claimedCount == null) {
      logPlaidOperation({
        operation: "refresh-connected-account",
        outcome: "failure",
        connectionId: item.id,
      });
      return jsonResponse({ error: "Daily refresh limit reached for this account", remaining: 0 }, 429);
    }

    // The claim succeeded — Plaid is now genuinely called. If THIS call itself fails (network
    // error before reaching Plaid, or Plaid's own API call returning an error), the claim is
    // released below rather than staying consumed — see this file's header comment.
    let accountRows;
    try {
      accountRows = await refreshPlaidAccounts(supabase, item.id, item.access_token);
    } catch (plaidError) {
      try {
        const { error: releaseError } = await supabase.rpc("release_connected_account_refresh", {
          p_user_id: userId,
          p_plaid_account_id: account.id,
        });
        if (releaseError) throw releaseError;
      } catch (releaseFailure) {
        // Never let a release-path failure mask the original Plaid error, and never let it stop
        // that original error from propagating — worst case here is a consumed attempt stays
        // consumed (strictly LESS available allowance than intended), which can never let anyone
        // exceed today's 2-refresh cap.
        logSafeError("refresh-connected-account release-on-failure also failed", releaseFailure);
      }
      throw plaidError;
    }
    const refreshedRow = accountRows.find((row) => row.account_id === account_id);
    if (!refreshedRow) {
      // The account existed a moment ago (ownership check above) but Plaid's response no longer
      // includes it — Plaid genuinely answered (a real, billed round-trip happened), so this is
      // NOT released; treat as a genuine, if rare, not-found rather than guessing at stale data.
      return jsonResponse({ error: "Account no longer available from this connection" }, 404);
    }

    logPlaidOperation({
      operation: "refresh-connected-account",
      outcome: "success",
      connectionId: item.id,
      accountCount: 1,
    });

    // Same sanitized per-account shape sync-balances already sends — never access_token, never
    // other accounts' data, never plaid_accounts.id. Money-valued fields as STRINGS (same
    // reasoning as sync-balances: sidesteps JSONDecoder-through-Double precision loss).
    return jsonResponse({
      connection_id: item.id,
      account: {
        account_id: refreshedRow.account_id,
        name: refreshedRow.name,
        official_name: refreshedRow.official_name,
        mask: refreshedRow.mask,
        type: refreshedRow.type,
        subtype: refreshedRow.subtype,
        current_balance: refreshedRow.current_balance != null ? String(refreshedRow.current_balance) : null,
        available_balance: refreshedRow.available_balance != null ? String(refreshedRow.available_balance) : null,
        credit_limit: refreshedRow.credit_limit != null ? String(refreshedRow.credit_limit) : null,
        iso_currency_code: refreshedRow.iso_currency_code,
        unofficial_currency_code: refreshedRow.unofficial_currency_code,
      },
      remaining: 2 - claimedCount,
    });
  } catch (error) {
    logSafeError(`refresh-connected-account failed connection_id=${typeof connection_id === "string" ? connection_id : "unknown"}`, error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof EnvironmentMismatchError) {
      return jsonResponse({ error: error.message, environment_mismatch: true }, 409);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to refresh account" }, 500);
  }
});
