// Focused regression tests for the pure functions in ./manual.ts — Manual Account/Transaction
// cloud sync foundation (Phase 5), see migration 0011_manual_accounts_transactions.sql for the
// table definitions these map onto.
//
// Deliberately does NOT test anything requiring a live Supabase/Postgres connection or a live
// HTTP call (createPrivilegedClient, requireAuthenticatedUserId, the actual upsert/delete calls in
// sync-manual-data/index.ts and get-manual-account-data/index.ts) — those need real infrastructure
// this repo's test setup doesn't provide, and are covered instead by direct code review, matching
// this project's established testing philosophy (see plaid.test.ts's own header comment).
//
// Run with: deno test --allow-env supabase/functions/_shared/manual.test.ts

import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  buildManualAccountRow,
  buildManualTransactionRow,
  isValidAccountType,
  isValidBareDate,
  isValidTransactionType,
  planManualAccountSync,
  planManualTransactionSync,
} from "./manual.ts";

// A minimal, deliberately permissive UUID check for these tests — the real isValidUuid lives in
// ../_shared/plaid.ts and is exercised by its own test file; these tests only need SOME function
// with the right signature, so a self-contained stand-in avoids a cross-file test dependency.
const UUID_PATTERN = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
function isValidUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

const OWNER_ID = "11111111-1111-1111-1111-111111111111";
const ACCOUNT_ID = "22222222-2222-2222-2222-222222222222";
const TXN_ID = "33333333-3333-3333-3333-333333333333";

// -------------------------------------------------------------------------------------------
// isValidAccountType / isValidTransactionType / isValidBareDate
// -------------------------------------------------------------------------------------------

Deno.test("isValidAccountType: accepts every AccountType raw value", () => {
  for (const value of ["checking", "savings", "creditCard", "cash", "other"]) {
    assert(isValidAccountType(value), `${value} should be valid`);
  }
});

Deno.test("isValidAccountType: rejects an unknown or wrongly-cased value", () => {
  assert(!isValidAccountType("Checking"));
  assert(!isValidAccountType("credit_card"));
  assert(!isValidAccountType(""));
  assert(!isValidAccountType(123));
  assert(!isValidAccountType(null));
});

Deno.test("isValidTransactionType: accepts every TransactionType raw value", () => {
  for (const value of ["expense", "income", "transfer", "creditCardPayment", "refund", "balanceAdjustment"]) {
    assert(isValidTransactionType(value), `${value} should be valid`);
  }
});

Deno.test("isValidTransactionType: rejects an unknown value", () => {
  assert(!isValidTransactionType("deposit"));
  assert(!isValidTransactionType(undefined));
});

Deno.test("isValidBareDate: accepts a well-formed YYYY-MM-DD string", () => {
  assert(isValidBareDate("2026-07-18"));
});

Deno.test("isValidBareDate: rejects an ISO8601 instant, never silently accepts a timestamp", () => {
  assert(!isValidBareDate("2026-07-18T00:00:00Z"));
  assert(!isValidBareDate("2026-07-18T00:00:00.000Z"));
});

Deno.test("isValidBareDate: rejects malformed strings and non-strings", () => {
  assert(!isValidBareDate("07-18-2026"));
  assert(!isValidBareDate("2026-7-18"));
  assert(!isValidBareDate(""));
  assert(!isValidBareDate(null));
  assert(!isValidBareDate(20260718));
});

// -------------------------------------------------------------------------------------------
// buildManualAccountRow
// -------------------------------------------------------------------------------------------

const VALID_ACCOUNT_INPUT = {
  id: ACCOUNT_ID,
  name: "Chase Checking",
  account_type: "checking",
  current_balance: "1234.56",
  institution_name: "Chase",
  last_four_digits: "4821",
  shows_in_recent_activity: true,
  created_at: "2026-07-18T12:00:00.000Z",
  updated_at: "2026-07-18T12:00:00.000Z",
};

Deno.test("buildManualAccountRow: maps a fully-populated valid input to the exact row shape", () => {
  const result = buildManualAccountRow(VALID_ACCOUNT_INPUT, OWNER_ID, isValidUuid);
  assert("row" in result);
  assertEquals(result.row, {
    id: ACCOUNT_ID,
    owner_user_id: OWNER_ID,
    name: "Chase Checking",
    account_type: "checking",
    current_balance: 1234.56,
    institution_name: "Chase",
    last_four_digits: "4821",
    shows_in_recent_activity: true,
    created_at: "2026-07-18T12:00:00.000Z",
    updated_at: "2026-07-18T12:00:00.000Z",
  });
});

Deno.test("buildManualAccountRow: owner_user_id always comes from the caller-supplied parameter, never from the input object, even if the input object happens to carry one", () => {
  const spoofed = { ...VALID_ACCOUNT_INPUT, owner_user_id: "99999999-9999-9999-9999-999999999999" };
  const result = buildManualAccountRow(spoofed, OWNER_ID, isValidUuid);
  assert("row" in result);
  assertEquals(result.row.owner_user_id, OWNER_ID);
});

