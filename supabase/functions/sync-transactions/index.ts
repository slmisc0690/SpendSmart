// Supabase Edge Function: sync-transactions
//
// Called by the iOS app to fetch new/updated transactions for ONE linked institution. Looks up
// the stored access_token server-side (never from the request), calls Plaid's
// /transactions/sync, and returns a normalized, read-only transaction list shaped to match the
// iOS app's `PlaidTransactionDTO`. The access_token itself never leaves this function.
//
// MULTI-INSTITUTION: `connection_id` is the intended long-term contract — a household account
// can link more than one institution (or Plaid Item), so there is no longer a single
// well-defined "the" plaid_items row for a user_id to guess at (the previous `.limit(1)`
// behavior would silently sync whichever row happened to sort first, which is wrong the moment
// a second connection exists). The iOS app is responsible for calling this once per connection
// it wants refreshed (see PlaidConnectionManager) — this function still does exactly one
// connection's sync per call, kept deliberately simple/atomic rather than trying to fan out to
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
// longer calling this function — see the deployment plan for the exact removal criteria.
import {
  assertItemEnvironmentMatches,
  createPrivilegedClient,
  EnvironmentMismatchError,
  isValidUuid,
  jsonResponse,
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

  try {
    let item: { id: string; access_token: string; cursor: string | null; requires_reauth: boolean; environment: string | null } | null;

    if (connection_id !== undefined) {
      // Scoped by the specific row id AND user_id — never a bare "first row for this user"
      // lookup (see this file's header for why that used to be ambiguous the moment a user has
      // more than one connection).
      const { data, error: lookupError } = await supabase
        .from("plaid_items")
        .select("id, access_token, cursor, requires_reauth, environment")
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
        .select("id, access_token, cursor, requires_reauth, environment")
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
    // Must be checked BEFORE calling Plaid — see assertItemEnvironmentMatches's doc comment.
    assertItemEnvironmentMatches(item.environment);
    if (item.requires_reauth) {
      // Plaid will reject /transactions/sync for an Item in this state anyway (ITEM_LOGIN_REQUIRED
      // webhooks fire precisely because the access_token can no longer be used) — failing fast
      // here avoids a wasted round-trip and gives the app a distinct, actionable error code
      // instead of a generic Plaid failure to parse.
      return jsonResponse({ error: "This connection needs to be reconnected", requires_reauth: true }, 409);
    }
    console.log("[sync-transactions] stored cursor present:", item.cursor != null);

    // Plaid paginates /transactions/sync — a single call only returns up to one page (has_more
    // indicates whether more exist for this diff). Loop until has_more is false so the app always
    // gets the FULL diff in one round-trip, not just the first ~100 transactions. next_cursor is
    // only persisted to Postgres once the entire loop finishes without error, so a failure
    // partway through never leaves the stored cursor pointing past data we never actually
    // returned to the app.
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
    console.log("[sync-transactions] plaid /transactions/sync request completed, pages:", pageCount);
    console.log("[sync-transactions] added count:", added.length);
    console.log("[sync-transactions] modified count:", modified.length);
    console.log("[sync-transactions] removed count:", removed.length);
    console.log("[sync-transactions] has_more (final):", hasMore);

    // Shared shape for both `added` and `modified` — iOS decodes both through the same DTO.
    const toWireTransaction = (t: Record<string, unknown>) => ({
      external_transaction_id: t.transaction_id,
      pending_transaction_id: t.pending_transaction_id ?? null,
      plaid_account_id: t.account_id,
      // Sent as a STRING, not a JSON number. The iOS app decodes this into a `Decimal` from the
      // string directly — a JSON number would round-trip through Double first and can silently
      // corrupt exact cent values (e.g. 19.99 -> 19.98999999999999488).
      amount: String(t.amount),
      merchant_name: t.merchant_name ?? null,
      original_description: t.name,
      authorized_date: t.authorized_date ?? null,
      posted_date: t.date ?? null,
      is_pending: t.pending === true,
      category_guess: Array.isArray(t.category) ? t.category[0] : null,
    });

    const transactions = added.map(toWireTransaction);
    const modifiedTransactions = modified.map(toWireTransaction);
    // Plaid's `removed` entries only ever carry `transaction_id` (no other fields) — forward just
    // the ids so the app can delete/reconcile its matching local records.
    const removedTransactionIds = removed
      .map((r) => r.transaction_id)
      .filter((id): id is string => typeof id === "string" && id.length > 0);

    // Persist the new cursor so the next sync only fetches what's changed since this one. Only
    // reached after the pagination loop above has fully succeeded — cursor here is the LAST
    // page's next_cursor, i.e. the correct resume point for the next call. Scoped by primary key +
    // user_id (never by access_token, so the token never has to appear in a query predicate that
    // could end up in a Postgres error/log line).
    const { error: cursorUpdateError } = await supabase
      .from("plaid_items")
      .update({ cursor, updated_at: new Date().toISOString() })
      .eq("id", item.id)
      .eq("user_id", userId);
    console.log("[sync-transactions] final cursor saved:", !cursorUpdateError);
    console.log("[sync-transactions] response transaction count:", transactions.length);

    return jsonResponse({
      connection_id: item.id,
      transactions,
      modified_transactions: modifiedTransactions,
      removed_transaction_ids: removedTransactionIds,
      next_cursor: cursor,
      modified_count: modified.length,
      removed_count: removed.length,
    });
  } catch (error) {
    logSafeError("sync-transactions failed", error);

    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof EnvironmentMismatchError) {
      return jsonResponse({ error: error.message, environment_mismatch: true }, 409);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to sync transactions" }, 500);
  }
});
