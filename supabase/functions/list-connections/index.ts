// Supabase Edge Function: list-connections
//
// Called by the iOS app to learn the authoritative, server-side state of every institution this
// user has linked — including flags a webhook set that the device could never have known about
// on its own (requires_reauth from ITEM_LOGIN_REQUIRED, pending_expiration_at from
// PENDING_EXPIRATION, new_accounts_available from NEW_ACCOUNTS_AVAILABLE — see plaid-webhook).
// Without this function, PlaidConnectionManager's on-device cache would only ever reflect what
// THIS device did (connect/disconnect), never what Plaid told the backend asynchronously.
//
// Returns only non-sensitive identifiers and state flags — never access_token, never item_id
// (Plaid's own id is never returned to the client; connection_id, the plaid_items row's own
// opaque UUID, is the only identifier the app ever holds, consistent with every other function
// here).

import {
  createPrivilegedClient,
  jsonResponse,
  logSafeError,
  requireAuthenticatedUserId,
  UnauthorizedError,
} from "../_shared/plaid.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("list-connections auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  try {
    const { data: items, error } = await supabase
      .from("plaid_items")
      .select("id, institution_id, institution_name, requires_reauth, pending_expiration_at, new_accounts_available, updated_at")
      .eq("user_id", userId)
      .order("created_at", { ascending: true });
    if (error) throw error;

    return jsonResponse({
      connections: (items ?? []).map((item) => ({
        connection_id: item.id,
        institution_id: item.institution_id,
        institution_name: item.institution_name,
        requires_reauth: item.requires_reauth,
        pending_expiration_at: item.pending_expiration_at,
        new_accounts_available: item.new_accounts_available,
        updated_at: item.updated_at,
      })),
    });
  } catch (error) {
    logSafeError("list-connections failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    return jsonResponse({ error: "Failed to list connections" }, 500);
  }
});
