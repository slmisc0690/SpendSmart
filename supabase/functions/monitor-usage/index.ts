// Supabase Edge Function: monitor-usage
//
// SpendSmart's read-only usage/cost aggregate for the external cost-monitor dashboard (alongside
// Scan2Cal, LifeVaultPlus, StreamDrop). Strictly aggregates-only, no user identity, no secrets:
// every query below is a SELECT and nothing here ever returns a row, a user id, or an
// institution/account name.
//
// WHAT THIS REPORTS, AND WHY: Plaid bills per Item per month, not per API call — so the one
// number that matters here is the live Item count (plaid_items row count; both disconnect-account
// and delete-account hard-delete a row unconditionally, so a row's existence is this database's
// only honest signal of "still billing"). Per-Item age/created_at and Plaid product enablement are
// deliberately NOT reported here — neither has an honest slot in the shared contract (no per-entity
// list shape exists), and forcing them into an unrelated field (e.g. lastRequestAt for "oldest
// Item") would render one concept as another, which is exactly what this contract's null-vs-zero
// discipline exists to prevent. Per-Item age instead belongs on SpendSmart's own Connected
// Accounts screen, not a cost dashboard.
//
// The stuck-orphan count (plaid_item_removal_failures rows older than 24h) is the visibility half
// of the Item-leak-closure fix (migration 0029) — it must render as unknown, not zero, if that
// table cannot be read; see the per-table try/catch below, each of which leaves its own count null
// on failure rather than defaulting to 0.
//
// TWO DELIBERATE FIELD OVERLOADS, recorded here and in CLAUDE.md so a future reader doesn't take
// the field names at face value: the shared contract has no dedicated "billable unit count" field
// (its shape is built for call/token-based billing). `month.calls` below means "live Plaid Item
// count," and `byCategory[].calls` means "row count in that category" — neither is ever a request
// count for this service. The `label`/`billing`/`category` strings carry the real meaning; the
// field names themselves cannot.
//
// AUTH, two independent layers, both required, checked BEFORE any database access:
//   1. Gateway-level verify_jwt = true (the default for this function specifically — see
//      supabase/config.toml, which deliberately does NOT list monitor-usage among the
//      verify_jwt = false functions). The caller presents a valid Supabase API key as
//      `Authorization: Bearer <key>` — not secret, ships in the monitor's own client.
//   2. This function's OWN dedicated secret, MONITOR_USAGE_TOKEN, checked via the `X-Monitor-Token`
//      header with a constant-time comparison — never `==`. Fails closed: an unset secret means
//      every request is unauthorized, never silently allowed through.
// A failed check returns a minimal, generic 401 body — never a table name, env var name, or stack
// trace, success or failure.

import { createPrivilegedClient, jsonResponse, logSafeError, UnauthorizedError } from "../_shared/plaid.ts";

const SUPABASE_REGION = "ca-central-1"; // verified against `supabase projects list` for this project, not assumed from documentation.

/** SHA-256-based constant-time comparison. Hashing first means both branches always compare a
 * fixed 32-byte digest, so neither the loop length nor its exit point can leak the raw secret's
 * length or contents via timing — a plain `===`/`==` on the raw strings would short-circuit on
 * the first mismatched character and a naive byte-loop would still leak length differences. */
