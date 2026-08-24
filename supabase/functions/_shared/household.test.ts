// Deno unit tests for _shared/household.ts — PHASE 7. Run via `deno test --allow-env <path>`,
// matching this project's established backend testing convention (see plaid.test.ts/
// manual.test.ts/monthlyPlan.test.ts). NOT runnable in this environment (Deno is not installed
// locally) — verified by code review only, per this project's own documented convention
// (CLAUDE.md, "Testing conventions").

import { assertEquals, assertMatch, assertNotEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  buildInvitationUrl,
  generateAcceptanceToken,
  HOUSEHOLD_INVITATION_URL_HOST,
  HOUSEHOLD_INVITATION_URL_SCHEME,
  hashAcceptanceToken,
  isValidAcceptanceToken,
  isValidEmail,
  isValidInvitationAction,
  isValidSharingCategory,
  isValidSharingPermissionRequest,
  isValidSpendingStatus,
  normalizeEmail,
} from "./household.ts";

Deno.test("normalizeEmail trims and lowercases", () => {
  assertEquals(normalizeEmail("  Scott@Example.COM  "), "scott@example.com");
});

Deno.test("isValidEmail accepts a well-formed address", () => {
  assertEquals(isValidEmail("scott@example.com"), true);
});

Deno.test("isValidEmail rejects missing @", () => {
  assertEquals(isValidEmail("scottexample.com"), false);
});

Deno.test("isValidEmail rejects missing domain dot", () => {
  assertEquals(isValidEmail("scott@examplecom"), false);
});

Deno.test("isValidEmail rejects empty/whitespace-only", () => {
  assertEquals(isValidEmail("   "), false);
  assertEquals(isValidEmail(""), false);
});

Deno.test("isValidEmail rejects non-string", () => {
  assertEquals(isValidEmail(42), false);
  assertEquals(isValidEmail(null), false);
  assertEquals(isValidEmail(undefined), false);
});

Deno.test("isValidEmail rejects overlong address", () => {
  const local = "a".repeat(310);
  assertEquals(isValidEmail(`${local}@example.com`), false);
});

Deno.test("isValidSharingCategory accepts all five categories", () => {
  assertEquals(isValidSharingCategory("connectedAccounts"), true);
  assertEquals(isValidSharingCategory("manualAccounts"), true);
  assertEquals(isValidSharingCategory("monthlyPlan"), true);
  assertEquals(isValidSharingCategory("monthlySavings"), true);
  assertEquals(isValidSharingCategory("savedViaTransfer"), true);
});

Deno.test("isValidSharingCategory rejects unknown category", () => {
  assertEquals(isValidSharingCategory("somethingElse"), false);
  assertEquals(isValidSharingCategory(123), false);
});

// PHASE A — monthlySavings independent sharing category

Deno.test("isValidSharingPermissionRequest accepts null item_id for monthlySavings", () => {
  const result = isValidSharingPermissionRequest("monthlySavings", null);
  assertEquals(result, { valid: true, category: "monthlySavings", itemId: null });
});

Deno.test("isValidSharingPermissionRequest rejects non-null item_id for monthlySavings", () => {
  const result = isValidSharingPermissionRequest("monthlySavings", "11111111-1111-1111-1111-111111111111");
  assertEquals(result.valid, false);
});

Deno.test("isValidSharingPermissionRequest treats monthlySavings and monthlyPlan as independent categories", () => {
  const savings = isValidSharingPermissionRequest("monthlySavings", null);
  const plan = isValidSharingPermissionRequest("monthlyPlan", null);
  assertEquals(savings, { valid: true, category: "monthlySavings", itemId: null });
  assertEquals(plan, { valid: true, category: "monthlyPlan", itemId: null });
  assertNotEquals(savings, plan);
});

// DRIFT BUG FIX — savedViaTransfer (migration 0023) was missing from this Edge-Function-side
// allowlist even though the database itself always accepted it; these tests lock in the fix.

Deno.test("isValidSharingCategory accepts savedViaTransfer", () => {
  assertEquals(isValidSharingCategory("savedViaTransfer"), true);
});

Deno.test("isValidSharingPermissionRequest accepts null item_id for savedViaTransfer", () => {
  const result = isValidSharingPermissionRequest("savedViaTransfer", null);
  assertEquals(result, { valid: true, category: "savedViaTransfer", itemId: null });
});

Deno.test("isValidSharingPermissionRequest rejects non-null item_id for savedViaTransfer (global-only)", () => {
  const result = isValidSharingPermissionRequest("savedViaTransfer", "11111111-1111-1111-1111-111111111111");
  assertEquals(result.valid, false);
});

Deno.test("isValidSharingPermissionRequest accepts global connectedAccounts row", () => {
  const result = isValidSharingPermissionRequest("connectedAccounts", null);
  assertEquals(result, { valid: true, category: "connectedAccounts", itemId: null });
});

Deno.test("isValidSharingPermissionRequest accepts per-item manualAccounts row", () => {
  const result = isValidSharingPermissionRequest("manualAccounts", "11111111-1111-1111-1111-111111111111");
  assertEquals(result, {
    valid: true,
    category: "manualAccounts",
    itemId: "11111111-1111-1111-1111-111111111111",
  });
});

