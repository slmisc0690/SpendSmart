// Supabase Edge Function: get-my-manual-accounts
//
// LOCAL DATA RESTORE (owner-only) — lets a device with an empty local store (fresh install, new
// device) recover the caller's own Manual Accounts + Transactions from Supabase. Structurally
// identical to get-manual-account-data (migration 0011/Phase 5) — see that function's own header
// for the fully-argued trust-boundary rationale — with ONE difference: there is no sharing logic
// here at all. `owner_user_id` is never accepted as a request field; the only identity involved is
// the caller's own JWT-derived id, and `get_my_manual_accounts_with_transactions` (migration 0021)
// only ever returns rows where `owner_user_id` matches that caller — structurally impossible to use
// this endpoint to read anyone else's data.
//
// READ-ONLY: this function performs no write of any kind.
//
// Request body: {} (no fields required — identity comes entirely from the caller's own JWT).

import {
  createPrivilegedClient,
  jsonResponse,
  logPlaidOperation,
  logSafeError,
  requireAuthenticatedUserId,
  SafeError,
  UnauthorizedError,
} from "../_shared/plaid.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[get-my-manual-accounts] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("get-my-manual-accounts auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  try {
    const { data, error } = await supabase.rpc("get_my_manual_accounts_with_transactions", {
      p_caller_user_id: userId,
    });
    if (error) throw error;

    const rows = (data as Record<string, unknown>[] | null) ?? [];

    logPlaidOperation({
      operation: "get-my-manual-accounts",
      outcome: "success",
      accountCount: rows.length,
    });

    // Money-valued fields as STRINGS, not JSON numbers — same reasoning as every other money
    // field this project sends to iOS (see get-manual-account-data's own identical note).
    return jsonResponse({
      accounts: rows.map((row) => {
        const transactions = (row.transactions as Record<string, unknown>[] | null) ?? [];
        return {
          id: row.id,
          name: row.name,
          account_type: row.account_type,
          current_balance: row.current_balance != null ? String(row.current_balance) : null,
          institution_name: row.institution_name,
          last_four_digits: row.last_four_digits,
          shows_in_recent_activity: row.shows_in_recent_activity,
          updated_at: row.updated_at,
          transactions: transactions.map((t) => ({
            id: t.id,
            amount: t.amount != null ? String(t.amount) : null,
            transaction_type: t.transaction_type,
            transaction_date: t.transaction_date,
            note: t.note,
            category_name: t.category_name,
            is_pending: t.is_pending,
            updated_at: t.updated_at,
          })),
        };
      }),
    });
  } catch (error) {
    logSafeError("get-my-manual-accounts failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to retrieve manual accounts" }, 500);
  }
});
