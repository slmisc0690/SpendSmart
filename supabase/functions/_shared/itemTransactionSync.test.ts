// Focused regression tests for the pure/deterministic pieces of ../_shared/itemTransactionSync.ts
// (Plaid webhook-driven background sync, Phase 3).
//
// Deliberately does NOT test syncItemTransactionsForItem/runClaimedItemSync themselves — both
// require a live Supabase/Postgres connection (claim_item_transaction_sync/
// release_item_transaction_sync RPCs) and a live Plaid /transactions/sync call, neither of which
// this repo's test setup provides (same disclosed limitation as every other Plaid Edge Function
// test file in this project — see plaid.test.ts's own header). Required test scenarios not covered
// here (first sync with null cursor, subsequent sync with stored cursor, multiple pages/has_more/
// next_cursor persistence, added/modified/removed handling, pending->posted, multiple accounts
// under one Item, cross-Item/cross-user isolation, duplicate webhook, sync failure before cursor
// commit, retry after failure, concurrent same-Item vs. different-Item webhooks, cursor never
// regressing, malformed Plaid response handling) are verified by direct code review of
// itemTransactionSync.ts's own reasoning (see that file's doc comments) and, before Production
// deployment, empirical testing against an isolated preview branch — the same disclosed limitation
// already established for migrations 0008/0009/0010's own concurrency/ownership guarantees.
//
// AUTOMATIC CACHED-BALANCE REFRESH (added alongside the webhook-driven transaction sync) — also not
// covered here for the same live-dependency reason, verified instead by code review of
// runClaimedItemSync's own "BALANCE REFRESH" comment block plus empirical Preview testing before
// Production deployment: exactly one refreshPlaidAccounts (`/accounts/get`) call per successful
// Item-level transaction sync, never one per account under a multi-account Item; the call happens
// strictly AFTER release_item_transaction_sync's own success commit, in its own try/catch, so a
// balance-refresh failure can never roll back, corrupt, or be reported as a failure of the
// already-committed transaction sync (`success`/`addedCount`/`modifiedCount`/`removedCount` on the
// returned outcome are entirely unaffected by `balanceRefreshSucceeded`); balances are mapped by
// Plaid's stable `account_id` (refreshPlaidAccounts' own existing upsert-by-`(plaid_item_id,
// account_id)` logic, unmodified by this phase); no retry bookkeeping was added because a failed
// balance refresh needs none — the next successful transaction sync (webhook- or manual-refresh-
// triggered) simply attempts refreshPlaidAccounts again.
//
// This file covers exactly one thing in isolation: summarizeSyncErrorForStorage, the function that
// decides what a sync failure is allowed to write into plaid_items.last_transaction_sync_error — a
// column a future admin/observability surface could plausibly display, so it must never leak a
// Plaid response body or a raw Postgres error message/detail (either of which can embed request
// content up to and including an access_token).
//
// Run with: deno test --allow-env supabase/functions/_shared/itemTransactionSync.test.ts

import { assert, assertEquals } from "jsr:@std/assert@1";
import { PlaidRequestError, SafeError } from "./plaid.ts";
import { summarizeSyncErrorForStorage } from "./itemTransactionSync.ts";

Deno.test("summarizeSyncErrorForStorage: a SafeError's own message is used as-is (already safe by construction)", () => {
  const error = new SafeError("Connection requires reauthentication");
  assertEquals(summarizeSyncErrorForStorage(error), "Connection requires reauthentication");
});

Deno.test("summarizeSyncErrorForStorage: a PlaidRequestError never leaks its raw response body — only the status is surfaced", () => {
  const secretBearingBody = { error_code: "INVALID_ACCESS_TOKEN", access_token: "access-sandbox-super-secret-value" };
  const error = new PlaidRequestError(400, secretBearingBody, "req-123");
  const summary = summarizeSyncErrorForStorage(error);
  assert(summary.includes("400"));
  assert(!summary.includes("access-sandbox-super-secret-value"));
  assert(!summary.includes("INVALID_ACCESS_TOKEN"));
});

Deno.test("summarizeSyncErrorForStorage: a Postgres-shaped error (object with a `code` property) is reduced to a bare generic string, never its message/detail", () => {
  const postgresError = {
    code: "23505",
    message: "duplicate key value violates unique constraint — Key (access_token)=(access-sandbox-super-secret-value) already exists.",
    detail: "access-sandbox-super-secret-value",
  };
  const summary = summarizeSyncErrorForStorage(postgresError);
  assertEquals(summary, "Database error");
  assert(!summary.includes("access-sandbox-super-secret-value"));
});

Deno.test("summarizeSyncErrorForStorage: an entirely unrecognized thrown value falls back to a bare generic string, never throws itself", () => {
  assertEquals(summarizeSyncErrorForStorage("some raw string thrown by accident"), "Sync failed");
  assertEquals(summarizeSyncErrorForStorage(undefined), "Sync failed");
  assertEquals(summarizeSyncErrorForStorage(new Error("a plain, unclassified Error with a scary message")), "Sync failed");
});
