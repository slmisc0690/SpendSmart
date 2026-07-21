// Supabase Edge Function: get-account-related-options
//
// PHASE 7 — ACCOUNT RELATED OPTIONS / PRIMARY SHARING CONTROLS. Authored as backend foundation
// work; NOT deployed in this task.
//
// The single consolidated read endpoint for the "Account Related Options" screen — deliberately
// one function rather than one-per-section, per this phase's own "avoid excessive function
// sprawl" instruction. Returns:
//   - household_id / role / status for the CALLER (server-verified identity only)
//   - if the caller is the active Primary, additionally: secondary_member, pending_invitation,
//     sharing_permissions (all from migration 0013's get_household_state), PLUS the caller's own
//     Connected Accounts and Manual Accounts lists so the client can render per-item sharing rows.
//
// SECRETS: never touches plaid_items.access_token or any Plaid credential — only
// plaid_accounts.id/name/mask/type (the same non-sensitive fields list-connections/
// sync-balances already expose) are read, scoped to plaid_items.user_id = caller.
//
// item_id EXPOSURE (Phase 9's own requirement): the iOS client has no other way to learn its own
// public.plaid_accounts.id — this is the one safe place it is surfaced, alongside Plaid's own
// account_id string (for display-list correlation with what ConnectedAccountsView already shows),
// never instead of it.
//
// Request body: {} — no fields; the caller's own identity is the only input.

import {
  createPrivilegedClient,
  jsonResponse,
  logPlaidOperation,
  logSafeError,
  requireAuthenticatedUserId,
  UnauthorizedError,
} from "../_shared/plaid.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[get-account-related-options] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("get-account-related-options auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  try {
    const { data: stateData, error: stateError } = await supabase.rpc("get_household_state", {
      p_requesting_user_id: userId,
    });
    if (stateError) throw stateError;

    const state = (stateData as Record<string, unknown>) ?? { household_id: null, role: null, status: null };

    if (state.role !== "primary") {
      // Secondary / no-household callers get only their own role/status — no sharing detail, no
      // account lists. See migration 0013's get_household_state for why this is deliberate.
      logPlaidOperation({ operation: "get-account-related-options", outcome: "non_primary" });
      return jsonResponse({
        household_id: state.household_id ?? null,
        role: state.role ?? null,
        status: state.status ?? null,
        secondary_member: null,
        pending_invitation: null,
        sharing_permissions: [],
        connected_accounts: [],
        manual_accounts: [],
      });
    }

    const [connectedAccountsResult, manualAccountsResult] = await Promise.all([
      supabase
        .from("plaid_accounts")
        .select("id, account_id, name, mask, plaid_item_id, plaid_items!inner(user_id)")
        .eq("plaid_items.user_id", userId),
      supabase
        .from("manual_accounts")
        .select("id, name, account_type")
        .eq("owner_user_id", userId),
    ]);
    if (connectedAccountsResult.error) throw connectedAccountsResult.error;
    if (manualAccountsResult.error) throw manualAccountsResult.error;

    const connectedAccounts = (connectedAccountsResult.data ?? []).map((row: Record<string, unknown>) => ({
      plaid_account_id: row.id,
      account_id: row.account_id,
      name: row.name,
      mask: row.mask,
    }));

    const manualAccounts = (manualAccountsResult.data ?? []).map((row: Record<string, unknown>) => ({
      id: row.id,
      name: row.name,
      account_type: row.account_type,
    }));

    logPlaidOperation({
      operation: "get-account-related-options",
      outcome: "success",
      accountCount: connectedAccounts.length + manualAccounts.length,
    });

    return jsonResponse({
      household_id: state.household_id,
      role: state.role,
      status: state.status,
      secondary_member: state.secondary_member ?? null,
      pending_invitation: state.pending_invitation ?? null,
      sharing_permissions: state.sharing_permissions ?? [],
      connected_accounts: connectedAccounts,
      manual_accounts: manualAccounts,
    });
  } catch (error) {
    logSafeError("get-account-related-options failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    return jsonResponse({ error: "Failed to retrieve account related options" }, 500);
  }
});
