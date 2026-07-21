// Focused regression tests for the pure/deterministic pieces of ../_shared/plaid.ts added or
// changed for Plaid Production preparation (Phase P1A/P1A.1) and OAuth Universal Link support
// (Phase P1B): environment loading (including the now-unblocked "production" case and the
// fail-closed correction — no implicit Sandbox fallback), per-Item environment consistency,
// webhook URL construction, the OAuth redirect URI constant, and the extracted sandbox-only gate
// used by debug-reset-cursor.
//
// Deliberately does NOT test anything that requires a live Supabase/Postgres connection or a
// live Plaid API call (createPrivilegedClient, refreshPlaidAccounts, requireAuthenticatedUserId,
// plaidFetch) — those need real infrastructure this repo's test setup doesn't provide, and are
// covered instead by direct code review (see the accompanying audit report). This also includes
// whether create-link-token's request bodies include `redirect_uri`/`webhook` — that construction
// happens inline inside a `Deno.serve` handler, not a pure exported function, so it is verified by
// code review rather than a unit test, matching how `webhook` itself was already verified. Every
// test here exercises pure functions of environment variables/string inputs only.
//
// Also covers the duplicate-Item detection helper (computeDuplicateInstitutionResult), the Link
// conversion logging shape (buildLinkTokenCreatedLogFields), Plaid request_id capture
// (PlaidRequestError/plaidFetch), and the structured operation-logging helpers
// (buildPlaidOperationLogFields/logPlaidOperation) added for the "Logging" onboarding item.
//
// Run with: deno test --allow-env supabase/functions/_shared/plaid.test.ts