Deno.test("isValidSharingPermissionRequest rejects non-null item_id for monthlyPlan", () => {
  const result = isValidSharingPermissionRequest("monthlyPlan", "11111111-1111-1111-1111-111111111111");
  assertEquals(result.valid, false);
});

Deno.test("isValidSharingPermissionRequest accepts null item_id for monthlyPlan", () => {
  const result = isValidSharingPermissionRequest("monthlyPlan", null);
  assertEquals(result, { valid: true, category: "monthlyPlan", itemId: null });
});

Deno.test("isValidSharingPermissionRequest rejects invalid category", () => {
  const result = isValidSharingPermissionRequest("somethingElse", null);
  assertEquals(result.valid, false);
});

Deno.test("isValidSharingPermissionRequest rejects non-string item_id", () => {
  const result = isValidSharingPermissionRequest("connectedAccounts", 42);
  assertEquals(result.valid, false);
});

Deno.test("isValidInvitationAction accepts invite/resend/revoke", () => {
  assertEquals(isValidInvitationAction("invite"), true);
  assertEquals(isValidInvitationAction("resend"), true);
  assertEquals(isValidInvitationAction("revoke"), true);
});

Deno.test("isValidInvitationAction rejects unknown action", () => {
  assertEquals(isValidInvitationAction("accept"), false);
  assertEquals(isValidInvitationAction(1), false);
});

// PHASE 8 — acceptance token generation/hashing

Deno.test("generateAcceptanceToken produces a token whose hash matches hashAcceptanceToken", async () => {
  const { token, tokenHash } = await generateAcceptanceToken();
  const recomputed = await hashAcceptanceToken(token);
  assertEquals(recomputed, tokenHash);
});

Deno.test("generateAcceptanceToken produces a 64-character hex hash (SHA-256)", async () => {
  const { tokenHash } = await generateAcceptanceToken();
  assertMatch(tokenHash, /^[0-9a-f]{64}$/);
});

Deno.test("generateAcceptanceToken produces a URL-safe token (no +, /, or =)", async () => {
  const { token } = await generateAcceptanceToken();
  assertMatch(token, /^[A-Za-z0-9\-_]+$/);
});

Deno.test("generateAcceptanceToken produces distinct tokens across calls", async () => {
  const first = await generateAcceptanceToken();
  const second = await generateAcceptanceToken();
  assertNotEquals(first.token, second.token);
  assertNotEquals(first.tokenHash, second.tokenHash);
});

Deno.test("hashAcceptanceToken is deterministic for the same input", async () => {
  const hashA = await hashAcceptanceToken("fixed-test-token-value");
  const hashB = await hashAcceptanceToken("fixed-test-token-value");
  assertEquals(hashA, hashB);
});

Deno.test("hashAcceptanceToken produces different hashes for different tokens", async () => {
  const hashA = await hashAcceptanceToken("token-one");
  const hashB = await hashAcceptanceToken("token-two");
  assertNotEquals(hashA, hashB);
});

Deno.test("isValidAcceptanceToken accepts a non-empty string within the length bound", () => {
  assertEquals(isValidAcceptanceToken("abc123"), true);
});

Deno.test("isValidAcceptanceToken rejects an empty string", () => {
  assertEquals(isValidAcceptanceToken(""), false);
});

Deno.test("isValidAcceptanceToken rejects a non-string", () => {
  assertEquals(isValidAcceptanceToken(12345), false);
  assertEquals(isValidAcceptanceToken(null), false);
  assertEquals(isValidAcceptanceToken(undefined), false);
});

Deno.test("isValidAcceptanceToken rejects an overlong string", () => {
  assertEquals(isValidAcceptanceToken("a".repeat(513)), false);
});

Deno.test("buildInvitationUrl embeds the token under the locked scheme/host", async () => {
  const { token } = await generateAcceptanceToken();
  const url = buildInvitationUrl(token);
  assertEquals(url, `${HOUSEHOLD_INVITATION_URL_SCHEME}://${HOUSEHOLD_INVITATION_URL_HOST}?token=${encodeURIComponent(token)}`);
});

Deno.test("buildInvitationUrl percent-encodes special characters in the token", () => {
  const url = buildInvitationUrl("a+b/c=d");
  assertEquals(url, `spendsmart://household-invitation?token=${encodeURIComponent("a+b/c=d")}`);
});

// USER B DASHBOARD PARITY (canonical Monthly Outlook/Week-by-Week) — isValidSpendingStatus, used
// by upsert-dashboard-summary to validate monthly_outlook_status/current_plan_week_status.

Deno.test("isValidSpendingStatus accepts each of the three canonical values", () => {
  assertEquals(isValidSpendingStatus("good"), true);
  assertEquals(isValidSpendingStatus("warning"), true);
  assertEquals(isValidSpendingStatus("over"), true);
});

Deno.test("isValidSpendingStatus rejects an unrecognized string rather than guessing", () => {
  assertEquals(isValidSpendingStatus("great"), false);
  assertEquals(isValidSpendingStatus(""), false);
  assertEquals(isValidSpendingStatus("GOOD"), false);
});

Deno.test("isValidSpendingStatus rejects non-string values", () => {
  assertEquals(isValidSpendingStatus(null), false);
  assertEquals(isValidSpendingStatus(undefined), false);
  assertEquals(isValidSpendingStatus(1), false);
});
