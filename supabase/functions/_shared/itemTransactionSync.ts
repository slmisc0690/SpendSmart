// PLAID WEBHOOK-DRIVEN BACKGROUND TRANSACTION SYNC — PHASE 3: ITEM-LEVEL /transactions/sync ENGINE.
//
// The one place that calls Plaid's /transactions/sync on behalf of a webhook delivery or an
// explicit "force a real sync now" request (see sync-item-transactions/index.ts and
// plaid-webhook/index.ts, the two callers). Item-scoped, never account-scoped — a single call here
// reconciles every account under one Plaid Item in one pagination loop, exactly matching Plaid's own
// account_id-agnostic /transactions/sync response shape (see this project's own Phase 0 audit
// confirming /transactions/sync returns transactions for every account under an Item, not one).
//
// CURSOR OWNERSHIP: as of this phase, this function is the SOLE caller of /transactions/sync for
// any Item in this project — sync-transactions/index.ts (what the iPhone itself calls) no longer
// calls Plaid at all; it reads the already-reconciled plaid_transactions/plaid_transaction_removals
// rows this function writes (see that file's own updated header for the full explanation of why a
// single stateful per-Item cursor cannot safely have two independent callers).
//
// CONCURRENCY: claim_item_transaction_sync/release_item_transaction_sync (migration
// 0028_plaid_item_transaction_sync_foundation.sql) serialize concurrent attempts for the SAME Item
// via one atomic UPDATE ... WHERE ... RETURNING, with a 10-minute stale-claim recovery window since
// this project introduces no background job scheduler in this phase (see that migration's own
// header for why 10 minutes is safe). Different Items never contend with each other — each has its
// own row/claim.
//
// FAILURE SAFETY: every page of the pagination loop is buffered in memory; nothing is persisted to
// plaid_transactions/plaid_transaction_removals and the cursor is never advanced unless the ENTIRE
// loop (every page, has_more eventually false) completes without error — identical discipline to
// sync-transactions/index.ts's own pre-existing cursor-commit-only-after-full-success behavior.
import {
  assertItemEnvironmentMatches,
  buildNormalizedTransactionRows,
  logPlaidOperation,
  logSafeError,
  plaidFetch,
  PlaidRequestError,
  SafeError,
} from "./plaid.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

export interface ItemTransactionSyncOutcome {
  /** True when another sync was already claimed/in-flight for this Item — a safe no-op, not a
   * failure. Both a duplicate webhook delivery and a webhook racing a manual "force sync" land
   * here rather than erroring. */
  skipped: boolean;
  /** False only when `skipped` is false AND the attempt itself failed (Plaid error, DB error,
   * requires_reauth, environment mismatch). Never both `skipped: true` and `success: false`. */
  success: boolean;
  addedCount: number;
  modifiedCount: number;
  removedCount: number;
}

const SKIPPED_OUTCOME: ItemTransactionSyncOutcome = {
  skipped: true,
  success: true,
  addedCount: 0,
  modifiedCount: 0,
  removedCount: 0,
};

const FAILED_OUTCOME: ItemTransactionSyncOutcome = {
  skipped: false,
  success: false,
  addedCount: 0,
  modifiedCount: 0,
  removedCount: 0,
};

/**
 * Maps a caught error to a short, pre-sanitized string safe to persist in
 * plaid_items.last_transaction_sync_error — never a raw Plaid response body (PlaidRequestError.body
 * can echo request content) and never a raw Postgres error message/detail (which can embed the
 * offending column value, e.g. access_token, directly in the message — same reasoning as
 * logSafeError's own database-error branch in _shared/plaid.ts). This is a distinct concern from
 * logSafeError (which decides what reaches console output); this one decides what is safe to store
 * as a column value that a service_role Edge Function or future admin UI might display.
 */
export function summarizeSyncErrorForStorage(error: unknown): string {
  if (error instanceof SafeError) return error.message;
  if (error instanceof PlaidRequestError) return `Plaid request failed (status ${error.status})`;
  if (typeof error === "object" && error !== null && "code" in error) return "Database error";
  return "Sync failed";
}

