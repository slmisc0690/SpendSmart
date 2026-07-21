// Supabase Edge Function: sync-manual-data
//
// PHASE 5 — MANUAL ACCOUNT / MANUAL TRANSACTION CLOUD SYNC FOUNDATION. Authored as backend
// foundation work; NOT deployed, NOT wired into any iOS UI change beyond the sync client itself
// (see this phase's own scope — Account Related Options UI / Secondary shared-data UI are
// explicitly out of scope). One compact function handling every OWNER write operation (create,
// update, delete — for both Manual Accounts and Manual Transactions) in a single authenticated
// batch call, rather than a function per operation — per this phase's own instruction to inspect
// whether one function can safely cover multiple operations before creating several.
//
// TRUST BOUNDARY: iOS -> this function -> requireAuthenticatedUserId() -> server-verified caller
// identity -> upsert/delete against public.manual_accounts/public.manual_transactions, via this
// function's own privileged (service_role) client. The request body carries NO owner_user_id field
// anywhere, for either accounts or transactions — every row's owner_user_id is set here, from the
// verified caller identity only, exactly mirroring get-connected-account-transactions'/
// sync-transactions' own established anti-spoofing posture (migration 0010). A client cannot
// influence whose data a write is attributed to, no matter what it sends.
//
// OWNERSHIP VERIFICATION FOR TRANSACTIONS: a transaction's `manual_account_id` must resolve to an
// account THIS caller owns — checked here via a database lookup (which manual_accounts rows this
// caller owns), never trusted from the payload. A transaction naming an account id the caller
// doesn't own is skipped (reported back, never silently upserted or reassigned) — this is what
// keeps "Transaction cannot be linked to another user's account" true even before
// enforce_manual_transaction_owner_matches_account (the database-level backstop, migration 0011)
// ever gets a chance to fire.
//
// IDEMPOTENCY: every upsert targets `id` (the client-supplied UUID matching the local SwiftData
// row's own `id`) as the conflict key — replaying the exact same sync (e.g. after a network retry)
// updates the same row in place, never duplicates it.
//
// DELETES: scoped by `id = ANY(...) AND owner_user_id = <verified caller>` for both accounts and
// transactions — never a bare id match — so a caller can never delete a row they don't own even if
// an id from another user's data somehow appeared in their delete list. Deleting a
// `manual_accounts` row cascades its own `manual_transactions` rows automatically (the table's own
// `ON DELETE CASCADE`, migration 0011) — no separate per-transaction delete is needed or attempted
// for transactions removed only because their owning account was deleted.
//
// FAILURE ISOLATION: this function's entire job is server-side sync bookkeeping — a failure here
// must never be capable of touching, let alone corrupting or deleting, the caller's local SwiftData
// store, which remains authoritative for that owner's own UI in this phase (see this phase's own
// requirement #9). This function performs no local-data-affecting response at all; it only
// acknowledges what was/wasn't synced.
//
// AUTH: verify_jwt = false at the gateway (same reason as every other user-invoked function in
// this project — see ../_shared/plaid.ts's file header) — this function performs its own auth
// check in code via requireAuthenticatedUserId, never trusting the gateway to have done it.

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
import {
  planManualAccountSync,
  planManualTransactionSync,
  type RawManualAccountInput,
  type RawManualTransactionInput,
} from "../_shared/manual.ts";

function asArray<T>(value: unknown): T[] {
  return Array.isArray(value) ? (value as T[]) : [];
}

