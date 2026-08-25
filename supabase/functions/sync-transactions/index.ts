// Supabase Edge Function: sync-transactions
//
// Called by the iOS app to fetch new/updated/removed transactions for ONE linked institution,
// shaped to match the iOS app's `PlaidTransactionDTO`. As of the Plaid webhook-driven background
// sync phase, this function NO LONGER calls Plaid at all — it reads the already-reconciled
// plaid_transactions / plaid_transaction_removals mirror (kept current by the webhook-triggered and
// manual-refresh-triggered Item-level sync engine, ../_shared/itemTransactionSync.ts) and returns
// whatever has changed since this Item's `plaid_items.last_transactions_ack_at` watermark.
//
// WHY THE PLAID CALL MOVED OUT OF THIS FUNCTION: Plaid's /transactions/sync cursor is a single,
// stateful, per-Item stream — only one caller can ever "consume" a given diff without the other
// missing it. Once a webhook-triggered background sync needed to become a second, independent
// trigger source for the same Item, the project's own "one authoritative cursor per Item"
// requirement meant exactly one thing could still call Plaid for that Item going forward. The
// webhook-triggered/manual-refresh-triggered syncItemTransactionsForItem is that one thing (see its
// own file header); this function became a pure read of what it has already persisted. The iOS
// app's OWN behavior is unaffected: `PlaidConnectionManager.syncAndImportTransactions` calls
// sync-item-transactions FIRST (forcing a real attempt, exactly preserving today's manual-refresh
// Plaid-call volume) and THEN this function (to actually receive the result) — see that method's
// own updated doc comment.
//
// WATERMARK, NOT CURSOR: `last_transactions_ack_at` tracks what has already been DELIVERED to the
// owning iPhone client, entirely distinct from `plaid_items.cursor` (Plaid's own opaque bookmark,
// used only by the Item-sync engine). A null watermark means "nothing yet acknowledged" — every
// currently-mirrored row for this Item's accounts is returned, matching a fresh Item's fully
// backfilled history. The watermark advances to the exact instant the query for this response was
// issued (captured before any query, so nothing that arrives DURING this handler's own execution
// can be silently skipped by a race between "read" and "mark as delivered").
//
// REQUIRES_REAUTH GUARD RETAINED, ENVIRONMENT GUARD REMOVED: requires_reauth is kept, in the exact
// same condition and response shape as before this phase, since it is a genuine user-facing signal
// (the iOS client's "needs to be reconnected" prompt) unrelated to whether THIS function happens to
// call Plaid. The environment-mismatch guard, by contrast, existed solely to avoid wasting a Plaid
// round-trip with a token issued under the wrong environment — since this function no longer calls
// Plaid at all, re-implementing that check here would mean coupling a pure DB read to
// PLAID_CLIENT_ID/PLAID_SECRET being configured for no behavioral benefit (it was never a
// user-facing invariant this function exists to enforce; assertItemEnvironmentMatches is still
// called, unchanged, everywhere Plaid is actually reached — sync-item-transactions and the Item-sync
// engine). Removed here rather than duplicated with different semantics.
//
// MULTI-INSTITUTION: `connection_id` is the intended long-term contract — a household account
// can link more than one institution (or Plaid Item), so there is no longer a single
// well-defined "the" plaid_items row for a user_id to guess at (the previous `.limit(1)`
// behavior would silently sync whichever row happened to sort first, which is wrong the moment
// a second connection exists). The iOS app is responsible for calling this once per connection
// it wants refreshed (see PlaidConnectionManager) — this function still does exactly one
// connection's pull per call, kept deliberately simple/atomic rather than trying to fan out to
// every connection server-side.
//
// TEMPORARY BACKWARD COMPATIBILITY — DELETE AFTER THE OLD iOS CLIENT IS NO LONGER IN THE FIELD:
// the previously-shipped iOS build calls this endpoint with NO `connection_id` in its request
// body at all (it predates multi-institution support). Deploying this function's new
// connection-scoped behavior would otherwise 400 that build on every sync. So: a MISSING
// `connection_id` falls back to "the exactly-one plaid_items row for this user", which is
// exactly what the old client always assumed existed. A user who has linked a SECOND
// institution (only possible via the NEW client, which always sends connection_id explicitly)
// makes this fallback ambiguous by construction — that case 400s rather than guessing, so it
// can never silently sync the wrong institution. `connection_id` PROVIDED but not a valid UUID
// is a distinct, harder error (a malformed request from a client that knows about the field)
// and still 400s immediately, before any lookup. Remove this whole fallback block (and go back
// to requiring `connection_id` unconditionally) once telemetry shows the old client is no
// longer calling this function — see the deployment plan for the exact removal criteria. This
// fallback block is unchanged by this phase.
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