import { assert, assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import {
  assertItemEnvironmentMatches,
  buildLinkTokenCreatedLogFields,
  buildNormalizedTransactionRows,
  buildPlaidOperationLogFields,
  buildPlaidWebhookUrl,
  computeDuplicateInstitutionResult,
  EnvironmentMismatchError,
  isSandboxEnvironment,
  loadPlaidCredentials,
  logPlaidOperation,
  logSafeError,
  mapPlaidTransactionToNormalizedRow,
  PLAID_OAUTH_REDIRECT_URI,
  plaidFetch,
  PlaidRequestError,
} from "./plaid.ts";

const ENV_KEYS = ["PLAID_CLIENT_ID", "PLAID_SECRET", "PLAID_ENV", "SUPABASE_URL"] as const;

/** Runs `fn` with `overrides` applied to `Deno.env`, restoring every touched key afterward
 * (deleting it if it wasn't previously set) — so tests never leak env state into one another or
 * into whatever real secrets happen to be present in the process running `deno test`. */
function withEnv<T>(overrides: Partial<Record<(typeof ENV_KEYS)[number], string | undefined>>, fn: () => T): T {
  const previous = new Map<string, string | undefined>();
  for (const key of ENV_KEYS) {
    previous.set(key, Deno.env.get(key));
  }
  try {
    for (const key of ENV_KEYS) {
      const value = overrides[key];
      if (value === undefined) {
        Deno.env.delete(key);
      } else {
        Deno.env.set(key, value);
      }
    }
    return fn();
  } finally {
    for (const key of ENV_KEYS) {
      const value = previous.get(key);
      if (value === undefined) {
        Deno.env.delete(key);
      } else {
        Deno.env.set(key, value);
      }
    }
  }
}

const VALID_CREDS = { PLAID_CLIENT_ID: "test-client-id", PLAID_SECRET: "test-secret" };

// --- loadPlaidCredentials: each environment loads successfully ---------------------------------

Deno.test("loadPlaidCredentials: sandbox credentials load successfully", () => {
  withEnv({ ...VALID_CREDS, PLAID_ENV: "sandbox" }, () => {
    const creds = loadPlaidCredentials();
    assertEquals(creds.environment, "sandbox");
    assertEquals(creds.baseUrl, "https://sandbox.plaid.com");
    assertEquals(creds.clientId, "test-client-id");
    assertEquals(creds.secret, "test-secret");
  });
});

Deno.test("loadPlaidCredentials: development credentials load successfully", () => {
  withEnv({ ...VALID_CREDS, PLAID_ENV: "development" }, () => {
    const creds = loadPlaidCredentials();
    assertEquals(creds.environment, "development");
    assertEquals(creds.baseUrl, "https://production.plaid.com");
  });
});

Deno.test("loadPlaidCredentials: production credentials now load successfully (previously blocked)", () => {
  withEnv({ ...VALID_CREDS, PLAID_ENV: "production" }, () => {
    const creds = loadPlaidCredentials();
    assertEquals(creds.environment, "production");
    assertEquals(creds.baseUrl, "https://production.plaid.com");
  });
});

// --- loadPlaidCredentials: still fails closed --------------------------------------------------

Deno.test("loadPlaidCredentials: missing PLAID_CLIENT_ID/PLAID_SECRET still throws", () => {
  withEnv({ PLAID_CLIENT_ID: undefined, PLAID_SECRET: undefined, PLAID_ENV: "sandbox" }, () => {
    assertThrows(() => loadPlaidCredentials(), Error, "PLAID_CLIENT_ID and PLAID_SECRET must be set");
  });
});

Deno.test("loadPlaidCredentials: unsupported PLAID_ENV value throws", () => {
  withEnv({ ...VALID_CREDS, PLAID_ENV: "staging" }, () => {
    assertThrows(() => loadPlaidCredentials(), Error, 'PLAID_ENV must be one of "sandbox", "development", "production"');
  });
});

Deno.test("loadPlaidCredentials: misspelled PLAID_ENV value throws", () => {
  withEnv({ ...VALID_CREDS, PLAID_ENV: "prod" }, () => {
    assertThrows(() => loadPlaidCredentials(), Error, 'PLAID_ENV must be one of "sandbox", "development", "production"');
  });
});

Deno.test("loadPlaidCredentials: empty-string PLAID_ENV throws (no implicit environment)", () => {
  withEnv({ ...VALID_CREDS, PLAID_ENV: "" }, () => {
    assertThrows(() => loadPlaidCredentials(), Error, "PLAID_ENV must be explicitly set");
  });
});

Deno.test("loadPlaidCredentials: whitespace-only PLAID_ENV throws (no implicit environment)", () => {
  withEnv({ ...VALID_CREDS, PLAID_ENV: "   " }, () => {
    assertThrows(() => loadPlaidCredentials(), Error, "PLAID_ENV must be explicitly set");
  });
});

Deno.test("loadPlaidCredentials: missing PLAID_ENV FAILS CLOSED — no fallback to sandbox or any other environment", () => {
  withEnv({ ...VALID_CREDS, PLAID_ENV: undefined }, () => {
    assertThrows(() => loadPlaidCredentials(), Error, "PLAID_ENV must be explicitly set");
  });
});

Deno.test("loadPlaidCredentials: leading/trailing whitespace around an otherwise-valid value is trimmed, not treated as invalid", () => {
  withEnv({ ...VALID_CREDS, PLAID_ENV: "  sandbox  " }, () => {
    assertEquals(loadPlaidCredentials().environment, "sandbox");
  });
});

// --- Base URL selection --------------------------------------------------------------------------

Deno.test("loadPlaidCredentials: base URL selection is sandbox vs. production-host for the other two", () => {
  withEnv({ ...VALID_CREDS, PLAID_ENV: "sandbox" }, () => {
    assertEquals(loadPlaidCredentials().baseUrl, "https://sandbox.plaid.com");
  });
  withEnv({ ...VALID_CREDS, PLAID_ENV: "development" }, () => {
    assertEquals(loadPlaidCredentials().baseUrl, "https://production.plaid.com");
  });
  withEnv({ ...VALID_CREDS, PLAID_ENV: "production" }, () => {
    assertEquals(loadPlaidCredentials().baseUrl, "https://production.plaid.com");
  });
});

// --- buildPlaidWebhookUrl -------------------------------------------------------------------------

Deno.test("buildPlaidWebhookUrl: forms correctly with no trailing slash on SUPABASE_URL", () => {
  withEnv({ SUPABASE_URL: "https://dlqjgpgnaguhubftfpel.supabase.co" }, () => {
    assertEquals(buildPlaidWebhookUrl(), "https://dlqjgpgnaguhubftfpel.supabase.co/functions/v1/plaid-webhook");
  });
});

Deno.test("buildPlaidWebhookUrl: forms correctly with a trailing slash on SUPABASE_URL", () => {
  withEnv({ SUPABASE_URL: "https://dlqjgpgnaguhubftfpel.supabase.co/" }, () => {
    assertEquals(buildPlaidWebhookUrl(), "https://dlqjgpgnaguhubftfpel.supabase.co/functions/v1/plaid-webhook");
  });
});

Deno.test("buildPlaidWebhookUrl: normalizes multiple trailing slashes", () => {
  withEnv({ SUPABASE_URL: "https://dlqjgpgnaguhubftfpel.supabase.co///" }, () => {
    assertEquals(buildPlaidWebhookUrl(), "https://dlqjgpgnaguhubftfpel.supabase.co/functions/v1/plaid-webhook");
  });
});

Deno.test("buildPlaidWebhookUrl: throws if SUPABASE_URL is unset", () => {
  withEnv({ SUPABASE_URL: undefined }, () => {
    assertThrows(() => buildPlaidWebhookUrl(), Error, "SUPABASE_URL must be set");
  });
});

// --- assertItemEnvironmentMatches -----------------------------------------------------------------

Deno.test("assertItemEnvironmentMatches: accepts a matching Item/server environment", () => {
  withEnv({ ...VALID_CREDS, PLAID_ENV: "sandbox" }, () => {
    // Must not throw.
    assertItemEnvironmentMatches("sandbox");
  });
});

Deno.test("assertItemEnvironmentMatches: rejects a mismatched Item/server environment before any Plaid request", () => {
  withEnv({ ...VALID_CREDS, PLAID_ENV: "production" }, () => {
    const error = assertThrows(
      () => assertItemEnvironmentMatches("sandbox"),
      EnvironmentMismatchError,
    );
    // The message may only ever contain environment labels — never a secret/token value.
    assert(error.message.includes("sandbox"));
    assert(error.message.includes("production"));
    assert(!error.message.includes("test-secret"));
    assert(!error.message.includes("test-client-id"));
  });
});

Deno.test("assertItemEnvironmentMatches: treats a null stored environment as a mismatch, never a silent pass", () => {
  withEnv({ ...VALID_CREDS, PLAID_ENV: "sandbox" }, () => {
    const error = assertThrows(() => assertItemEnvironmentMatches(null), EnvironmentMismatchError);
    assert(error.message.includes("unknown"));
  });
});

// --- isSandboxEnvironment (debug-reset-cursor's guard) --------------------------------------------

Deno.test("isSandboxEnvironment: true when PLAID_ENV is sandbox", () => {
  withEnv({ PLAID_ENV: "sandbox" }, () => {
    assertEquals(isSandboxEnvironment(), true);
  });
});

Deno.test("isSandboxEnvironment: true when PLAID_ENV has surrounding whitespace around sandbox", () => {
  withEnv({ PLAID_ENV: "  sandbox  " }, () => {
    assertEquals(isSandboxEnvironment(), true);
  });
});

Deno.test("isSandboxEnvironment: FAILS CLOSED — false (never true) when PLAID_ENV is unset", () => {
  withEnv({ PLAID_ENV: undefined }, () => {
    assertEquals(isSandboxEnvironment(), false);
  });
});

Deno.test("isSandboxEnvironment: FAILS CLOSED — false when PLAID_ENV is empty", () => {
  withEnv({ PLAID_ENV: "" }, () => {
    assertEquals(isSandboxEnvironment(), false);
  });
});

Deno.test("isSandboxEnvironment: FAILS CLOSED — false when PLAID_ENV is whitespace-only", () => {
  withEnv({ PLAID_ENV: "   " }, () => {
    assertEquals(isSandboxEnvironment(), false);
  });
});

Deno.test("isSandboxEnvironment: false when PLAID_ENV is development — debug-reset-cursor cannot reset a Development cursor", () => {
  withEnv({ PLAID_ENV: "development" }, () => {
    assertEquals(isSandboxEnvironment(), false);
  });
});

Deno.test("isSandboxEnvironment: false when PLAID_ENV is production — debug-reset-cursor cannot reset a Production cursor", () => {
  withEnv({ PLAID_ENV: "production" }, () => {
    assertEquals(isSandboxEnvironment(), false);
  });
});

Deno.test("isSandboxEnvironment: false for a misspelled value — never falls back to true", () => {
  withEnv({ PLAID_ENV: "Sandbox" }, () => {
    assertEquals(isSandboxEnvironment(), false);
  });
});

// --- PLAID_OAUTH_REDIRECT_URI (Phase P1B, host moved to Cloudflare subdomain in P1B.1) ---------

Deno.test("PLAID_OAUTH_REDIRECT_URI: is the exact approved Cloudflare-subdomain Universal Link", () => {
  assertEquals(PLAID_OAUTH_REDIRECT_URI, "https://plaid.sldevapps.com/spendsmart/plaid/");
});

Deno.test("PLAID_OAUTH_REDIRECT_URI: is HTTPS, never a custom scheme", () => {
  assert(PLAID_OAUTH_REDIRECT_URI.startsWith("https://"));
});

Deno.test("PLAID_OAUTH_REDIRECT_URI: no longer uses the old root-domain host", () => {
  assert(!PLAID_OAUTH_REDIRECT_URI.startsWith("https://sldevapps.com"));
});

Deno.test("PLAID_OAUTH_REDIRECT_URI: is not the spendsmart:// Supabase auth callback scheme", () => {
  assert(!PLAID_OAUTH_REDIRECT_URI.startsWith("spendsmart://"));
});

// --- computeDuplicateInstitutionResult (exchange-public-token duplicate-Item detection) --------

Deno.test("computeDuplicateInstitutionResult: no matches means no duplicate institution", () => {
  const result = computeDuplicateInstitutionResult([]);
  assertEquals(result, {
    duplicate_institution: false,
    existing_connection_id: null,
    existing_institution_name: null,
  });
});

Deno.test("computeDuplicateInstitutionResult: one match means duplicate detected, surfacing its id and name", () => {
  const result = computeDuplicateInstitutionResult([{ id: "existing-conn-1", institution_name: "Some Bank" }]);
  assertEquals(result, {
    duplicate_institution: true,
    existing_connection_id: "existing-conn-1",
    existing_institution_name: "Some Bank",
  });
});

Deno.test("computeDuplicateInstitutionResult: never blocks — always returns metadata, never throws", () => {
  // Plaid's own guidance is to warn the user, never to make a second legitimate Item at the same
  // institution impossible — this function has no error/rejection path at all, by construction.
  const result = computeDuplicateInstitutionResult([{ id: "existing-conn-1", institution_name: "Some Bank" }]);
  assertEquals(typeof result, "object");
  assertEquals(result.duplicate_institution, true);
});

Deno.test("computeDuplicateInstitutionResult: multiple matches still surface exactly one existing connection (the first)", () => {
  const result = computeDuplicateInstitutionResult([
    { id: "existing-conn-1", institution_name: "Some Bank" },
    { id: "existing-conn-2", institution_name: "Some Bank" },
  ]);
  assertEquals(result.existing_connection_id, "existing-conn-1");
});

Deno.test("computeDuplicateInstitutionResult: never echoes any field beyond id/institution_name (no access_token/item_id leakage)", () => {
  const result = computeDuplicateInstitutionResult([{ id: "existing-conn-1", institution_name: "Some Bank" }]);
  const keys = Object.keys(result).sort();
  assertEquals(keys, ["duplicate_institution", "existing_connection_id", "existing_institution_name"]);
  assert(!("access_token" in result));
  assert(!("item_id" in result));
});

// --- buildLinkTokenCreatedLogFields (create-link-token's Link conversion logging) ----------------

Deno.test("buildLinkTokenCreatedLogFields: update mode is labeled update_mode", () => {
  const fields = buildLinkTokenCreatedLogFields(true, "sandbox", true, true);
  assertEquals(fields.mode, "update_mode");
});

Deno.test("buildLinkTokenCreatedLogFields: new connection is labeled new_connection", () => {
  const fields = buildLinkTokenCreatedLogFields(false, "sandbox", true, true);
  assertEquals(fields.mode, "new_connection");
});

Deno.test("buildLinkTokenCreatedLogFields: carries the given environment, webhook, and redirect_uri flags", () => {
  const fields = buildLinkTokenCreatedLogFields(false, "production", true, true);
  assertEquals(fields.environment, "production");
  assertEquals(fields.webhook_included, true);
  assertEquals(fields.redirect_uri_included, true);
});

Deno.test("buildLinkTokenCreatedLogFields: never includes a token/credential field of any kind", () => {
  const fields = buildLinkTokenCreatedLogFields(true, "sandbox", true, true);
  const keys = Object.keys(fields).sort();
  assertEquals(keys, ["environment", "mode", "redirect_uri_included", "webhook_included"]);
  assert(!("link_token" in fields));
  assert(!("access_token" in fields));
  assert(!("client_secret" in fields));
});

// --- Plaid request_id capture (plaidFetch / PlaidRequestError) -----------------------------------
//
// plaidFetch itself makes a live HTTP call — rather than skip request_id capture entirely (as the
// file header above says for plaidFetch's happy path), these tests stub `globalThis.fetch` for
// the duration of one call so the FAILURE path (the only path that constructs PlaidRequestError)
// is exercised deterministically, without a live Plaid API call. `withEnv` above is
// deliberately NOT reused here — it is synchronous (`fn: () => T`) and restores env vars via a
// `finally` that runs before an async `fn`'s internal `await`s resolve, which would silently
// restore the environment mid-request. `withEnvAsync` awaits `fn()` before restoring, so this
// stays test-isolated for genuinely async bodies.

async function withEnvAsync<T>(
  overrides: Partial<Record<(typeof ENV_KEYS)[number], string | undefined>>,
  fn: () => Promise<T>,
): Promise<T> {
  const previous = new Map<string, string | undefined>();
  for (const key of ENV_KEYS) {
    previous.set(key, Deno.env.get(key));
  }
  try {
    for (const key of ENV_KEYS) {
      const value = overrides[key];
      if (value === undefined) {
        Deno.env.delete(key);
      } else {
        Deno.env.set(key, value);
      }
    }
    return await fn();
  } finally {
    for (const key of ENV_KEYS) {
      const value = previous.get(key);
      if (value === undefined) {
        Deno.env.delete(key);
      } else {
        Deno.env.set(key, value);
      }
    }
  }
}

/** Replaces `globalThis.fetch` with one that always resolves to `response`, for the duration of
 * `fn` only — restored in `finally` even if `fn` throws/rejects, so a failing assertion in one
 * test can never leave a later test talking to a stubbed fetch. */
async function withStubbedFetch<T>(response: Response, fn: () => Promise<T>): Promise<T> {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (() => Promise.resolve(response)) as typeof fetch;
  try {
    return await fn();
  } finally {
    globalThis.fetch = originalFetch;
  }
}

Deno.test("plaidFetch: PlaidRequestError captures request_id from the JSON response body", async () => {
  await withEnvAsync({ ...VALID_CREDS, PLAID_ENV: "sandbox" }, async () => {
    const response = new Response(
      JSON.stringify({ error_code: "INVALID_REQUEST", request_id: "req-from-body" }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
    await withStubbedFetch(response, async () => {
      const error = await assertRejects(() => plaidFetch("/test", {}), PlaidRequestError);
      assertEquals(error.status, 400);
      assertEquals(error.requestId, "req-from-body");
    });
  });
});

Deno.test("plaidFetch: PlaidRequestError captures request_id from the x-request-id header when the body omits it", async () => {
  await withEnvAsync({ ...VALID_CREDS, PLAID_ENV: "sandbox" }, async () => {
    const response = new Response(JSON.stringify({ error_code: "INVALID_REQUEST" }), {
      status: 500,
      headers: { "Content-Type": "application/json", "x-request-id": "req-from-header" },
    });
    await withStubbedFetch(response, async () => {
      const error = await assertRejects(() => plaidFetch("/test", {}), PlaidRequestError);
      assertEquals(error.requestId, "req-from-header");
    });
  });
});

Deno.test("plaidFetch: PlaidRequestError.requestId is safely undefined when Plaid supplies no request_id anywhere", async () => {
  await withEnvAsync({ ...VALID_CREDS, PLAID_ENV: "sandbox" }, async () => {
    const response = new Response(JSON.stringify({ error_code: "INVALID_REQUEST" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
    await withStubbedFetch(response, async () => {
      const error = await assertRejects(() => plaidFetch("/test", {}), PlaidRequestError);
      assertEquals(error.requestId, undefined);
    });
  });
});

Deno.test("PlaidRequestError: constructor retains status and requestId exactly as given", () => {
  const error = new PlaidRequestError(401, { some: "body" }, "req-abc");
  assertEquals(error.status, 401);
  assertEquals(error.requestId, "req-abc");
  assertEquals(error.body, { some: "body" });
});

Deno.test("PlaidRequestError: requestId defaults to undefined when not passed", () => {
  const error = new PlaidRequestError(500, {});
  assertEquals(error.requestId, undefined);
});

// --- logSafeError safety (status + request_id only, never the response body or a token) --------

/** Captures every `console.error` call made during `fn`, restoring the original afterward even
 * if `fn` throws — so a failing assertion never leaves later tests silently swallowing logs. */
function captureConsoleError<T>(fn: () => T): { result: T; calls: unknown[][] } {
  const original = console.error;
  const calls: unknown[][] = [];
  console.error = (...args: unknown[]) => {
    calls.push(args);
  };
  try {
    const result = fn();
    return { result, calls };
  } finally {
    console.error = original;
  }
}

Deno.test("logSafeError: PlaidRequestError logs status and request_id, never the response body", () => {
  const error = new PlaidRequestError(
    400,
    { access_token: "access-sandbox-should-never-leak", error_code: "INVALID_REQUEST" },
    "req-123",
  );
  const { calls } = captureConsoleError(() => logSafeError("test context", error));
  assertEquals(calls.length, 1);
  assertEquals(calls[0][0], "test context: Plaid request failed");
  assertEquals(calls[0][1], { status: 400, request_id: "req-123" });
  const serialized = JSON.stringify(calls[0]);
  assert(!serialized.includes("access-sandbox-should-never-leak"));
});

Deno.test("logSafeError: PlaidRequestError with no requestId logs request_id: null, never throws", () => {
  const error = new PlaidRequestError(500, { anything: "here" });
  const { calls } = captureConsoleError(() => logSafeError("ctx", error));
  assertEquals(calls[0][1], { status: 500, request_id: null });
});

// --- buildPlaidOperationLogFields / logPlaidOperation (structured operation logging) -------------

Deno.test("buildPlaidOperationLogFields: returns exactly the approved closed set of keys when every field is supplied", () => {
  const fields = buildPlaidOperationLogFields({
    operation: "test-op",
    outcome: "success",
    environment: "sandbox",
    connectionId: "conn-1",
    itemId: "item-1",
    requestId: "req-1",
    institutionId: "ins-1",
    webhookType: "ITEM",
    webhookCode: "ITEM_LOGIN_REQUIRED",
    accountCount: 3,
    addedCount: 1,
    modifiedCount: 2,
    removedCount: 0,
    mode: "new_connection",
  });
  const keys = Object.keys(fields).sort();
  assertEquals(
    keys,
    [
      "accountCount",
      "addedCount",
      "connectionId",
      "environment",
      "institutionId",
      "itemId",
      "mode",
      "modifiedCount",
      "operation",
      "outcome",
      "removedCount",
      "requestId",
      "webhookCode",
      "webhookType",
    ].sort(),
  );
});

Deno.test("buildPlaidOperationLogFields: never carries a token/secret/PII field, even with minimal input", () => {
  const fields = buildPlaidOperationLogFields({ operation: "x", outcome: "failure" });
  assert(!("access_token" in fields));
  assert(!("public_token" in fields));
  assert(!("link_token" in fields));
  assert(!("PLAID_SECRET" in fields));
  assert(!("user_id" in fields));
  assert(!("body" in fields));
  assert(!("response" in fields));
});

/** Captures every `console.log` call made during `fn`, same isolation guarantee as
 * `captureConsoleError` above. */
function captureConsoleLog<T>(fn: () => T): { result: T; calls: unknown[][] } {
  const original = console.log;
  const calls: unknown[][] = [];
  console.log = (...args: unknown[]) => {
    calls.push(args);
  };
  try {
    const result = fn();
    return { result, calls };
  } finally {
    console.log = original;
  }
}

Deno.test("logPlaidOperation: logged output never contains a token/secret/user-id/raw-body field", () => {
  const { calls } = captureConsoleLog(() =>
    logPlaidOperation({
      operation: "exchange-public-token",
      outcome: "success",
      connectionId: "conn-1",
      itemId: "item-1",
      requestId: "req-1",
    })
  );
  assertEquals(calls.length, 1);
  assertEquals(calls[0][0], "[exchange-public-token] operation outcome:");
  const serialized = JSON.stringify(calls[0]);
  for (const banned of ["access_token", "public_token", "link_token", "PLAID_SECRET", "user_id", "\"body\""]) {
    assert(!serialized.includes(banned), `logPlaidOperation output must never contain "${banned}"`);
  }
});

// -------------------------------------------------------------------------------------------
// PHASE 4 — normalized Plaid transaction persistence (mapPlaidTransactionToNormalizedRow /
// buildNormalizedTransactionRows), see migration 0010_plaid_transactions_normalized.sql. Pure
// mapping only, verified here without any live Supabase/Postgres call — the actual upsert/delete
// against public.plaid_transactions is verified by code review (sync-transactions/index.ts),
// matching this file's own established testing philosophy (see this file's header comment).
// -------------------------------------------------------------------------------------------

const RAW_MCDONALDS_PENDING = {
  transaction_id: "txn-mcdonalds-pending",
  pending_transaction_id: null,
  account_id: "plaid-account-amex-1",
  amount: 9.5,
  merchant_name: "MCDONALDS",
  name: "MCDONALDS",
  authorized_date: "2026-07-18",
  date: "2026-07-18",
  pending: true,
};

Deno.test("mapPlaidTransactionToNormalizedRow: maps every field to the exact normalized row shape", () => {
  const row = mapPlaidTransactionToNormalizedRow(
    RAW_MCDONALDS_PENDING,
    "resolved-plaid-account-uuid",
    "owner-uuid",
    "2026-07-18T12:00:00.000Z",
  );
  assertEquals(row, {
    plaid_account_id: "resolved-plaid-account-uuid",
    owner_user_id: "owner-uuid",
    transaction_id: "txn-mcdonalds-pending",
    pending_transaction_id: null,
    original_description: "MCDONALDS",
    merchant_name: "MCDONALDS",
    amount: 9.5,
    authorized_date: "2026-07-18",
    posted_date: "2026-07-18",
    is_pending: true,
    updated_at: "2026-07-18T12:00:00.000Z",
  });
});

Deno.test("mapPlaidTransactionToNormalizedRow: bare Plaid date strings pass through completely unparsed — no UTC-midnight shift is even possible here", () => {
  const row = mapPlaidTransactionToNormalizedRow(
    { ...RAW_MCDONALDS_PENDING, authorized_date: "2026-07-18", date: "2026-07-18" },
    "acct",
    "owner",
    "now",
  );
  assertEquals(row.authorized_date, "2026-07-18", "must be the exact literal string Plaid sent, never reconstructed through any Date/instant type");
  assertEquals(row.posted_date, "2026-07-18");
});

Deno.test("mapPlaidTransactionToNormalizedRow: a pending transaction's date mirrors authorized_date, matching Plaid's own documented semantics", () => {
  const row = mapPlaidTransactionToNormalizedRow(RAW_MCDONALDS_PENDING, "acct", "owner", "now");
  assertEquals(row.is_pending, true);
  assertEquals(row.authorized_date, row.posted_date, "while pending, Plaid's own `date` field mirrors `authorized_date` — both must carry the same calendar day");
});

Deno.test("mapPlaidTransactionToNormalizedRow: a posted transaction's posted_date is Plaid's own authoritative date, independent of authorized_date", () => {
  const posted = {
    ...RAW_MCDONALDS_PENDING,
    transaction_id: "txn-mcdonalds-posted",
    pending: false,
    authorized_date: "2026-07-18",
    date: "2026-07-19", // posted a day later than authorized, a real-world case Plaid supports
  };
  const row = mapPlaidTransactionToNormalizedRow(posted, "acct", "owner", "now");
  assertEquals(row.authorized_date, "2026-07-18");
  assertEquals(row.posted_date, "2026-07-19");
  assertEquals(row.is_pending, false);
});

Deno.test("mapPlaidTransactionToNormalizedRow: missing optional fields default to null, never undefined", () => {
  const minimal = {
    transaction_id: "txn-minimal",
    account_id: "acct-1",
    amount: 5,
    name: "TEST",
    pending: false,
  };
  const row = mapPlaidTransactionToNormalizedRow(minimal, "acct", "owner", "now");
  assertEquals(row.pending_transaction_id, null);
  assertEquals(row.merchant_name, null);
  assertEquals(row.authorized_date, null);
  assertEquals(row.posted_date, null);
});

Deno.test("mapPlaidTransactionToNormalizedRow: amount is passed through as the same JS number representation, never re-stringified here", () => {
  const row = mapPlaidTransactionToNormalizedRow({ ...RAW_MCDONALDS_PENDING, amount: 19.99 }, "acct", "owner", "now");
  assertEquals(row.amount, 19.99);
  assertEquals(typeof row.amount, "number");
});

Deno.test("mapPlaidTransactionToNormalizedRow: never carries an access_token/secret/credential field (closed shape)", () => {
  const row = mapPlaidTransactionToNormalizedRow(
    { ...RAW_MCDONALDS_PENDING, access_token: "access-sandbox-should-never-appear" },
    "acct",
    "owner",
    "now",
  );
  const serialized = JSON.stringify(row);
  assert(!serialized.includes("access_token"), "the normalized row must never echo an access_token even if the raw Plaid object happened to carry one");
});

Deno.test("buildNormalizedTransactionRows: maps every transaction whose account_id resolves, in order", () => {
  const plan = buildNormalizedTransactionRows(
    [RAW_MCDONALDS_PENDING, { ...RAW_MCDONALDS_PENDING, transaction_id: "txn-2", account_id: "plaid-account-amex-2" }],
    { "plaid-account-amex-1": "uuid-account-1", "plaid-account-amex-2": "uuid-account-2" },
    "owner-uuid",
    "now",
  );
  assertEquals(plan.rows.length, 2);
  assertEquals(plan.skippedUnknownAccountCount, 0);
  assertEquals(plan.rows[0].plaid_account_id, "uuid-account-1");
  assertEquals(plan.rows[1].plaid_account_id, "uuid-account-2");
});

Deno.test("buildNormalizedTransactionRows: two accounts under one Plaid Item remain distinct, never merged", () => {
  const plan = buildNormalizedTransactionRows(
    [
      { ...RAW_MCDONALDS_PENDING, transaction_id: "txn-acct-1", account_id: "amex-card-1" },
      { ...RAW_MCDONALDS_PENDING, transaction_id: "txn-acct-2", account_id: "amex-card-2" },
    ],
    { "amex-card-1": "uuid-1", "amex-card-2": "uuid-2" },
    "owner",
    "now",
  );
  const accountIds = plan.rows.map((r) => r.plaid_account_id);
  assertEquals(new Set(accountIds).size, 2, "each transaction must resolve to its OWN account's plaid_accounts.id, never collapsed onto a sibling account under the same Item");
});

Deno.test("buildNormalizedTransactionRows: skips (never throws for) a transaction whose account_id has no known plaid_accounts mapping", () => {
  const plan = buildNormalizedTransactionRows(
    [{ ...RAW_MCDONALDS_PENDING, account_id: "never-discovered-account" }],
    { "plaid-account-amex-1": "uuid-1" },
    "owner",
    "now",
  );
  assertEquals(plan.rows.length, 0);
  assertEquals(plan.skippedUnknownAccountCount, 1);
});

Deno.test("buildNormalizedTransactionRows: an unknown-account transaction never blocks normalization of the OTHER transactions in the same batch", () => {
  const plan = buildNormalizedTransactionRows(
    [
      { ...RAW_MCDONALDS_PENDING, transaction_id: "txn-known", account_id: "plaid-account-amex-1" },
      { ...RAW_MCDONALDS_PENDING, transaction_id: "txn-unknown", account_id: "never-discovered-account" },
    ],
    { "plaid-account-amex-1": "uuid-1" },
    "owner",
    "now",
  );
  assertEquals(plan.rows.length, 1);
  assertEquals(plan.rows[0].transaction_id, "txn-known");
  assertEquals(plan.skippedUnknownAccountCount, 1);
});

Deno.test("buildNormalizedTransactionRows: empty input produces an empty plan, never throws", () => {
  const plan = buildNormalizedTransactionRows([], {}, "owner", "now");
  assertEquals(plan.rows.length, 0);
  assertEquals(plan.skippedUnknownAccountCount, 0);
});

Deno.test("buildNormalizedTransactionRows: reprocessing the exact same input is a pure, deterministic no-op (idempotent at the mapping layer)", () => {
  const accountMap = { "plaid-account-amex-1": "uuid-1" };
  const first = buildNormalizedTransactionRows([RAW_MCDONALDS_PENDING], accountMap, "owner", "same-instant");
  const second = buildNormalizedTransactionRows([RAW_MCDONALDS_PENDING], accountMap, "owner", "same-instant");
  assertEquals(first, second, "the exact same sync input must always produce the exact same normalized rows — the actual dedup/no-duplication guarantee is then provided by the database's own upsert-on-conflict(plaid_account_id, transaction_id), verified by code review");
});
