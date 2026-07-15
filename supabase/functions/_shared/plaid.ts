// Shared helpers for the SpendSmart Plaid Edge Functions.
//
// SECURITY:
// - PLAID_CLIENT_ID and PLAID_SECRET are read ONLY from environment variables (set via
//   `supabase secrets set`, never committed to source control, never sent to the iOS app).
// - PLAID_ENV selects which Plaid environment every function talks to — see `loadPlaidCredentials`
//   below. This is the SINGLE place that decides Plaid's base URL; no other file in this project
//   (Edge Function or iOS) may hardcode a `*.plaid.com` host.
// - Every function in this project calls Plaid over HTTPS using these credentials server-side.
//   The iOS app never sees PLAID_CLIENT_ID, PLAID_SECRET, or any Plaid access_token.
// - Every plaid_items row records the environment it was created under (see migration
//   0005_plaid_items_environment.sql); `assertItemEnvironmentMatches` below must be called before
//   any Plaid request that reuses an existing Item's stored access_token, so a token issued under
//   one environment can never be sent to a different environment's host.
//
// AUTH: user-invoked functions (create-link-token, exchange-public-token, sync-transactions,
// disconnect-account) run with `verify_jwt = false` at the gateway — NOT because they're
// unauthenticated, but because Supabase's gateway-level verify_jwt check only understands the
// legacy JWT-format anon/service_role keys; the new sb_publishable_/sb_secret_ key system sends
// those on the `apikey` header instead, and gateway verify_jwt rejects that with "JWT is
// invalid" (confirmed against Supabase's current docs/community reports). So every one of those
// four functions performs its own auth check in code instead, via `requireAuthenticatedUserId`
// below — never trusting the gateway to have done it.

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

/// The three Plaid environments this project can run against. Plaid itself only issues
/// `development` or `production` API keys distinct from `sandbox`; which of those two a given
/// PLAID_CLIENT_ID/PLAID_SECRET pair actually authenticates against is determined entirely by
/// Plaid's own dashboard, not by this project. `PLAID_ENV` just tells this code which base URL to
/// call with whatever credentials are currently set.
export type PlaidEnvironment = "sandbox" | "development" | "production";

const PLAID_ENVIRONMENTS: readonly PlaidEnvironment[] = ["sandbox", "development", "production"];

function isPlaidEnvironment(value: string): value is PlaidEnvironment {
  return (PLAID_ENVIRONMENTS as readonly string[]).includes(value);
}

/// Plaid's base URL per environment. `development` and `production` both point at
/// `production.plaid.com` — Plaid retired the separate `development.plaid.com` host industry-wide
/// (Development is now a quota/billing mode within the Production environment, not a distinct
/// API host); `development` is kept as its own `PlaidEnvironment` case anyway because Supabase
/// Secrets, dashboards, and this project's own docs still refer to "Development" as the
/// pre-production testing tier, and collapsing the two names into one enum value would make
/// `PLAID_ENV=development` a confusing thing to set. If Plaid ever reintroduces a distinct
/// Development host, only this map needs to change.
const PLAID_BASE_URLS: Record<PlaidEnvironment, string> = {
  sandbox: "https://sandbox.plaid.com",
  development: "https://production.plaid.com",
  production: "https://production.plaid.com",
};

export interface PlaidCredentials {
  clientId: string;
  secret: string;
  baseUrl: string;
  environment: PlaidEnvironment;
}

// General UUID shape check — deliberately does NOT require version 4 (the "4" in the third group,
// "8|9|a|b" in the fourth), since this validates both PLAID_SANDBOX_USER_ID and any plaid_items
// row id/item id a caller supplies, none of which are guaranteed to be v4-generated.
const UUID_PATTERN = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

export function isValidUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

/// An error whose `message` is safe to both log and return to the client — use this (instead of a
/// bare `Error` or an error from Postgres/Plaid) for every failure condition we construct
/// ourselves, so the catch-all error handling in each function can tell "safe to show" apart from
/// "may contain a token, sanitize before logging or responding."
export class SafeError extends Error {}

