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
//   - if the caller is the active Secondary (PHASE 8D), a narrow subset scoped to exactly that
//     phase's own locked "Share Connected Account" + "Share Manual Account" requirement: the
//     caller's OWN Connected Accounts AND OWN Manual Accounts lists, plus their OWN
//     connectedAccounts/manualAccounts-category sharing_permissions rows — never household
//     administration data or invitation data. Critically: `manual_accounts` is filtered
//     by `owner_user_id = caller` only — a Manual Account the Primary owns and has shared WITH
//     this Secondary is never returned in THIS field, so it can never appear as eligible to
//     re-share and can never be re-shared back to its actual owner.
//   - PHASE 9 BACKEND PREREQUISITE — a Secondary response additionally carries `primary_user_id`,
//     `primary_shared_connected_accounts`, `primary_shared_manual_accounts`,
//     `primary_monthly_plan_shared`, and (PHASE A) `primary_monthly_savings_shared`, sourced from
//     migration 0016/0018's get_secondary_shared_data — the
//     missing discovery step for what the Primary shares WITH this Secondary (as opposed to the
//     share-back fields above, which are what this Secondary shares back TO the Primary). Never
//     transactions or plan values themselves — only the minimal identity/display metadata a
//     client needs to then call the two remaining, unmodified per-item read endpoints
//     (get-connected-account-transactions/get-manual-account-data) and get-monthly-plan-data.
//     PHASE B PARITY FIX, STEP 1 (migration 0017) — `primary_shared_connected_accounts` items now
//     additionally carry `current_balance`/`available_balance`/`credit_limit`/`type`/
//     `updated_at`, so a Secondary's Dashboard card can show the same informational balance
//     state the Primary's own equivalent card shows. This function's own code is unchanged by
//     that migration — `sharedData.connected_accounts` is passed through as-is, see below.
//
// SECRETS: never touches plaid_items.access_token or any Plaid credential — only
// plaid_accounts.id/name/mask/type/current_balance/available_balance/credit_limit/updated_at (all
// non-sensitive display fields; the balance columns are the same ones the Primary's own
// list-connections/sync-balances path already exposes to its owner) are read, scoped to
// plaid_items.user_id = caller (own accounts) or filtered through
// is_effectively_shared_for_user (Primary-shared accounts, via get_secondary_shared_data).
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

    if (state.role === "secondary") {
      // PHASE 8D — narrow Secondary-only subset: the caller's own Connected Accounts AND own
      // Manual Accounts, plus their own connectedAccounts/manualAccounts-category
      // sharing_permissions rows (share-back), nothing else from household administration or
      // invitation detail.
      //
      // PHASE 9 BACKEND PREREQUISITE — additionally calls migration 0016's
      // get_secondary_shared_data, the missing discovery step for what the Primary shares WITH
      // this Secondary (as opposed to the share-back data above, which is what this Secondary
      // shares back). Permission is not duplicated here — that RPC internally re-verifies every
      // item against the same canonical is_effectively_shared_for_user evaluator every other
      // sharing decision in this project already uses. This function still returns no
      // transactions/balances/plan values itself — only the identity/display metadata a client
      // needs to then call get-connected-account-transactions/get-manual-account-data/
      // get-monthly-plan-data, none of which are changed by this edit.
      const [connectedAccountsResult, manualAccountsResult, sharingPermissionsResult, sharedDataResult] = await Promise.all([
        supabase
          .from("plaid_accounts")
          .select("id, account_id, name, mask, plaid_item_id, plaid_items!inner(user_id)")
          .eq("plaid_items.user_id", userId),
        supabase
          .from("manual_accounts")
          .select("id, name, account_type")
          .eq("owner_user_id", userId),
        supabase
          .from("sharing_permissions")
          .select("category, item_id, is_shared")
          .eq("household_id", state.household_id as string)
          .eq("owner_user_id", userId)
          .in("category", ["connectedAccounts", "manualAccounts"]),
        supabase.rpc("get_secondary_shared_data", { p_requesting_user_id: userId }),
      ]);
      if (connectedAccountsResult.error) throw connectedAccountsResult.error;
      if (manualAccountsResult.error) throw manualAccountsResult.error;
      if (sharingPermissionsResult.error) throw sharingPermissionsResult.error;
      if (sharedDataResult.error) throw sharedDataResult.error;

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

      const sharedData = (sharedDataResult.data as Record<string, unknown>) ?? {
        is_active_secondary: false,
        primary_user_id: null,
        connected_accounts: [],
        manual_accounts: [],
        monthly_plan_shared: false,
        monthly_savings_shared: false, // PHASE A
        saved_via_transfer_shared: false, // SAVED VIA TRANSFER SHARING
      };

      logPlaidOperation({
        operation: "get-account-related-options",
        outcome: "secondary",
        accountCount: connectedAccounts.length + manualAccounts.length,
      });

      return jsonResponse({
        household_id: state.household_id,
        role: state.role,
        status: state.status,
        secondary_member: null,
        pending_invitation: null,
        sharing_permissions: sharingPermissionsResult.data ?? [],
        connected_accounts: connectedAccounts,
        manual_accounts: manualAccounts,
        // PHASE 9 BACKEND PREREQUISITE — Primary-shared discovery (see this branch's own header).
        primary_user_id: sharedData.primary_user_id ?? null,
        primary_shared_connected_accounts: sharedData.connected_accounts ?? [],
        primary_shared_manual_accounts: sharedData.manual_accounts ?? [],
        primary_monthly_plan_shared: sharedData.monthly_plan_shared ?? false,
        // PHASE A — independent of primary_monthly_plan_shared above; see
        // get_secondary_shared_data's own header for why these are never derived from each other.
        primary_monthly_savings_shared: sharedData.monthly_savings_shared ?? false,
        // SAVED VIA TRANSFER SHARING — independent of primary_monthly_plan_shared and
        // primary_monthly_savings_shared above; see get_secondary_shared_data's own header for why
        // these are never derived from each other.
        primary_saved_via_transfer_shared: sharedData.saved_via_transfer_shared ?? false,
      });
    }

    if (state.role !== "primary") {
      // No-household callers get only their own role/status — no sharing detail, no account
      // lists. See migration 0013's get_household_state for why this is deliberate.
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