/**
 * Runs one full Item-level /transactions/sync reconciliation for `itemRowId` (a plaid_items.id),
 * claiming exclusive access for the duration, reconciling every account under that Item in a single
 * pagination loop, persisting into plaid_transactions/plaid_transaction_removals, and advancing
 * plaid_items.cursor ONLY on full success. Safe to call concurrently for different Items; safe to
 * call concurrently for the SAME Item (the second caller gets `{skipped: true}` immediately, no
 * Plaid call made). Never throws — every failure path is caught, logged safely, and reflected in
 * the returned outcome so both callers (the webhook's fire-and-forget background task, and the
 * synchronous manual-refresh-triggered Edge Function) can treat it uniformly.
 */
export async function syncItemTransactionsForItem(
  supabase: SupabaseClient,
  itemRowId: string,
): Promise<ItemTransactionSyncOutcome> {
  const { data: claimed, error: claimError } = await supabase.rpc("claim_item_transaction_sync", {
    p_item_id: itemRowId,
  });
  if (claimError) {
    logSafeError(`sync-item-transactions: claim failed item_row_id=${itemRowId}`, claimError);
    return FAILED_OUTCOME;
  }
  if (!claimed) {
    console.log(`[sync-item-transactions] item ${itemRowId} already claimed, skipping`);
    return SKIPPED_OUTCOME;
  }

  try {
    const outcome = await runClaimedItemSync(supabase, itemRowId);
    return outcome;
  } catch (error) {
    logSafeError(`sync-item-transactions failed item_row_id=${itemRowId}`, error);
    const safeMessage = summarizeSyncErrorForStorage(error);
    try {
      const { error: releaseError } = await supabase.rpc("release_item_transaction_sync", {
        p_item_id: itemRowId,
        p_success: false,
        p_new_cursor: null,
        p_error: safeMessage,
      });
      if (releaseError) throw releaseError;
    } catch (releaseFailure) {
      // Never let a release-path failure mask the original error, and never let it stop the claim
      // from eventually being recoverable — worst case here is the claim stays held until the
      // 10-minute staleness window in claim_item_transaction_sync elapses, which can never let two
      // concurrent syncs for this Item both run, only delay the next one.
      logSafeError(`sync-item-transactions: release-on-failure also failed item_row_id=${itemRowId}`, releaseFailure);
    }
    logPlaidOperation({
      operation: "sync-item-transactions",
      outcome: "failure",
      connectionId: itemRowId,
    });
    return FAILED_OUTCOME;
  }
}

/** The actual claimed-work body, split out only so the outer function's try/catch has a single,
 * clearly-scoped block to wrap — never called directly by anything outside this file. */