/// Thrown by `requireAuthenticatedUserId` — callers map this to an HTTP 401, distinct from every
/// other failure (which is a 500). Never carries any token material in its message.
export class UnauthorizedError extends Error {
  constructor(message = "Unauthorized") {
    super(message);
  }
}

/**
 * Validates the caller's Supabase Auth access token and returns their verified user id
 * (`auth.uid()`) — the ONLY source of `user_id` for every plaid_items read/write in this
 * project. Never accepts a user id from the request body.
 *
 * Required because gateway-level `verify_jwt` doesn't work with the new sb_publishable_/
 * sb_secret_ key system (see the file header) — this is the real authentication check for these
 * functions, done in code, not a gateway pass-through.
 *
 * `supabase` must be a client constructed with the privileged secret key (see
 * `loadSupabaseSecretKey`) — `auth.getUser(token)` validates whatever token is PASSED to it
 * against Supabase Auth, independent of which key the client itself holds, so reusing the same
 * privileged client already needed for the plaid_items operations is safe and avoids a second
 * client instance per request.
 */
export async function requireAuthenticatedUserId(
  req: Request,
  supabase: SupabaseClient,
): Promise<string> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    throw new UnauthorizedError("Missing Authorization header");
  }
  const accessToken = authHeader.slice("Bearer ".length).trim();
  if (!accessToken) {
    throw new UnauthorizedError("Missing bearer token");
  }

  const { data, error } = await supabase.auth.getUser(accessToken);
  if (error || !data.user) {
    throw new UnauthorizedError("Invalid or expired access token");
  }
  return data.user.id;
}

/** Convenience: `SUPABASE_URL` + the privileged secret key, in one client. */
export function createPrivilegedClient(): SupabaseClient {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  if (!supabaseUrl) {
    throw new SafeError("Backend is misconfigured: SUPABASE_URL must be set.");
  }
  return createClient(supabaseUrl, loadSupabaseSecretKey());
}

/**
 * Logs an error server-side without ever including fields that can carry secret material.
 * Postgres/PostgREST errors often embed the offending column VALUE directly in `message` or
 * `details` (e.g. `Key (access_token)=(access-sandbox-...) already exists`), and Plaid error
 * bodies can echo request fields back — so only structural, non-sensitive information (an HTTP
 * status, a Postgres SQLSTATE `code`, or our own pre-written `SafeError` message) is ever logged.
 */
export function logSafeError(context: string, error: unknown): void {
  if (error instanceof UnauthorizedError) {
    console.error(`${context}: unauthorized`, { reason: error.message });
    return;
  }
  if (error instanceof SafeError) {
    console.error(`${context}:`, error.message);
    return;
  }
  if (error instanceof PlaidRequestError) {
    console.error(`${context}: Plaid request failed`, { status: error.status });
    return;
  }
  if (typeof error === "object" && error !== null && "code" in error) {
    console.error(`${context}: database error`, { code: (error as { code: unknown }).code });
    return;
  }
  console.error(`${context}: unexpected error`);
}

/**
 * Reads this project's privileged (RLS-bypassing) Supabase key from the new key format —
 * `SUPABASE_SECRET_KEYS`, a JSON object of named secret keys Supabase auto-injects into every
 * Edge Function (replacing the legacy `SUPABASE_SERVICE_ROLE_KEY` plain-string env var, which
 * this project no longer reads). Never logged, never returned to any client.
 */
export function loadSupabaseSecretKey(): string {
  const raw = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (!raw) {
    throw new SafeError("Backend is misconfigured: SUPABASE_SECRET_KEYS is not set.");
  }
  let parsed: Record<string, string>;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new SafeError("Backend is misconfigured: SUPABASE_SECRET_KEYS is not valid JSON.");
  }
  const key = parsed.default;
  if (!key) {
    throw new SafeError('Backend is misconfigured: SUPABASE_SECRET_KEYS has no "default" entry.');
  }
  return key;
}

