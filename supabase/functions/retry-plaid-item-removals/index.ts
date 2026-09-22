// Supabase Edge Function: retry-plaid-item-removals
//
// The sole consumer of plaid_item_removal_failures (migration 0029) — for every row not yet
// revoked, attempts /item/remove again. On success, DELETES the row immediately (never marks it
// resolved) — this table must never accumulate resolved-but-retained rows, only currently-
// unrevoked ones (see that migration's own header: "steady-state size should be zero"). On
// failure, records the attempt (attempt_count/last_attempted_at) so a row stuck for a long time
// becomes visible via elapsed time, never silently retried forever with nothing to show for it.
//
// CADENCE — hourly for the first 24 hours since detected_at, then daily thereafter, indefinitely
// (isRetryDue, below). The cron TRIGGER itself just fires hourly (migration 0030); this function
// decides per-row whether THIS tick is actually due for that specific row.
//
// SERVICE-ROLE ONLY, never callable by the iOS app or any authenticated user. Verified via a
// shared secret dedicated to this one function (RETRY_PLAID_ITEM_REMOVALS_SECRET) — deliberately
// NOT this project's own Supabase service-role/secret key: that value is write-only once set
// (Supabase never returns it in plaintext again), so it could not be independently placed into
// Supabase Vault for pg_net to present, or verified end-to-end during testing. A secret minted
// specifically for this one purpose has a strictly smaller blast radius than the platform's own
// service-role credential anyway, and is fully testable. The iOS app never holds it — it is set
// only as a Supabase secret and a Vault entry, never shipped to any client.

import {
  createPrivilegedClient,
  jsonResponse,
  logSafeError,
  plaidFetch,
  PlaidRequestError,
  SafeError,
  UnauthorizedError,
} from "../_shared/plaid.ts";

function requireRetrySecretCaller(req: Request): void {
  const expectedSecret = Deno.env.get("RETRY_PLAID_ITEM_REMOVALS_SECRET");
  if (!expectedSecret) {
    throw new SafeError("Backend is misconfigured: RETRY_PLAID_ITEM_REMOVALS_SECRET is not set.");
  }
  const authHeader = req.headers.get("Authorization");
  if (authHeader !== `Bearer ${expectedSecret}`) {
    throw new UnauthorizedError("This function may only be invoked with its own dedicated retry secret.");
  }
}

const ONE_HOUR_MS = 60 * 60 * 1000;
const ONE_DAY_MS = 24 * ONE_HOUR_MS;

interface RemovalFailureRow {
  id: string;
  item_id: string;
  access_token: string;
  detected_at: string;
  attempt_count: number;
  last_attempted_at: string | null;
}

/** Hourly for the first 24h since detected_at, then daily thereafter — never stops. */
export function isRetryDue(row: Pick<RemovalFailureRow, "detected_at" | "last_attempted_at">, now: Date): boolean {
  if (!row.last_attempted_at) return true;
  const ageMs = now.getTime() - new Date(row.detected_at).getTime();
  const sinceLastAttemptMs = now.getTime() - new Date(row.last_attempted_at).getTime();
  const requiredGapMs = ageMs < ONE_DAY_MS ? ONE_HOUR_MS : ONE_DAY_MS;
  return sinceLastAttemptMs >= requiredGapMs;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  try {
    requireRetrySecretCaller(req);
  } catch (error) {
    logSafeError("retry-plaid-item-removals auth failed", error);
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const supabase = createPrivilegedClient();
  const now = new Date();

  try {
    const { data: rows, error: fetchError } = await supabase
      .from("plaid_item_removal_failures")
      .select("id, item_id, access_token, detected_at, attempt_count, last_attempted_at");
    if (fetchError) throw fetchError;

    let revokedCount = 0;
    let stillFailingCount = 0;
    let skippedCount = 0;

    for (const row of (rows ?? []) as RemovalFailureRow[]) {
      if (!isRetryDue(row, now)) {
        skippedCount += 1;
        continue;
      }

      try {
        await plaidFetch("/item/remove", { access_token: row.access_token });
        const { error: deleteError } = await supabase.from("plaid_item_removal_failures").delete().eq("id", row.id);
        if (deleteError) throw deleteError;
        revokedCount += 1;
      } catch (revokeError) {
        // Plaid reporting the Item already gone (e.g. a previous retry's /item/remove call
        // actually succeeded at Plaid but this table's own delete never completed — a crash
        // between the two) is functionally identical to a fresh success: nothing more to revoke.
        const alreadyRemoved = revokeError instanceof PlaidRequestError &&
          (revokeError.body as { error_code?: string } | null | undefined)?.error_code === "ITEM_NOT_FOUND";
        if (alreadyRemoved) {
          const { error: deleteError } = await supabase.from("plaid_item_removal_failures").delete().eq("id", row.id);
          if (deleteError) throw deleteError;
          revokedCount += 1;
          continue;
        }

        logSafeError("retry-plaid-item-removals: retry failed for a row", revokeError);
        const { error: updateError } = await supabase
          .from("plaid_item_removal_failures")
          .update({ attempt_count: row.attempt_count + 1, last_attempted_at: now.toISOString() })
          .eq("id", row.id);
        if (updateError) throw updateError;
        stillFailingCount += 1;
      }
    }

    console.log(
      "[retry-plaid-item-removals] revoked:", revokedCount,
      "still failing:", stillFailingCount,
      "skipped (not due yet):", skippedCount,
    );

    return jsonResponse({ revoked: revokedCount, still_failing: stillFailingCount, skipped: skippedCount });
  } catch (error) {
    logSafeError("retry-plaid-item-removals failed", error);
    return jsonResponse({ error: "Failed to process removal retries" }, 500);
  }
});