function asIdArray(value: unknown): string[] {
  return asArray<unknown>(value).filter((v): v is string => isValidUuid(v));
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[sync-manual-data] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("sync-manual-data auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const body = await req.json().catch(() => ({}));
  const accountInputs = asArray<RawManualAccountInput>(body.accounts);
  const transactionInputs = asArray<RawManualTransactionInput>(body.transactions);
  const deletedAccountIds = asIdArray(body.deleted_account_ids);
  const deletedTransactionIds = asIdArray(body.deleted_transaction_ids);

  try {
    // 1. Upsert accounts FIRST — any transaction in this same batch referencing a brand-new
    // account needs that account row to already exist before the ownership-ordering check below
    // and the database's own FK/trigger validate it.
    //
    // OWNERSHIP-HIJACK GUARD: an `id` in the payload might already exist as a DIFFERENT user's
    // row (a client bug, or a malicious caller replaying/guessing another user's account id) — a
    // bare `upsert(..., { onConflict: "id" })` would silently UPDATE that existing row in place,
    // including reassigning its `owner_user_id` to this caller, since `buildManualAccountRow`
    // always stamps the row with the CALLER's own verified identity. This is checked BEFORE the
    // upsert runs (never after) by reading which of the requested ids already exist and who
    // currently owns them: only genuinely-new ids or ids this caller ALREADY owns are upserted;
    // any id already owned by someone else is skipped and reported, exactly like the analogous
    // ownership check already applied to transactions below (step 3) — this closes the one gap
    // that check didn't cover, since it only ever validated a transaction's PARENT account, never
    // an account row's own conflicting identity.
    const accountPlan = planManualAccountSync(accountInputs, userId, isValidUuid);
    const requestedAccountIds = accountPlan.rows.map((row) => row.id);
    let accountRowsToUpsert = accountPlan.rows;
    let skippedForeignAccountIdConflicts: string[] = [];
    if (requestedAccountIds.length > 0) {
      const { data: existingAccountRows, error: existingAccountsError } = await supabase
        .from("manual_accounts")
        .select("id, owner_user_id")
        .in("id", requestedAccountIds);
      if (existingAccountsError) throw existingAccountsError;

      const foreignOwnedIds = new Set(
        (existingAccountRows ?? [])
          .filter((row) => row.owner_user_id !== userId)
          .map((row) => row.id as string),
      );
      if (foreignOwnedIds.size > 0) {
        accountRowsToUpsert = accountPlan.rows.filter((row) => !foreignOwnedIds.has(row.id));
        skippedForeignAccountIdConflicts = accountPlan.rows
          .filter((row) => foreignOwnedIds.has(row.id))
          .map((row) => row.id);
      }
    }

    if (accountRowsToUpsert.length > 0) {
      const { error: accountUpsertError } = await supabase
        .from("manual_accounts")
        .upsert(accountRowsToUpsert, { onConflict: "id" });
      if (accountUpsertError) throw accountUpsertError;
    }

    // 2. Resolve exactly which manual_accounts ids this caller owns — the authoritative source
    // for step 3's ownership check, re-read fresh (not merely "the ids just upserted above") so a
    // transaction can validly reference an account synced in an EARLIER call, not just this one.
    const { data: ownedAccountRows, error: ownedAccountsError } = await supabase
      .from("manual_accounts")
      .select("id")
      .eq("owner_user_id", userId);
    if (ownedAccountsError) throw ownedAccountsError;
    const ownedAccountIds = new Set((ownedAccountRows ?? []).map((row) => row.id as string));

    // 3. Validate transactions structurally, THEN filter to only those whose manual_account_id is
    // actually owned by this caller — never upsert (or attempt to reassign) a transaction pointing
    // at someone else's account.
    const transactionPlan = planManualTransactionSync(transactionInputs, userId, isValidUuid);
    const ownedTransactionRows = transactionPlan.rows.filter((row) => ownedAccountIds.has(row.manual_account_id));
    const skippedForeignAccountIds = transactionPlan.rows
      .filter((row) => !ownedAccountIds.has(row.manual_account_id))
      .map((row) => row.id);

    if (ownedTransactionRows.length > 0) {
      const { error: transactionUpsertError } = await supabase
        .from("manual_transactions")
        .upsert(ownedTransactionRows, { onConflict: "id" });
      if (transactionUpsertError) throw transactionUpsertError;
    }

    // 4. Deletes — transactions before accounts (accounts cascade their own transactions
    // automatically; processing this order first means an account-delete's cascade never races
    // against this function's own separate transaction-delete for the same rows in any observable
    // way, though both orders are actually safe given the cascade). Each delete `.select("id")`s
    // the rows it actually removed — not merely a count — so the client can clear exactly the
    // matching local tombstones (`PendingCloudDeletion` rows) it has confirmation for, never more.
    let deletedTransactionIdsResult: string[] = [];
    if (deletedTransactionIds.length > 0) {
      const { data: deletedTransactionRows, error: deleteTransactionsError } = await supabase
        .from("manual_transactions")
        .delete()
        .in("id", deletedTransactionIds)
        .eq("owner_user_id", userId)
        .select("id");
      if (deleteTransactionsError) throw deleteTransactionsError;
      deletedTransactionIdsResult = (deletedTransactionRows ?? []).map((row) => row.id as string);
    }

    let deletedAccountIdsResult: string[] = [];
    if (deletedAccountIds.length > 0) {
      const { data: deletedAccountRows, error: deleteAccountsError } = await supabase
        .from("manual_accounts")
        .delete()
        .in("id", deletedAccountIds)
        .eq("owner_user_id", userId)
        .select("id");
      if (deleteAccountsError) throw deleteAccountsError;
      deletedAccountIdsResult = (deletedAccountRows ?? []).map((row) => row.id as string);
    }

    logPlaidOperation({
      operation: "sync-manual-data",
      outcome: "success",
      accountCount: accountRowsToUpsert.length,
      addedCount: ownedTransactionRows.length,
    });

    return jsonResponse({
      synced_account_ids: accountRowsToUpsert.map((r) => r.id),
      synced_transaction_ids: ownedTransactionRows.map((r) => r.id),
      deleted_account_ids: deletedAccountIdsResult,
      deleted_transaction_ids: deletedTransactionIdsResult,
      rejected_accounts: accountPlan.rejected,
      rejected_transactions: transactionPlan.rejected,
      skipped_foreign_account_transaction_ids: skippedForeignAccountIds,
      skipped_foreign_account_id_conflicts: skippedForeignAccountIdConflicts,
    });
  } catch (error) {
    logSafeError("sync-manual-data failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to sync manual data" }, 500);
  }
});