Deno.test("buildManualAccountRow: nullable fields default to null when omitted, not undefined", () => {
  const minimal = {
    id: ACCOUNT_ID,
    name: "Cash",
    account_type: "cash",
    current_balance: "0",
    shows_in_recent_activity: false,
    created_at: "2026-07-18T12:00:00.000Z",
    updated_at: "2026-07-18T12:00:00.000Z",
  };
  const result = buildManualAccountRow(minimal, OWNER_ID, isValidUuid);
  assert("row" in result);
  assertEquals(result.row.institution_name, null);
  assertEquals(result.row.last_four_digits, null);
});

Deno.test("buildManualAccountRow: rejects an invalid id with the specific reason, never throws", () => {
  const result = buildManualAccountRow({ ...VALID_ACCOUNT_INPUT, id: "not-a-uuid" }, OWNER_ID, isValidUuid);
  assertEquals(result, { error: "invalid_id" });
});

Deno.test("buildManualAccountRow: rejects an empty name", () => {
  const result = buildManualAccountRow({ ...VALID_ACCOUNT_INPUT, name: "" }, OWNER_ID, isValidUuid);
  assertEquals(result, { error: "invalid_name" });
});

Deno.test("buildManualAccountRow: rejects an account_type outside the locked enum", () => {
  const result = buildManualAccountRow({ ...VALID_ACCOUNT_INPUT, account_type: "crypto" }, OWNER_ID, isValidUuid);
  assertEquals(result, { error: "invalid_account_type" });
});

Deno.test("buildManualAccountRow: rejects a non-numeric current_balance string", () => {
  const result = buildManualAccountRow({ ...VALID_ACCOUNT_INPUT, current_balance: "not-a-number" }, OWNER_ID, isValidUuid);
  assertEquals(result, { error: "invalid_current_balance" });
});

Deno.test("buildManualAccountRow: rejects a non-boolean shows_in_recent_activity", () => {
  const result = buildManualAccountRow({ ...VALID_ACCOUNT_INPUT, shows_in_recent_activity: "true" }, OWNER_ID, isValidUuid);
  assertEquals(result, { error: "invalid_shows_in_recent_activity" });
});

Deno.test("buildManualAccountRow: rejects an unparseable created_at/updated_at", () => {
  assertEquals(buildManualAccountRow({ ...VALID_ACCOUNT_INPUT, created_at: "not-a-date" }, OWNER_ID, isValidUuid), {
    error: "invalid_created_at",
  });
  assertEquals(buildManualAccountRow({ ...VALID_ACCOUNT_INPUT, updated_at: "not-a-date" }, OWNER_ID, isValidUuid), {
    error: "invalid_updated_at",
  });
});

// -------------------------------------------------------------------------------------------
// buildManualTransactionRow
// -------------------------------------------------------------------------------------------

const VALID_TRANSACTION_INPUT = {
  id: TXN_ID,
  manual_account_id: ACCOUNT_ID,
  amount: "42.50",
  transaction_type: "expense",
  transaction_date: "2026-07-18",
  note: "Trader Joe's",
  category_name: "Groceries",
  is_pending: false,
  created_at: "2026-07-18T12:00:00.000Z",
  updated_at: "2026-07-18T12:00:00.000Z",
};

Deno.test("buildManualTransactionRow: maps a fully-populated valid input to the exact row shape", () => {
  const result = buildManualTransactionRow(VALID_TRANSACTION_INPUT, OWNER_ID, isValidUuid);
  assert("row" in result);
  assertEquals(result.row, {
    id: TXN_ID,
    manual_account_id: ACCOUNT_ID,
    owner_user_id: OWNER_ID,
    amount: 42.5,
    transaction_type: "expense",
    transaction_date: "2026-07-18",
    note: "Trader Joe's",
    category_name: "Groceries",
    is_pending: false,
    created_at: "2026-07-18T12:00:00.000Z",
    updated_at: "2026-07-18T12:00:00.000Z",
  });
});

Deno.test("buildManualTransactionRow: a bare date of 2026-07-18 remains exactly 2026-07-18 — no parsing, no shift", () => {
  const result = buildManualTransactionRow(VALID_TRANSACTION_INPUT, OWNER_ID, isValidUuid);
  assert("row" in result);
  assertEquals(result.row.transaction_date, "2026-07-18");
});

Deno.test("buildManualTransactionRow: owner_user_id always comes from the caller-supplied parameter, never the input object", () => {
  const spoofed = { ...VALID_TRANSACTION_INPUT, owner_user_id: "99999999-9999-9999-9999-999999999999" };
  const result = buildManualTransactionRow(spoofed, OWNER_ID, isValidUuid);
  assert("row" in result);
  assertEquals(result.row.owner_user_id, OWNER_ID);
});

