// Supabase Edge Function: exchange-public-token
//
// Called by the iOS app immediately after Plaid Link succeeds, with the public_token Link
// returned. Exchanges it for a Plaid access_token and item_id, then stores those SERVER-SIDE
// only (see ../../migrations/0001_plaid_items.sql, 0003_plaid_multi_institution.sql). The
// access_token is never included in the response sent back to the app — the app only learns
// whether the connection succeeded, plus non-sensitive institution/account identifiers.
//
// INSTITUTION-AGNOSTIC: this project no longer assumes American Express. `institution_id` and
// `institution_name` are supplied by the CALLER (the iOS app forwards Plaid Link's own
// `onSuccess` metadata — `metadata.institution.id`/`.name`, which Link's hosted UI already knows
// because the user picked their institution there) — never hardcoded here. If the caller omits
// them (an older app build, or a Link flow where Plaid didn't report institution metadata),
// this stores `null`/`"Unknown Institution"` rather than guessing.
//
// Also fetches the full account list for this Item via `/accounts/get` right after the exchange
// and stores it in `plaid_accounts` — this is what makes multiple-accounts-per-institution and
// balance sync (`sync-balances`) possible; previously no account-level data was persisted at all.
//
// AUTH: `verify_jwt = false` at the gateway (required by the new sb_publishable_/sb_secret_ key
// system — see ../_shared/plaid.ts's file header). The caller MUST send
// `Authorization: Bearer <user access token>`; requireAuthenticatedUserId validates it in code
// and derives user_id ONLY from that verified token — never from the request body.

import {
  createPrivilegedClient,
  jsonResponse,
  loadPlaidCredentials,
  logSafeError,
  plaidFetch,
  refreshPlaidAccounts,
  requireAuthenticatedUserId,
  SafeError,
  UnauthorizedError,
} from "../_shared/plaid.ts";

interface PlaidAccountSummary {
  account_id: string;
  name: string | null;
  mask: string | null;
  type: string | null;
  subtype: string | null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[exchange-public-token] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("exchange-public-token auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const { public_token, institution_id, institution_name } = await req.json().catch(() => ({}));
  if (!public_token || typeof public_token !== "string") {
    return jsonResponse({ error: "public_token is required" }, 400);
  }
  // user_id is deliberately NEVER read from the request body — only from the verified access
  // token above. The iOS app has no way to influence which user_id a plaid_items row is written
  // under.

  try {
    // Read once, up front — this is the same active environment plaidFetch itself will use for
    // this call, and it's what gets stamped onto the plaid_items row below so this Item can never
    // later be ambiguous about which Plaid environment issued its access_token.
    const { environment } = loadPlaidCredentials();

    const data = await plaidFetch("/item/public_token/exchange", { public_token });
    const accessToken = data.access_token as string;
    const itemId = data.item_id as string;
    console.log("[exchange-public-token] plaid exchange completed:", true);
    console.log("[exchange-public-token] item_id received:", typeof itemId === "string" && itemId.length > 0);
    console.log("[exchange-public-token] environment:", environment);

    const resolvedInstitutionName =
      typeof institution_name === "string" && institution_name.length > 0
        ? institution_name
        : "Unknown Institution";
    const resolvedInstitutionId = typeof institution_id === "string" && institution_id.length > 0
      ? institution_id
      : null;

    const { data: savedRow, error } = await supabase
      .from("plaid_items")
      .upsert(
        {
          user_id: userId,
          item_id: itemId,
          access_token: accessToken,
          institution_id: resolvedInstitutionId,
          institution_name: resolvedInstitutionName,
          // A fresh Item never requires re-auth and never has new-accounts pending — reset both
          // explicitly in case this upsert is reconnecting an item_id that previously had either
          // flag set (onConflict below can hit an existing row).
          requires_reauth: false,
          new_accounts_available: false,
          // Always the server's CURRENT active environment — never client-supplied, never
          // inferred from the credential format. A successful exchange just happened against
          // this exact environment, so it is by construction the correct value to stamp here,
          // even if this upsert is overwriting an existing row's prior environment value.
          environment,
          updated_at: new Date().toISOString(),
        },
        { onConflict: "item_id" }, // matches plaid_items.item_id's `unique` constraint
      )
      .select("id")
      .single();

    console.log("[exchange-public-token] plaid_items row saved:", !error);
    if (error) throw error;

    // Discover every account this Item covers (a single Item can be more than one physical
    // card/account at the same institution) and persist them — via the SAME shared helper
    // sync-balances and refresh-plaid-accounts use, so this project has exactly one place that
    // maps a Plaid account onto a plaid_accounts row (see refreshPlaidAccounts's own doc comment
    // for why duplicating that mapping per-function is exactly what caused the reconnect flow to
    // originally never discover new accounts at all). Never blocks the connection on failure: if
    // this call fails, the connection itself has already succeeded (plaid_items row is saved), so
    // this is best-effort and logged, not thrown.
    let accountSummaries: PlaidAccountSummary[] = [];
    try {
      const accountRows = await refreshPlaidAccounts(supabase, savedRow.id, accessToken);
      console.log("[exchange-public-token] accounts discovered:", accountRows.length);

      accountSummaries = accountRows.map((row) => ({
        account_id: row.account_id,
        name: row.name,
        mask: row.mask,
        type: row.type,
        subtype: row.subtype,
      }));
    } catch (accountsError) {
      logSafeError("exchange-public-token account discovery failed (connection still succeeded)", accountsError);
    }

    // Returns the plaid_items row's own opaque UUID (never the Plaid item_id, never any token
    // material) so the app can later tell disconnect-account/sync-transactions/sync-balances
    // EXACTLY which connection to target, instead of guessing among however many rows this
    // user_id has. institution_id/name and the discovered accounts are all non-sensitive
    // identifiers, safe to return.
    return jsonResponse({
      connected: true,
      connection_id: savedRow.id,
      institution_id: resolvedInstitutionId,
      institution_name: resolvedInstitutionName,
      accounts: accountSummaries,
    });
  } catch (error) {
    logSafeError("exchange-public-token failed", error);

    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    if (typeof error === "object" && error !== null && "code" in error) {
      const code = (error as { code?: string }).code;
      if (code === "23502" || code === "23503") {
        // not-null / foreign-key violation. Never surface the raw Postgres message (it can
        // include the offending value, e.g. the access_token, in plain text).
        return jsonResponse({ error: "Backend is misconfigured. Contact support." }, 500);
      }
    }
    return jsonResponse({ error: "Failed to connect account" }, 500);
  }
});