async function runClaimedItemSync(
  supabase: SupabaseClient,
  itemRowId: string,
): Promise<ItemTransactionSyncOutcome> {
  const { data: item, error: itemError } = await supabase
    .from("plaid_items")
    .select("id, user_id, access_token, cursor, requires_reauth, environment")
    .eq("id", itemRowId)
    .maybeSingle();
  if (itemError) throw itemError;
  if (!item) throw new SafeError("Item no longer exists");
  if (item.requires_reauth) throw new SafeError("Connection requires reauthentication");
  // Must be checked BEFORE calling Plaid — see assertItemEnvironmentMatches's own doc comment.
  assertItemEnvironmentMatches(item.environment);

  const { data: accountRows, error: accountsError } = await supabase
    .from("plaid_accounts")
    .select("id, account_id")
    .eq("plaid_item_id", item.id);
  if (accountsError) throw accountsError;

  const accountIdToPlaidAccountId: Record<string, string> = {};
  const itemAccountInternalIds: string[] = [];
  for (const row of accountRows ?? []) {
    accountIdToPlaidAccountId[row.account_id as string] = row.id as string;
    itemAccountInternalIds.push(row.id as string);
  }

  // Identical pagination discipline to sync-transactions/index.ts's own pre-existing loop: buffer
  // every page in memory, only exit once has_more is false, so a partial failure never leaves
  // anything committed. See this file's own header for the full failure-safety rationale.
  let cursor: string | undefined = item.cursor ?? undefined;
  let hasMore = true;
  let pageCount = 0;
  const added: Record<string, unknown>[] = [];
  const modified: Record<string, unknown>[] = [];
  const removed: Record<string, unknown>[] = [];

  while (hasMore) {
    const data = await plaidFetch("/transactions/sync", { access_token: item.access_token, cursor });
    pageCount += 1;
    added.push(...((data.added as Record<string, unknown>[] | undefined) ?? []));
    modified.push(...((data.modified as Record<string, unknown>[] | undefined) ?? []));
    removed.push(...((data.removed as Record<string, unknown>[] | undefined) ?? []));
    hasMore = data.has_more === true;
    cursor = data.next_cursor as string;
  }
  console.log(`[sync-item-transactions] item ${itemRowId} pages=${pageCount} added=${added.length} modified=${modified.length} removed=${removed.length}`);

  const nowIso = new Date().toISOString();

  // Persist added+modified BEFORE removed — a pending transaction posting is delivered as the OLD
  // pending id in `removed` alongside the NEW posted transaction in `added`/`modified`; the posted
  // row must exist before its sibling removal is processed, matching both sync-transactions' own
  // existing ordering and the iOS local import's documented ordering rationale.
  const { rows: normalizedRows } = buildNormalizedTransactionRows(
    [...added, ...modified],
    accountIdToPlaidAccountId,
    item.user_id,
    nowIso,
  );
  if (normalizedRows.length > 0) {
    const { error: upsertError } = await supabase
      .from("plaid_transactions")
      .upsert(normalizedRows, { onConflict: "plaid_account_id,transaction_id" });
    if (upsertError) throw upsertError;
  }

  const removedTransactionIds = removed
    .map((r) => r.transaction_id)
    .filter((id): id is string => typeof id === "string" && id.length > 0);

  if (removedTransactionIds.length > 0 && itemAccountInternalIds.length > 0) {
    // Resolve which of THIS Item's own accounts each removed transaction_id currently belongs to,
    // scoped to this Item's own plaid_account_id set — never a bare global transaction_id match.
    // plaid_transactions is only ever unique per (plaid_account_id, transaction_id), never
    // globally (Plaid Sandbox is known to reuse transaction_id strings across unrelated
    // users/Items — see migration 0010's own comment) — a query not scoped to this Item's accounts
    // could otherwise resolve to a different Item's row entirely.
    const { data: removalTargets, error: removalLookupError } = await supabase
      .from("plaid_transactions")
      .select("plaid_account_id, transaction_id")
      .in("plaid_account_id", itemAccountInternalIds)
      .in("transaction_id", removedTransactionIds);
    if (removalLookupError) throw removalLookupError;

    if ((removalTargets ?? []).length > 0) {
      const removalRows = (removalTargets ?? []).map((row) => ({
        plaid_account_id: row.plaid_account_id as string,
        owner_user_id: item.user_id as string,
        transaction_id: row.transaction_id as string,
        removed_at: nowIso,
      }));
      // Upsert, never plain insert — a transaction_id reported removed again after a previously
      // failed attempt was safely retried (against the same never-advanced cursor) must bump
      // removed_at on the existing row, not accumulate a duplicate (see migration 0028's own
      // comment on plaid_transaction_removals' unique constraint).
      const { error: removalUpsertError } = await supabase
        .from("plaid_transaction_removals")
        .upsert(removalRows, { onConflict: "plaid_account_id,transaction_id" });
      if (removalUpsertError) throw removalUpsertError;

      const { error: deleteError } = await supabase
        .from("plaid_transactions")
        .delete()
        .in("plaid_account_id", itemAccountInternalIds)
        .in("transaction_id", removedTransactionIds);
      if (deleteError) throw deleteError;
    }
  }

  // Only reached after every page fetched AND every row persisted — see this file's own header.
  const { error: releaseError } = await supabase.rpc("release_item_transaction_sync", {
    p_item_id: itemRowId,
    p_success: true,
    p_new_cursor: cursor ?? null,
    p_error: null,
  });
  if (releaseError) throw releaseError;

  logPlaidOperation({
    operation: "sync-item-transactions",
    outcome: "success",
    connectionId: item.id,
    addedCount: added.length,
    modifiedCount: modified.length,
    removedCount: removed.length,
  });

  return {
    skipped: false,
    success: true,
    addedCount: added.length,
    modifiedCount: modified.length,
    removedCount: removed.length,
  };
}
