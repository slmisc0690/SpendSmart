// Focused regression tests for the pure/deterministic pieces of ../_shared/plaid.ts added or
// changed for Plaid Production preparation (Phase P1A): environment loading (including the
// now-unblocked "production" case), per-Item environment consistency, webhook URL construction,
// and the extracted sandbox-only gate used by debug-reset-cursor.
//
// Deliberately does NOT test anything that requires a live Supabase/Postgres connection or a
// live Plaid API call (createPrivilegedClient, refreshPlaidAccounts, requireAuthenticatedUserId,
// plaidFetch) — those need real infrastructure this repo's test setup doesn't provide, and are
// covered instead by direct code review (see the accompanying audit report). Every test here
// exercises pure functions of environment variables/string inputs only.
//
// Run with: deno test --allow-env supabase/functions/_shared/plaid.test.ts

import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  assertItemEnvironmentMatches,
  buildPlaidWebhookUrl,
  EnvironmentMismatchError,
  isSandboxEnvironment,
  loadPlaidCredentials,
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

Deno.test("loadPlaidCredentials: unsupported PLAID_ENV value still throws", () => {
  withEnv({ ...VALID_CREDS, PLAID_ENV: "staging" }, () => {
    assertThrows(() => loadPlaidCredentials(), Error, 'PLAID_ENV must be one of "sandbox", "development", "production"');
  });
});

Deno.test("loadPlaidCredentials: empty-string PLAID_ENV still throws (not silently defaulted)", () => {
  withEnv({ ...VALID_CREDS, PLAID_ENV: "" }, () => {
    assertThrows(() => loadPlaidCredentials(), Error, 'PLAID_ENV must be one of');
  });
});

Deno.test("loadPlaidCredentials: missing PLAID_ENV still defaults to sandbox (pre-existing behavior, unchanged)", () => {
  withEnv({ ...VALID_CREDS, PLAID_ENV: undefined }, () => {
    const creds = loadPlaidCredentials();
    assertEquals(creds.environment, "sandbox");
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

Deno.test("isSandboxEnvironment: true when PLAID_ENV is unset (defaults to sandbox)", () => {
  withEnv({ PLAID_ENV: undefined }, () => {
    assertEquals(isSandboxEnvironment(), true);
  });
});

Deno.test("isSandboxEnvironment: false when PLAID_ENV is development", () => {
  withEnv({ PLAID_ENV: "development" }, () => {
    assertEquals(isSandboxEnvironment(), false);
  });
});

Deno.test("isSandboxEnvironment: false when PLAID_ENV is production — debug-reset-cursor stays unavailable outside sandbox", () => {
  withEnv({ PLAID_ENV: "production" }, () => {
    assertEquals(isSandboxEnvironment(), false);
  });
});
