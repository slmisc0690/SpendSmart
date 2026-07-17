// Supabase Edge Function: disconnect-account
//
// Called by the iOS app's "Disconnect" action for a linked institution (renamed from
// disconnect-amex now that a household account can link more than one institution — see the
// migration plan). Asks Plaid to invalidate the access_token (/item/remove) and deletes the
// stored row. After this call, the access_token no longer works even if it had leaked — so this
// is the real safety net, not just a UI toggle.
//
// Requires the caller to name EXACTLY which plaid_items row to disconnect via `connection_id`
// (the opaque row id exchange-public-token returns on success). `user_id` alone is not
// guaranteed unique — nothing stops a second exchange-public-token call from creating a second
// row for the same user_id — so a bare "the one row for this user" lookup is ambiguous the
// moment more than one exists. Picking arbitrarily among them (e.g. via `.limit(1)` with no
// ordering) risks calling Plaid's /item/remove on, and deleting, a DIFFERENT connection than the
// one the user asked to disconnect. Requiring an explicit, caller-supplied identifier removes
// that ambiguity entirely.
//
// AUTH: `verify_jwt = false` at the gateway (required by the new sb_publishable_/sb_secret_ key
// system — see ../_shared/plaid.ts's file header). The caller MUST send
// `Authorization: Bearer <user access token>`; requireAuthenticatedUserId validates it in code
// and derives user_id ONLY from that verified token — never from the request body.

import {
  assertItemEnvironmentMatches,
  createPrivilegedClient,
  EnvironmentMismatchError,
  isValidUuid,
  jsonResponse,
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

  console.log("[disconnect-account] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("disconnect-account auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const { connection_id } = await req.json().catch(() => ({}));
  if (!isValidUuid(connection_id)) {
    return jsonResponse({ error: "connection_id (a valid UUID) is required" }, 400);
  }

  try {
    // Scoped by the specific row id AND user_id — never a bare "first row for this user" lookup.
    const { data: item, error: lookupError } = await supabase
      .from("plaid_items")
      .select("id, access_token, environment")
      .eq("id", connection_id)
      .eq("user_id", userId)
      .maybeSingle();

    if (lookupError) throw lookupError;
    if (!item) {
      // Already disconnected, or connection_id belongs to a different user — either way, treat as
      // success rather than an error (this must never delete something ELSE on a mismatch).
      console.log("[disconnect-account] no matching plaid_items row (already disconnected?):", { connection_id });
      return jsonResponse({ disconnected: true });
    }
    // Must be checked BEFORE calling Plaid — see assertItemEnvironmentMatches's doc comment. On a
    // mismatch, this row is intentionally left untouched here (neither revoked at Plaid nor
    // deleted) rather than partially cleaning it up — dedicated Sandbox-data cleanup is a
    // separate, deliberate action, not a side effect of a routine disconnect request.
    assertItemEnvironmentMatches(item.environment);

    const removeResult = await plaidFetch("/item/remove", { access_token: item.access_token });

    const { error: deleteError } = await supabase
      .from("plaid_items")
      .delete()
      .eq("id", item.id)
      .eq("user_id", userId);
    if (deleteError) throw deleteError;

    console.log("[disconnect-account] plaid_items row deleted:", true);
    logPlaidOperation({
      operation: "disconnect-account",
      outcome: "success",
      environment: item.environment ?? undefined,
      connectionId: item.id,
      requestId: typeof removeResult.request_id === "string" ? removeResult.request_id : undefined,
    });

    return jsonResponse({ disconnected: true });
  } catch (error) {
    logSafeError(`disconnect-account failed connection_id=${connection_id}`, error);

    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof EnvironmentMismatchError) {
      return jsonResponse({ error: error.message, environment_mismatch: true }, 409);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to disconnect account" }, 500);
  }
});