/**
 * The single place in this project that decides which Plaid environment every Edge Function
 * talks to. Controlled entirely by the `PLAID_ENV` Supabase Secret (`supabase secrets set
 * PLAID_ENV=sandbox|development|production`) — no other file, iOS or Edge Function, may hardcode
 * a `*.plaid.com` host or branch on environment name. Changing environments is a one-secret
 * change.
 *
 * All three environments are live/usable (see `PLAID_BASE_URLS` above for why `development` and
 * `production` currently resolve to the same host — Plaid retired the separate development
 * host). `PLAID_ENV` is never defaulted to anything other than the pre-existing `"sandbox"`
 * fallback below when unset, and an unrecognized value still fails closed rather than silently
 * picking an environment.
 */
export function loadPlaidCredentials(): PlaidCredentials {
  const clientId = Deno.env.get("PLAID_CLIENT_ID");
  const secret = Deno.env.get("PLAID_SECRET");
  const envRaw = Deno.env.get("PLAID_ENV") ?? "sandbox";

  if (!clientId || !secret) {
    throw new Error("PLAID_CLIENT_ID and PLAID_SECRET must be set (supabase secrets set ...)");
  }

  if (!isPlaidEnvironment(envRaw)) {
    throw new Error(
      `PLAID_ENV must be one of "sandbox", "development", "production" (got "${envRaw}")`,
    );
  }

  return { clientId, secret, baseUrl: PLAID_BASE_URLS[envRaw], environment: envRaw };
}

// ---------------------------------------------------------------------------------------------
// Per-Item environment consistency (used by every function that calls Plaid with an EXISTING
// Item's stored access_token)
// ---------------------------------------------------------------------------------------------
//
// A plaid_items row's access_token is only ever valid against the Plaid host it was originally
// issued under (see migration 0005_plaid_items_environment.sql). If the server's active PLAID_ENV
// ever differs from the environment a given Item was created under — e.g. a Sandbox-created Item
// still on file while PLAID_ENV is now "production" — calling Plaid with that token against the
// CURRENT host would be wrong: at best a confusing failure, at worst a stale token happening to
// still resolve to something. Every function that loads an existing Item's access_token must
// check this BEFORE calling Plaid, never after.

/**
 * Thrown when a `plaid_items` row's stored `environment` doesn't match the server's currently
 * active `PLAID_ENV`. The message only ever contains environment LABELS ("sandbox",
 * "development", "production"), never a secret or token value — safe to log and safe to return
 * to the client as-is.
 */
export class EnvironmentMismatchError extends SafeError {
  constructor(itemEnvironment: string, activeEnvironment: string) {
    super(
      `This connection was created under a different Plaid environment (item="${itemEnvironment}", active="${activeEnvironment}") and must be reconnected.`,
    );
  }
}

/**
 * Throws `EnvironmentMismatchError` if `itemEnvironment` doesn't match the server's currently
 * active Plaid environment (read via `loadPlaidCredentials()`, the same single source of truth
 * every Plaid call already goes through). Callers must call this BEFORE `plaidFetch`/
 * `refreshPlaidAccounts` for any Item loaded from `plaid_items`, never after.
 */
export function assertItemEnvironmentMatches(itemEnvironment: string | null): void {
  const { environment: activeEnvironment } = loadPlaidCredentials();
  if (itemEnvironment !== activeEnvironment) {
    throw new EnvironmentMismatchError(itemEnvironment ?? "unknown", activeEnvironment);
  }
}

/**
 * True when the server's active `PLAID_ENV` is `"sandbox"` (or unset, which defaults to
 * sandbox). Used by `debug-reset-cursor`'s server-side gate — extracted as a small, independently
 * testable helper rather than left inlined, so that guard can be verified without invoking a full
 * `Deno.serve` handler. Deliberately reads the raw env var directly rather than going through
 * `loadPlaidCredentials()`, so this still evaluates correctly even when `PLAID_CLIENT_ID`/
 * `PLAID_SECRET` aren't set — this check must run before those become relevant.
 */