interface NormalizedTransactionRow {
  plaid_account_id: string;
  transaction_id: string;
  pending_transaction_id: string | null;
  original_description: string;
  merchant_name: string | null;
  amount: number;
  authorized_date: string | null;
  posted_date: string | null;
  is_pending: boolean;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[sync-transactions] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("sync-transactions auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const { connection_id } = await req.json().catch(() => ({}));
  if (connection_id !== undefined && !isValidUuid(connection_id)) {
    return jsonResponse({ error: "connection_id (a valid UUID) is required" }, 400);
  }

  // Populated as soon as the connection is resolved, purely so the catch-all below can log it —
  // never used for anything else.
  let connectionIdForLogging: string | undefined;

  try {
    let item: {
      id: string;
      requires_reauth: boolean;
      last_transactions_ack_at: string | null;
    } | null;

    const selectColumns = "id, requires_reauth, last_transactions_ack_at";

    if (connection_id !== undefined) {
      // Scoped by the specific row id AND user_id — never a bare "first row for this user"
      // lookup (see this file's header for why that used to be ambiguous the moment a user has
      // more than one connection).
      const { data, error: lookupError } = await supabase
        .from("plaid_items")
        .select(selectColumns)
        .eq("id", connection_id)
        .eq("user_id", userId)
        .maybeSingle();
      if (lookupError) throw lookupError;
      item = data;
    } else {
      // Old-client fallback — see this file's header comment. Fetches up to 2 rows (never more)
      // purely so "exactly one" vs. "more than one" can be distinguished without pulling a
      // user's entire connection list into memory.
      console.warn("[sync-transactions] DEPRECATED: request omitted connection_id — falling back to single-item lookup. Remove this path once the old client is fully retired.");
      const { data: candidates, error: lookupError } = await supabase
        .from("plaid_items")
        .select(selectColumns)
        .eq("user_id", userId)
        .limit(2);
      if (lookupError) throw lookupError;
      if ((candidates ?? []).length > 1) {
        return jsonResponse(
          { error: "connection_id is required — more than one institution is linked to this account" },
          400,
        );
      }
      item = candidates?.[0] ?? null;
    }

    console.log("[sync-transactions] plaid_items row found:", !!item);
    if (!item) {
      return jsonResponse({ error: "No such connection for this account" }, 404);
    }
    connectionIdForLogging = item.id;
    // See this file's own header ("REQUIRES_REAUTH GUARD RETAINED, ENVIRONMENT GUARD REMOVED").
    if (item.requires_reauth) {
      return jsonResponse({ error: "This connection needs to be reconnected", requires_reauth: true }, 409);
    }

    // Captured BEFORE any query — this instant becomes the new watermark, so nothing persisted
    // DURING this handler's own execution (a race with a concurrent Item-sync engine run) can be
    // silently skipped: only rows/removals with a timestamp strictly at-or-before this instant are
    // ever returned or acknowledged.
    const queryStartedAt = new Date();
    const queryStartedAtIso = queryStartedAt.toISOString();
    const lastAck = item.last_transactions_ack_at;

    const { data: accountRows, error: accountsError } = await supabase
      .from("plaid_accounts")
      .select("id, account_id")
      .eq("plaid_item_id", item.id);
    if (accountsError) throw accountsError;

    const internalAccountIdToExternal: Record<string, string> = {};
    const itemAccountInternalIds: string[] = [];
    for (const row of accountRows ?? []) {
      internalAccountIdToExternal[row.id as string] = row.account_id as string;
      itemAccountInternalIds.push(row.id as string);
    }

    let changedRows: NormalizedTransactionRow[] = [];
    let removedTransactionIds: string[] = [];

    if (itemAccountInternalIds.length > 0) {
      let changedQuery = supabase
        .from("plaid_transactions")
        .select(
          "plaid_account_id, transaction_id, pending_transaction_id, original_description, merchant_name, amount, authorized_date, posted_date, is_pending",
        )
        .in("plaid_account_id", itemAccountInternalIds)
        .lte("updated_at", queryStartedAtIso);
      if (lastAck !== null) {
        changedQuery = changedQuery.gt("updated_at", lastAck);
      }
      const { data: changedData, error: changedError } = await changedQuery;
      if (changedError) throw changedError;
      changedRows = (changedData ?? []) as NormalizedTransactionRow[];

      let removedQuery = supabase
        .from("plaid_transaction_removals")
        .select("transaction_id")
        .in("plaid_account_id", itemAccountInternalIds)
        .lte("removed_at", queryStartedAtIso);
      if (lastAck !== null) {
        removedQuery = removedQuery.gt("removed_at", lastAck);
      }
      const { data: removedData, error: removedError } = await removedQuery;
      if (removedError) throw removedError;
      removedTransactionIds = (removedData ?? [])
        .map((row) => row.transaction_id as string)
        .filter((id) => typeof id === "string" && id.length > 0);
    }

    console.log("[sync-transactions] changed rows:", changedRows.length, "removed:", removedTransactionIds.length);

    // Every changed row (new OR updated) is emitted as an "added" entry — the iOS client's own
    // import logic (PlaidTransactionImportService.upsert) already treats `added` and `modified`
    // identically (both look up by external_transaction_id and upsert), so this project's own
    // Phase 0 architecture audit confirmed splitting them here would be pure ceremony, not a
    // behavior difference. `modified_transactions` is always empty; kept in the response purely
    // for wire-shape parity (the iOS decoder already treats it as optional/defaulting to empty).
    const transactions = changedRows.map((row) => ({
      external_transaction_id: row.transaction_id,
      pending_transaction_id: row.pending_transaction_id,
      plaid_account_id: internalAccountIdToExternal[row.plaid_account_id] ?? row.plaid_account_id,
      // Sent as a STRING, not a JSON number — same reasoning as before this phase: a JSON number
      // would round-trip through Double and can silently corrupt exact cent values.
      amount: String(row.amount),
      merchant_name: row.merchant_name,
      original_description: row.original_description,
      authorized_date: row.authorized_date,
      posted_date: row.posted_date,
      is_pending: row.is_pending,
      // plaid_transactions does not store Plaid's category guess (a deliberate, documented
      // exclusion from migration 0010 — nothing consumes it: PlaidTransactionImportService decodes
      // this field but never actually applies it anywhere, confirmed by this phase's own
      // architecture audit) — always null, matching what was already effectively unused before
      // this phase, not a new capability loss.
      category_guess: null as string | null,
    }));

    // Best-effort — matches this endpoint's own pre-existing tolerance for a failed bookkeeping
    // write (the previous implementation similarly never hard-failed the response over a failed
    // cursor update). A failure here only means the SAME batch may be redelivered on the next
    // pull, which the iOS client's own upsert-by-external-id import already handles idempotently —
    // never data loss, never a duplicate.
    const { error: watermarkUpdateError } = await supabase
      .from("plaid_items")
      .update({ last_transactions_ack_at: queryStartedAtIso, updated_at: queryStartedAtIso })
      .eq("id", item.id)
      .eq("user_id", userId);
    console.log("[sync-transactions] watermark advanced:", !watermarkUpdateError);

    logPlaidOperation({
      operation: "sync-transactions",
      outcome: "success",
      connectionId: item.id,
      addedCount: transactions.length,
      removedCount: removedTransactionIds.length,
    });

    return jsonResponse({
      connection_id: item.id,
      transactions,
      modified_transactions: [],
      removed_transaction_ids: removedTransactionIds,
      next_cursor: null,
      modified_count: 0,
      removed_count: removedTransactionIds.length,
    });
  } catch (error) {
    logSafeError(`sync-transactions failed connection_id=${connectionIdForLogging ?? "unknown"}`, error);

    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to sync transactions" }, 500);
  }
});
