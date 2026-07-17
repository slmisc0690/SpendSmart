// Supabase Edge Function: create-link-token
//
// Called by the iOS app to get a short-lived link_token, which is handed to Plaid Link so the
// user can log into a financial institution through Plaid's own hosted UI — ANY institution Plaid
// supports under the `transactions` product, not just American Express. This is the ONLY Plaid
// credential-bearing call the app triggers directly for a NEW connection (all others happen after
// Link succeeds); for an EXISTING connection needing re-auth, see the update-mode branch below.
//
// PLAID_CLIENT_ID / PLAID_SECRET are read from environment variables (see ../_shared/plaid.ts)
// and never appear in this file or in the response sent back to the app.
//
// AUTH: `verify_jwt = false` at the gateway (required by the new sb_publishable_/sb_secret_ key
// system — see ../_shared/plaid.ts's file header). The caller MUST send
// `Authorization: Bearer <user access token>`; requireAuthenticatedUserId validates it in code.

import {
  assertItemEnvironmentMatches,
  buildLinkTokenCreatedLogFields,
  buildPlaidWebhookUrl,
  buildUpdateModeLinkTokenParams,
  createPrivilegedClient,
  EnvironmentMismatchError,
  isValidUuid,
  jsonResponse,
  loadPlaidCredentials,
  logPlaidOperation,
  logSafeError,
  PLAID_OAUTH_REDIRECT_URI,
  plaidFetch,
  requireAuthenticatedUserId,
  SafeError,
  UnauthorizedError,
} from "../_shared/plaid.ts";

// Plaid's own hard ceiling for `transactions.days_requested` is entitlement-dependent (typically
// up to 730 with extended transaction history access, otherwise Plaid itself rejects a request
// above what the account is entitled to) — this project doesn't need to know the exact number,
// only a sane upper bound so a caller can't request something absurd like days_requested: -1 or
// 100000. Plaid returns its own error if the account isn't entitled to whatever is requested
// here; that error is surfaced to the caller as-is via the existing catch block below.
const MAX_DAYS_REQUESTED = 730;
const MIN_DAYS_REQUESTED = 1;

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("create-link-token auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const { connection_id, days_requested } = await req.json().catch(() => ({}));

  try {
    // UPDATE MODE: reconnecting an existing institution (e.g. after ITEM_LOGIN_REQUIRED) without
    // deleting and recreating the Item — Plaid's Link flow supports this by passing the Item's
    // OWN access_token instead of `products`/a fresh `user`. The resulting link_token opens Link
    // in a mode that only asks the user to re-authenticate; it does NOT invalidate the existing
    // access_token, plaid_items row, or any already-synced transactions/accounts.
    if (connection_id !== undefined) {
      if (!isValidUuid(connection_id)) {
        return jsonResponse({ error: "connection_id, if provided, must be a valid UUID" }, 400);
      }
      const { data: item, error: lookupError } = await supabase
        .from("plaid_items")
        .select("access_token, environment")
        .eq("id", connection_id)
        .eq("user_id", userId)
        .maybeSingle();
      if (lookupError) throw lookupError;
      if (!item) {
        return jsonResponse({ error: "No such connection for this account" }, 404);
      }
      // Must be checked BEFORE calling Plaid — this Item's access_token is only valid against
      // the host it was originally issued under (see assertItemEnvironmentMatches's doc comment).
      assertItemEnvironmentMatches(item.environment);

      // See buildUpdateModeLinkTokenParams's own doc comment for exactly what this sends,
      // including `update.account_selection_enabled` (Plaid's update-mode account-selection
      // surface — lets the user pick up newly available accounts during this Link session).
      const data = await plaidFetch(
        "/link/token/create",
        buildUpdateModeLinkTokenParams(userId, item.access_token) as unknown as Record<string, unknown>,
      );
      console.log("[create-link-token] link token created:", buildLinkTokenCreatedLogFields(true, item.environment, true, true));
      logPlaidOperation({
        operation: "create-link-token",
        outcome: "success",
        environment: item.environment ?? undefined,
        connectionId: connection_id,
        requestId: typeof data.request_id === "string" ? data.request_id : undefined,
        mode: "update_mode",
      });
      return jsonResponse({ link_token: data.link_token, expiration: data.expiration });
    }

    // NEW CONNECTION.
    const linkTokenParams: Record<string, unknown> = {
      client_name: "SpendSmart",
      language: "en",
      country_codes: ["US"],
      // Plaid's own per-end-user correlation id — the real authenticated household account id,
      // not a fixed placeholder.
      user: { client_user_id: userId },
      products: ["transactions"],
      // Deliberately institution-agnostic — Plaid's Link UI itself is where the user picks their
      // institution (American Express or otherwise); nothing here scopes it to one.
      webhook: buildPlaidWebhookUrl(),
      // Required for native-iOS OAuth/App-to-App institutions — see PLAID_OAUTH_REDIRECT_URI's
      // doc comment. Fixed, trusted, never client-supplied.
      redirect_uri: PLAID_OAUTH_REDIRECT_URI,
    };

    if (days_requested !== undefined) {
      if (
        typeof days_requested !== "number" ||
        !Number.isInteger(days_requested) ||
        days_requested < MIN_DAYS_REQUESTED ||
        days_requested > MAX_DAYS_REQUESTED
      ) {
        return jsonResponse(
          { error: `days_requested must be an integer between ${MIN_DAYS_REQUESTED} and ${MAX_DAYS_REQUESTED}` },
          400,
        );
      }
      linkTokenParams.transactions = { days_requested };
    }

    const data = await plaidFetch("/link/token/create", linkTokenParams);
    console.log(
      "[create-link-token] link token created:",
      buildLinkTokenCreatedLogFields(false, loadPlaidCredentials().environment, true, true),
    );
    logPlaidOperation({
      operation: "create-link-token",
      outcome: "success",
      environment: loadPlaidCredentials().environment,
      requestId: typeof data.request_id === "string" ? data.request_id : undefined,
      mode: "new_connection",
    });

    // Only the link_token crosses back to the client — nothing else from this response.
    return jsonResponse({ link_token: data.link_token, expiration: data.expiration });
  } catch (error) {
    logSafeError(
      `create-link-token failed${connection_id !== undefined ? ` connection_id=${connection_id}` : ""}`,
      error,
    );
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof EnvironmentMismatchError) {
      return jsonResponse({ error: error.message, environment_mismatch: true }, 409);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to create link token" }, 500);
  }
});