export function isSandboxEnvironment(): boolean {
  return (Deno.env.get("PLAID_ENV") ?? "sandbox") === "sandbox";
}

// ---------------------------------------------------------------------------------------------
// Webhook URL (used by create-link-token)
// ---------------------------------------------------------------------------------------------

/**
 * Builds the trusted webhook URL for this project's `plaid-webhook` Edge Function, from the
 * server-side `SUPABASE_URL` secret — never hardcoded, never client-supplied. Plaid POSTs
 * Item-state changes here once it's passed as `/link/token/create`'s `webhook` field (see
 * plaid-webhook/index.ts). Normalizes any trailing slash(es) on `SUPABASE_URL` so the result is
 * always a well-formed URL regardless of how the secret happens to be set.
 */
export function buildPlaidWebhookUrl(): string {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  if (!supabaseUrl) {
    throw new SafeError("Backend is misconfigured: SUPABASE_URL must be set.");
  }
  return `${supabaseUrl.replace(/\/+$/, "")}/functions/v1/plaid-webhook`;
}

export async function plaidFetch(
  path: string,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const { clientId, secret, baseUrl } = loadPlaidCredentials();

  const response = await fetch(`${baseUrl}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ client_id: clientId, secret, ...body }),
  });

  const data = await response.json();
  if (!response.ok) {
    throw new PlaidRequestError(response.status, data);
  }
  return data;
}

export class PlaidRequestError extends Error {
  status: number;
  body: unknown;
  constructor(status: number, body: unknown) {
    super(`Plaid request failed with status ${status}`);
    this.status = status;
    this.body = body;
  }
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------------------------
// Plaid account discovery (used by exchange-public-token, sync-balances, refresh-plaid-accounts)
// ---------------------------------------------------------------------------------------------
//
// ONE place that calls /accounts/get and reconciles the result into plaid_accounts — every
// function that needs account/balance data goes through this instead of hand-rolling its own
// mapping+upsert (three call sites is exactly the situation where copy-pasted account-mapping
// logic would drift out of sync with itself; see the multi-institution architecture work's own
// finding that the reconnect flow originally never called this at all).

export interface PlaidAccountRow {
  plaid_item_id: string;
  account_id: string;
  name: string | null;
  official_name: string | null;
  mask: string | null;
  type: string | null;
  subtype: string | null;
  current_balance: number | null;
  available_balance: number | null;
  credit_limit: number | null;
  iso_currency_code: string | null;
  unofficial_currency_code: string | null;
  is_active: boolean;
  removed_at: string | null;
  updated_at: string;
}

/**
 * Fetches every account Plaid currently reports for one Item (`/accounts/get`), upserts each
 * into `plaid_accounts` (update in place if already known, insert if new, REACTIVATE — clear
 * `is_active`/`removed_at` — if it was previously soft-deleted and just reappeared), and
 * soft-deletes (`is_active = false, removed_at = now`) any row this Item previously had that
 * Plaid's response no longer includes.
 *
 * Soft-delete, not hard-delete: chosen because `FinanceTransaction.plaidAccountId` on the iOS
 * side can reference a Plaid account_id indefinitely (transactions are never purged just because
 * their account closed) — hard-deleting the `plaid_accounts` row would orphan that reference for
 * no benefit, since nothing here reads `plaid_accounts` to validate a transaction. See migration
 * `0004_plaid_accounts_balance_fields.sql`.
 *
 * The soft-delete reconciliation only ever runs after the upsert above has fully succeeded — a
 * failed/partial `/accounts/get` call throws before reaching it, so a transient Plaid error can
 * never be misread as "this account no longer exists" and incorrectly deactivate it.
 *
 * `accountId` uniqueness is scoped to `(plaid_item_id, account_id)`, never `account_id` alone —
 * Plaid documents `account_id` as unique only WITHIN an Item, not globally (see migration 0004's
 * comment for the exact quoted guarantee), so `onConflict` matches that composite key.
 *
 * Callers are responsible for everything OUTSIDE account data itself — clearing
 * `plaid_items.requires_reauth`/`new_accounts_available`, refreshing balances, syncing
 * transactions — this function's only job is accounts.
 */
export async function refreshPlaidAccounts(
  supabase: SupabaseClient,
  plaidItemId: string,
  accessToken: string,
): Promise<PlaidAccountRow[]> {
  const accountsData = await plaidFetch("/accounts/get", { access_token: accessToken });
  const accounts = (accountsData.accounts as Record<string, unknown>[] | undefined) ?? [];
  const nowIso = new Date().toISOString();

  const rows: PlaidAccountRow[] = accounts.map((account) => {
    const balances = (account.balances as Record<string, unknown> | undefined) ?? {};
    return {
      plaid_item_id: plaidItemId,
      account_id: account.account_id as string,
      name: (account.name as string | undefined) ?? null,
      official_name: (account.official_name as string | undefined) ?? null,
      mask: (account.mask as string | undefined) ?? null,
      type: (account.type as string | undefined) ?? null,
      subtype: (account.subtype as string | undefined) ?? null,
      current_balance: (balances.current as number | undefined) ?? null,
      available_balance: (balances.available as number | undefined) ?? null,
      credit_limit: (balances.limit as number | undefined) ?? null,
      iso_currency_code: (balances.iso_currency_code as string | undefined) ?? null,
      unofficial_currency_code: (balances.unofficial_currency_code as string | undefined) ?? null,
      // Every row in THIS response is, by definition, currently reported by Plaid — reactivates
      // a previously soft-deleted account_id that has reappeared, and is a no-op for one that was
      // already active.
      is_active: true,
      removed_at: null,
      updated_at: nowIso,
    };
  });

  if (rows.length > 0) {
    const { error: upsertError } = await supabase
      .from("plaid_accounts")
      .upsert(rows, { onConflict: "plaid_item_id,account_id" });
    if (upsertError) throw upsertError;
  }

  const seenAccountIds = new Set(rows.map((row) => row.account_id));
  const { data: previouslyActive, error: previouslyActiveError } = await supabase
    .from("plaid_accounts")
    .select("account_id")
    .eq("plaid_item_id", plaidItemId)
    .eq("is_active", true);
  if (previouslyActiveError) throw previouslyActiveError;

  const staleAccountIds = (previouslyActive ?? [])
    .map((row) => row.account_id as string)
    .filter((accountId) => !seenAccountIds.has(accountId));

  if (staleAccountIds.length > 0) {
    const { error: deactivateError } = await supabase
      .from("plaid_accounts")
      .update({ is_active: false, removed_at: nowIso })
      .eq("plaid_item_id", plaidItemId)
      .in("account_id", staleAccountIds);
    if (deactivateError) throw deactivateError;
  }

  return rows;
}

// ---------------------------------------------------------------------------------------------
// Plaid webhook signature verification (used by plaid-webhook/index.ts)
// ---------------------------------------------------------------------------------------------
//
// Plaid signs every webhook with a JWT in the `Plaid-Verification` header (ES256 — ECDSA over
// P-256/SHA-256). This is the ONLY thing standing between "a real Plaid webhook" and "anyone who
// finds this URL and POSTs a fake ITEM_LOGIN_REQUIRED to make the app nag a user to reconnect, or
// a fake NEW_ACCOUNTS_AVAILABLE" — there is no other auth on this endpoint (see plaid-webhook's
// own file header for why it can't use requireAuthenticatedUserId). Verification, per Plaid's
// documented webhook-verification flow:
//   1. Decode the JWT header (unverified) to read its `kid`.
//   2. Fetch that key from Plaid's own `/webhook_verification_key/get` (cached in-memory per
//      Edge Function instance — the same kid is reused across many webhooks).
//   3. Import it as a P-256 public key and verify the JWT's ES256 signature against it.
//   4. Check the JWT is fresh (`iat` within 5 minutes) — an old, previously-valid JWT replayed
//      later must not be accepted.
//   5. Check the JWT's `request_body_sha256` claim matches a SHA-256 of the ACTUAL raw request
//      body this call received — this is what stops a valid-but-unrelated Plaid webhook JWT (for
//      a different event) from being replayed against a different payload.

const MAX_WEBHOOK_AGE_SECONDS = 5 * 60;

interface CachedVerificationKey {
  jwk: JsonWebKey;
  cryptoKey: CryptoKey;
}

// Per-instance cache only (Edge Function instances are ephemeral and stateless across cold
// starts) — never persisted, never shared across instances. Worst case on a cache miss is one
// extra call to Plaid per new instance/new kid, never a correctness issue.
const verificationKeyCache = new Map<string, CachedVerificationKey>();

function base64UrlDecode(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(value.length + ((4 - (value.length % 4)) % 4), "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

async function sha256Hex(data: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(data));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function loadVerificationKey(keyId: string): Promise<CachedVerificationKey | null> {
  const cached = verificationKeyCache.get(keyId);
  if (cached) return cached;

  const response = await plaidFetch("/webhook_verification_key/get", { key_id: keyId });
  const jwk = response.key as (JsonWebKey & { expired_at?: string | null }) | undefined;
  if (!jwk || jwk.expired_at) {
    // Missing or explicitly expired — never cache, never treat as valid.
    return null;
  }

  const cryptoKey = await crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  const entry: CachedVerificationKey = { jwk, cryptoKey };
  verificationKeyCache.set(keyId, entry);
  return entry;
}

/**
 * Verifies that `rawBody` genuinely came from Plaid, signed by the JWT in the request's
 * `Plaid-Verification` header. MUST be called with the exact, unparsed request body text (not a
 * re-serialized `JSON.stringify` of the parsed object — Plaid signs the literal bytes it sent,
 * and re-serializing can reorder keys/whitespace and break the hash check even for a genuine
 * webhook). Returns `false` for any failure (missing header, malformed JWT, unknown/expired key,
 * bad signature, stale timestamp, body hash mismatch) — callers must reject the request on any
 * `false`, never partially trust it.
 */
export async function verifyPlaidWebhookSignature(req: Request, rawBody: string): Promise<boolean> {
  const jwt = req.headers.get("Plaid-Verification");
  if (!jwt) return false;

  const parts = jwt.split(".");
  if (parts.length !== 3) return false;
  const [headerPart, payloadPart, signaturePart] = parts;

  let header: { alg?: string; kid?: string };
  let payload: { iat?: number; request_body_sha256?: string };
  try {
    header = JSON.parse(new TextDecoder().decode(base64UrlDecode(headerPart)));
    payload = JSON.parse(new TextDecoder().decode(base64UrlDecode(payloadPart)));
  } catch {
    return false;
  }

  if (header.alg !== "ES256" || !header.kid) return false;

  const key = await loadVerificationKey(header.kid);
  if (!key) return false;

  const signature = base64UrlDecode(signaturePart);
  const signingInput = new TextEncoder().encode(`${headerPart}.${payloadPart}`);
  const signatureValid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key.cryptoKey,
    signature,
    signingInput,
  );
  if (!signatureValid) return false;

  if (typeof payload.iat !== "number") return false;
  const ageSeconds = Math.abs(Date.now() / 1000 - payload.iat);
  if (ageSeconds > MAX_WEBHOOK_AGE_SECONDS) return false;

  if (typeof payload.request_body_sha256 !== "string") return false;
  const actualBodyHash = await sha256Hex(rawBody);
  // Constant-time comparison, per Plaid's own webhook-verification guidance — a plain `!==` on
  // the two hex strings would short-circuit at the first differing character, which is a (very
  // impractical over HTTP, but still a documented best-practice violation) timing side channel.
  if (!constantTimeEquals(actualBodyHash, payload.request_body_sha256)) return false;

  return true;
}

function constantTimeEquals(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) {
    mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return mismatch === 0;
}
