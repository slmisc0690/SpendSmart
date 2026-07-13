// Supabase Edge Function: debug-reset-cursor
//
// Sandbox/testing-only recovery tool for the atomicity gap documented in
// PlaidTransactionImportService: sync-transactions persists the new Plaid cursor to Postgres
// as soon as its own pagination loop succeeds, BEFORE the iOS app has confirmed it actually
// saved that diff to SwiftData. If the app's persistence step fails after a successful sync
// (decode error, SwiftData save failure, app killed mid-save), that diff is gone — Plaid's
// cursor-based /transactions/sync never redelivers an "added" transaction once its cursor has
// advanced past it. There is no user-facing account risk (nothing financial is lost — these are
// read-only, not-yet-approved imports), but the device can end up permanently missing some
// imported transactions until Plaid produces new activity.
//
// This function is the recovery path for that: reset a specific connection's stored cursor to
// null so the next sync-transactions call re-pulls the FULL history from scratch (Plaid Sandbox
// keeps replaying the same seeded transactions indefinitely, so this is safe and repeatable in
// Sandbox). It is deliberately NOT wired into any real user-facing flow — the iOS app only calls
// it from a `#if DEBUG`-gated "Reset Cursor & Reimport" button, never in a Release build. That is
// ONLY a client-side guard, though — it does nothing to stop a signed-in user from calling this
// function directly over HTTP with their own valid access token, entirely bypassing the app. So
// this ALSO enforces server-side: `PLAID_ENV` (the same Supabase Secret every other function
// reads, see ../_shared/plaid.ts) must be `"sandbox"` (or unset, which defaults to sandbox) —
// once that secret is ever set to `"development"`/`"production"` for this project, every call
// here 403s unconditionally, regardless of who's authenticated. Removing/disabling this function
// entirely before a real go-live remains the recommended belt-and-suspenders step, but no longer
// the ONLY thing standing between an ordinary authenticated user and this endpoint.
//
// AUTH: same model as the other user-invoked functions — `verify_jwt = false` at the gateway
// (required by the new key system), authenticated in code via requireAuthenticatedUserId — PLUS
// the environment gate above, which is unique to this function.
//
// Longer-term, the better fix is protocol-level: have sync-transactions hold the new cursor
// until the app POSTs back a confirmation that it saved the diff (or have Plaid webhook-driven
// sync-transactions cache the last diff server-side so it can be replayed on request instead of
// only living in Plaid's own pagination state). Both are a real API contract change beyond this
// pass's scope — this function is the pragmatic stopgap for Sandbox/testing until then.

import {
  createPrivilegedClient,
  isValidUuid,
  jsonResponse,
  logSafeError,
  requireAuthenticatedUserId,
  SafeError,
  UnauthorizedError,
} from "../_shared/plaid.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  // Server-side environment gate — see this file's header comment. Checked BEFORE authentication
  // so a non-sandbox environment rejects every call uniformly, without depending on whether the
  // caller happens to hold a valid token.
  const plaidEnv = Deno.env.get("PLAID_ENV") ?? "sandbox";
  if (plaidEnv !== "sandbox") {
    console.error("[debug-reset-cursor] rejected: PLAID_ENV is not sandbox");
    return jsonResponse({ error: "Not available in this environment" }, 403);
  }

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("debug-reset-cursor auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const { connection_id } = await req.json().catch(() => ({}));
  if (!isValidUuid(connection_id)) {
    return jsonResponse({ error: "connection_id (a valid UUID) is required" }, 400);
  }

  try {
    // Scoped by the specific row id AND user_id, same as disconnect-account — never a bare
    // "first row for this user" lookup.
    const { error, count } = await supabase
      .from("plaid_items")
      .update({ cursor: null, updated_at: new Date().toISOString() }, { count: "exact" })
      .eq("id", connection_id)
      .eq("user_id", userId);

    if (error) throw error;

    return jsonResponse({ reset: true, rows_updated: count ?? 0 });
  } catch (error) {
    logSafeError("debug-reset-cursor failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to reset cursor" }, 500);
  }
});