async function timingSafeEqual(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [aDigest, bDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const aBytes = new Uint8Array(aDigest);
  const bBytes = new Uint8Array(bDigest);
  let diff = 0;
  for (let i = 0; i < aBytes.length; i++) {
    diff |= aBytes[i] ^ bBytes[i];
  }
  return diff === 0;
}

async function requireMonitorToken(req: Request): Promise<void> {
  const expected = Deno.env.get("MONITOR_USAGE_TOKEN");
  if (!expected) {
    // Fail closed: an unset secret is never treated as "no check configured, allow through."
    throw new UnauthorizedError("Monitor token not configured");
  }
  const provided = req.headers.get("X-Monitor-Token");
  if (!provided || !(await timingSafeEqual(provided, expected))) {
    throw new UnauthorizedError("Invalid monitor token");
  }
}

function projectRefFromSupabaseUrl(): string | null {
  const url = Deno.env.get("SUPABASE_URL");
  if (!url) return null;
  try {
    return new URL(url).hostname.split(".")[0] || null;
  } catch {
    return null;
  }
}

interface UsageStats {
  calls: number | null;
  succeeded: number | null;
  failed: number | null;
  rejected: number | null;
  inputTokens: number | null;
  cachedInputTokens: number | null;
  outputTokens: number | null;
  totalTokens: number | null;
  costUSD: number | null;
  latencyMsAvg: number | null;
  latencyMsP95: number | null;
}

function emptyUsageStats(calls: number | null): UsageStats {
  return {
    calls,
    succeeded: null,
    failed: null,
    rejected: null,
    inputTokens: null,
    cachedInputTokens: null,
    outputTokens: null,
    totalTokens: null,
    costUSD: null,
    latencyMsAvg: null,
    latencyMsP95: null,
  };
}

Deno.serve(async (req) => {
  if (req.method !== "GET") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  try {
    await requireMonitorToken(req);
  } catch (error) {
    logSafeError("monitor-usage auth failed", error);
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  const now = new Date();
  // boundaries' three fields are structural reference points the client uses for its own
  // rendering — required non-null strings regardless of whether any service below reports daily
  // figures (that is a separate decision; SpendSmart's services simply never populate a `today`
  // UsageStats object, but boundaries.todayStart itself must still be real).
  const todayStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));

  // Every field below defaults to the shape a total failure must still produce: schemaVersion,
  // app, generatedAt, boundaries, status, and services (as an empty array) are the required
  // fields the contract says can never be missing without discarding the ENTIRE payload — so the
  // outer try/catch below falls back to this exact skeleton rather than a 500 with no body.
  try {
    const supabase = createPrivilegedClient();

    let liveItemCount: number | null = null;
    try {
      const { count, error } = await supabase
        .from("plaid_items")
        .select("*", { count: "exact", head: true });
      if (error) throw error;
      // A null count with NO error is its own failure — a silent success-shaped non-answer
      // (e.g. a 204 whose Content-Range header never resolved), not "zero rows." `?? 0` here
      // would quietly turn "the table did not resolve" into a false zero; this table's own row
      // count is the number this whole endpoint is built around, so this must throw, not guess.
      if (count === null) throw new Error("plaid_items count is null with no query error — the table did not resolve");
      liveItemCount = count;
    } catch (error) {
      logSafeError("monitor-usage: failed to read plaid_items", error);
      liveItemCount = null;
    }

    let stuckOrphanCount: number | null = null;
    try {
      const cutoff = new Date(now.getTime() - 24 * 60 * 60 * 1000).toISOString();
      const { count, error } = await supabase
        .from("plaid_item_removal_failures")
        .select("*", { count: "exact", head: true })
        .lt("detected_at", cutoff);
      if (error) throw error;
      // See the plaid_items count above for why a null count with no error must throw rather
      // than default to 0 — this is the same silent-204 class of failure, on a different table.
      if (count === null) throw new Error("plaid_item_removal_failures count is null with no query error — the table did not resolve");
      stuckOrphanCount = count;
    } catch (error) {
      logSafeError("monitor-usage: failed to read plaid_item_removal_failures", error);
      stuckOrphanCount = null;
    }

    // UNIT ECONOMICS — distinct-user count and max-Items-for-one-user, derived from the same
    // plaid_items.user_id column (present and NOT NULL on every row). PostgREST has no built-in
    // "count distinct"/"max per group" aggregate reachable from this client, so both numbers are
    // computed here from one plain `select("user_id")` — trivial at this table's current size,
    // and both numbers share a single query/failure since they're derived from the same read.
    // THE NULL TRAP: CategoryBreakdown.calls is a non-optional Int in the monitor's own Swift
    // model (verified directly against USAGE_CONTRACT_SPEC.md before writing this) — sending
    // `calls: null` there fails the ENTIRE payload's decode, not just this row. So on failure
    // these stay null HERE (internal signal), and the row itself is OMITTED ENTIRELY below,
    // never sent with null or a substituted 0 — a failed read is not zero users.
    let usersWithItemsCount: number | null = null;
    let maxItemsForOneUser: number | null = null;
    try {
      const { data, error } = await supabase.from("plaid_items").select("user_id");
      if (error) throw error;
      const perUserCounts = new Map<string, number>();
      for (const row of (data ?? []) as { user_id: string }[]) {
        perUserCounts.set(row.user_id, (perUserCounts.get(row.user_id) ?? 0) + 1);
      }
      usersWithItemsCount = perUserCounts.size;
      maxItemsForOneUser = perUserCounts.size > 0 ? Math.max(...perUserCounts.values()) : 0;
    } catch (error) {
      logSafeError("monitor-usage: failed to read plaid_items for per-user counts", error);
      usersWithItemsCount = null;
      maxItemsForOneUser = null;
    }

    // REGISTERED USERS — the denominator: how many people have signed up at all, regardless of
    // whether they ever connected a bank. user_profiles has no soft-delete/is_active column (it
    // cascade-deletes with auth.users, migration 0008) — a plain row count already means exactly
    // "registered users," no filter needed for that to be true.
    let registeredUsersCount: number | null = null;
    try {
      const { count, error } = await supabase
        .from("user_profiles")
        .select("*", { count: "exact", head: true });
      if (error) throw error;
      // See the plaid_items count above for why a null count with no error must throw rather
      // than default to 0 — this is the same silent-204 class of failure, on a different table.
      if (count === null) throw new Error("user_profiles count is null with no query error — the table did not resolve");
      registeredUsersCount = count;
    } catch (error) {
      logSafeError("monitor-usage: failed to read user_profiles", error);
      registeredUsersCount = null;
    }

    // CONNECTED ACCOUNTS — distinct from the Item count above: one Item (one login) can cover
    // several accounts at the same institution, and Plaid bills per Item, not per account, so this
    // is the number that actually shows the ratio. plaid_accounts soft-deletes (is_active/
    // removed_at, migration 0004) so a closed/removed account's row stays forever for historical
    // transaction references — filtered to is_active = true so this counts accounts connected
    // RIGHT NOW, matching what the "Connected accounts" label actually claims.
    let connectedAccountsCount: number | null = null;
    try {
      const { count, error } = await supabase
        .from("plaid_accounts")
        .select("*", { count: "exact", head: true })
        .eq("is_active", true);
      if (error) throw error;
      // See the plaid_items count above for why a null count with no error must throw rather
      // than default to 0 — this is the same silent-204 class of failure, on a different table.
      if (count === null) throw new Error("plaid_accounts count is null with no query error — the table did not resolve");
      connectedAccountsCount = count;
    } catch (error) {
      logSafeError("monitor-usage: failed to read plaid_accounts", error);
      connectedAccountsCount = null;
    }

    // ServiceStatus (the monitor's own Swift enum) accepts exactly: online, watch, degraded,
    // down, idle — anything else decodes to .unknown(String), so this MUST send one of those
    // five literal strings, never a free-form word like the earlier "ok".
    const status = liveItemCount === null || stuckOrphanCount === null || usersWithItemsCount === null
      || registeredUsersCount === null || connectedAccountsCount === null
      ? "degraded"
      : "online";

    // health.degraded names WHICH read failed, not just that something did — a degraded status
    // plus null numbers can't otherwise distinguish one broken query from another. Each string
    // reports an observed failure, never an inference: only pushed when that specific read's own
    // try/catch above actually caught an error.
    const degradedReasons: string[] = [];
    if (liveItemCount === null) degradedReasons.push("plaid_items_unreadable");
    if (stuckOrphanCount === null) degradedReasons.push("removal_failures_unreadable");
    if (usersWithItemsCount === null) degradedReasons.push("plaid_items_user_counts_unreadable");
    if (registeredUsersCount === null) degradedReasons.push("user_profiles_unreadable");
    if (connectedAccountsCount === null) degradedReasons.push("plaid_accounts_unreadable");

    // byCategory rows — EVERY row here (including "Stuck orphans," a pre-existing row that was
    // previously sent unconditionally with `calls: stuckOrphanCount` even when that was `null`)
    // is now pushed only when its own read succeeded. CategoryBreakdown.calls is a non-optional
    // Int in the monitor's own Swift model (verified against USAGE_CONTRACT_SPEC.md) — a `null`
    // there fails the ENTIRE payload's decode, not just that one row. This was a real, live gap:
    // before this change, a stuckOrphanCount failure (its own catch block already existed and
    // already set it to null) would have sent `calls: null` for that row and broken every field
    // in this response, silently, the next time that one query happened to fail — independent of,
    // and unrelated to, the null-count/silent-204 fix in CHANGE 1 above.
    const byCategoryRows: { category: string; calls: number; costUSD: null }[] = [];
    if (stuckOrphanCount !== null) {
      byCategoryRows.push({ category: "Stuck orphans (over 24h)", calls: stuckOrphanCount, costUSD: null });
    }
    if (usersWithItemsCount !== null) {
      byCategoryRows.push({ category: "Users with Plaid Items", calls: usersWithItemsCount, costUSD: null });
    }
    if (maxItemsForOneUser !== null) {
      byCategoryRows.push({ category: "Max Items for one user", calls: maxItemsForOneUser, costUSD: null });
    }
    if (registeredUsersCount !== null) {
      byCategoryRows.push({ category: "Registered users", calls: registeredUsersCount, costUSD: null });
    }
    if (connectedAccountsCount !== null) {
      byCategoryRows.push({ category: "Connected accounts", calls: connectedAccountsCount, costUSD: null });
    }

    const body = {
      schemaVersion: 2,
      app: "SpendSmart",
      generatedAt: now.toISOString(),
      boundaries: {
        timezone: "UTC",
        todayStart: todayStart.toISOString(),
        monthStart: monthStart.toISOString(),
      },
      status,
      services: [
        {
          id: "plaid", // confirmed against the monitor's RateBookSeed (id: "plaid", appID: "spendsmart")
          label: "Plaid Items",
          billing: "per_item_monthly",
          status,
          meta: null,
          today: null,
          month: emptyUsageStats(liveItemCount),
          lastRequestAt: null,
          byModel: null,
          byCategory: byCategoryRows,
          byRoute: null,
          plan: null,
          projectRef: projectRefFromSupabaseUrl(),
          region: SUPABASE_REGION,
        },
      ],
      controls: null,
      limits: null,
      health: {
        // No control plane exists anywhere in this project — a confirmed fact, not an unknown,
        // so this is `false` rather than `null`.
        controlPlaneReadable: false,
        // plaid_items IS this service's usage table; this reports the real outcome of BOTH reads
        // of it above (live count, and the per-user breakdown), not an assumption. Widened from
        // just liveItemCount when the per-user read was added, so this can't say "true" while one
        // of the two plaid_items reads actually failed.
        usageTableReadable: liveItemCount !== null && usersWithItemsCount !== null,
        degraded: degradedReasons,
      },
    };

    return jsonResponse(body, 200);
  } catch (error) {
    logSafeError("monitor-usage failed", error);
    // Total failure — something threw before either table read was even attempted (e.g.
    // createPrivilegedClient() itself). Neither "plaid_items_unreadable" nor
    // "removal_failures_unreadable" belongs here: naming a specific read as the cause would
    // report an inference as an observation, when in fact no read ran at all. "backend_unavailable"
    // says what actually happened instead.
    return jsonResponse(
      {
        schemaVersion: 2,
        app: "SpendSmart",
        generatedAt: now.toISOString(),
        boundaries: {
          timezone: "UTC",
          todayStart: todayStart.toISOString(),
          monthStart: monthStart.toISOString(),
        },
        status: "degraded",
        services: [],
        controls: null,
        limits: null,
        health: {
          controlPlaneReadable: false,
          usageTableReadable: false,
          degraded: ["backend_unavailable"],
        },
      },
      200,
    );
  }
});