Deno.test("buildManualTransactionRow: category_name defaults to null when omitted", () => {
  const { category_name, ...withoutCategory } = VALID_TRANSACTION_INPUT;
  const result = buildManualTransactionRow(withoutCategory, OWNER_ID, isValidUuid);
  assert("row" in result);
  assertEquals(result.row.category_name, null);
});

Deno.test("buildManualTransactionRow: rejects an invalid manual_account_id", () => {
  const result = buildManualTransactionRow({ ...VALID_TRANSACTION_INPUT, manual_account_id: "nope" }, OWNER_ID, isValidUuid);
  assertEquals(result, { error: "invalid_manual_account_id" });
});

Deno.test("buildManualTransactionRow: rejects an ISO8601 instant passed as transaction_date", () => {
  const result = buildManualTransactionRow(
    { ...VALID_TRANSACTION_INPUT, transaction_date: "2026-07-18T00:00:00Z" },
    OWNER_ID,
    isValidUuid,
  );
  assertEquals(result, { error: "invalid_transaction_date" });
});

Deno.test("buildManualTransactionRow: rejects a transaction_type outside the locked enum", () => {
  const result = buildManualTransactionRow({ ...VALID_TRANSACTION_INPUT, transaction_type: "deposit" }, OWNER_ID, isValidUuid);
  assertEquals(result, { error: "invalid_transaction_type" });
});

Deno.test("buildManualTransactionRow: rejects a non-numeric amount", () => {
  const result = buildManualTransactionRow({ ...VALID_TRANSACTION_INPUT, amount: "free" }, OWNER_ID, isValidUuid);
  assertEquals(result, { error: "invalid_amount" });
});

// -------------------------------------------------------------------------------------------
// planManualAccountSync / planManualTransactionSync — batch behavior
// -------------------------------------------------------------------------------------------

Deno.test("planManualAccountSync: valid entries all map, rejected list is empty", () => {
  const plan = planManualAccountSync([VALID_ACCOUNT_INPUT, { ...VALID_ACCOUNT_INPUT, id: "44444444-4444-4444-4444-444444444444" }], OWNER_ID, isValidUuid);
  assertEquals(plan.rows.length, 2);
  assertEquals(plan.rejected.length, 0);
});

Deno.test("planManualAccountSync: one malformed entry is reported and skipped, never blocks the rest of the batch", () => {
  const plan = planManualAccountSync(
    [VALID_ACCOUNT_INPUT, { ...VALID_ACCOUNT_INPUT, id: "not-a-uuid" }],
    OWNER_ID,
    isValidUuid,
  );
  assertEquals(plan.rows.length, 1);
  assertEquals(plan.rejected.length, 1);
  assertEquals(plan.rejected[0], { id: "not-a-uuid", error: "invalid_id" });
});

Deno.test("planManualAccountSync: empty input produces an empty plan, never throws", () => {
  const plan = planManualAccountSync([], OWNER_ID, isValidUuid);
  assertEquals(plan.rows.length, 0);
  assertEquals(plan.rejected.length, 0);
});

Deno.test("planManualTransactionSync: valid entries all map, rejected list is empty", () => {
  const plan = planManualTransactionSync(
    [VALID_TRANSACTION_INPUT, { ...VALID_TRANSACTION_INPUT, id: "55555555-5555-5555-5555-555555555555" }],
    OWNER_ID,
    isValidUuid,
  );
  assertEquals(plan.rows.length, 2);
  assertEquals(plan.rejected.length, 0);
});

Deno.test("planManualTransactionSync: one malformed entry is reported and skipped, never blocks the rest of the batch", () => {
  const plan = planManualTransactionSync(
    [VALID_TRANSACTION_INPUT, { ...VALID_TRANSACTION_INPUT, id: TXN_ID, transaction_type: "bogus" }],
    OWNER_ID,
    isValidUuid,
  );
  assertEquals(plan.rows.length, 1);
  assertEquals(plan.rejected.length, 1);
  assertEquals(plan.rejected[0].error, "invalid_transaction_type");
});

Deno.test("planManualTransactionSync: two different owners' otherwise-identical inputs each keep their own owner_user_id — never collide", () => {
  const ownerA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
  const ownerB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
  const planA = planManualTransactionSync([VALID_TRANSACTION_INPUT], ownerA, isValidUuid);
  const planB = planManualTransactionSync([VALID_TRANSACTION_INPUT], ownerB, isValidUuid);
  assertEquals(planA.rows[0].owner_user_id, ownerA);
  assertEquals(planB.rows[0].owner_user_id, ownerB);
  assert(planA.rows[0].owner_user_id !== planB.rows[0].owner_user_id);
});
