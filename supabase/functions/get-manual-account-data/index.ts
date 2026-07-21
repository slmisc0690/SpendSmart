// Supabase Edge Function: get-manual-account-data
//
// PHASE 5 — MANUAL ACCOUNT / MANUAL TRANSACTION CLOUD SYNC FOUNDATION. Authored as backend
// foundation work; NOT deployed, NOT wired into any iOS UI (Secondary shared-data UI is explicitly
// out of scope this phase). Structurally identical to get-connected-account-transactions
// (migration 0010/Phase 4) — see that function's own header for the fully-argued trust-boundary/
// anti-enumeration rationale, repeated only in summary here to avoid duplication:
//
// - Caller identity comes ONLY from requireAuthenticatedUserId() — the request body has no
//   recipient/owner identity field at all.
// - Authorization is entirely delegated to public.get_manual_account_with_transactions (migration
//   0011), which itself delegates the actual Secondary-permission decision to the canonical
//   is_effectively_shared_for_user evaluator (migration 0008) — no permission logic is duplicated
//   here, in SQL, or anywhere else.
// - Anti-enumeration: unknown, unrelated, and shared-but-off accounts all produce the identical
//   response — an account of `null` — never a distinguishing 403/404.
// - READ-ONLY: this function performs no write of any kind.
//
// Request body: { manual_account_id: string (a UUID — public.manual_accounts.id, matching this
// project's locked sharing-key semantics for the 'manualAccounts' category, migration 0008's own
// comment), limit?: number }.

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

  console.log("[get-manual-account-data] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("get-manual-account-data auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const { manual_account_id, limit } = await req.json().catch(() => ({}));
  if (!isValidUuid(manual_account_id)) {
    return jsonResponse({ error: "manual_account_id (a valid UUID) is required" }, 400);
  }
  const requestedLimit = typeof limit === "number" && Number.isFinite(limit) ? Math.trunc(limit) : DEFAULT_LIMIT;
  const clampedLimit = Math.min(Math.max(requestedLimit, 1), MAX_LIMIT);

  try {
    const { data, error } = await supabase.rpc("get_manual_account_with_transactions", {
      p_caller_user_id: userId,
      p_manual_account_id: manual_account_id,
      p_limit: clampedLimit,
    });
    if (error) throw error;

    const row = (data as Record<string, unknown>[] | null)?.[0] ?? null;

    logPlaidOperation({
      operation: "get-manual-account-data",
      outcome: "success",
      accountCount: row ? 1 : 0,
    });

    if (!row) {
      // Never distinguishes "doesn't exist" from "exists but not shared with you" — see this
      // file's header.
      return jsonResponse({ account: null });
    }

    // Passed through from the SQL function's own narrow, non-sensitive RETURNS TABLE shape —
    // never owner_user_id. `current_balance`/transaction `amount` as STRINGS, not JSON numbers —
    // same reasoning as every other money field this project sends to iOS (a JSON number
    // round-trips through Double before an iOS JSONDecoder ever sees it, which can silently
    // corrupt exact cent values).
    const transactions = (row.transactions as Record<string, unknown>[] | null) ?? [];
    return jsonResponse({
      account: {
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
      },
    });
  } catch (error) {
    logSafeError("get-manual-account-data failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to retrieve manual account data" }, 500);
  }
});
