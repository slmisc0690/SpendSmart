// Focused regression tests for the pure functions in ./monthlyPlan.ts — Monthly Plan cloud sync
// foundation (Phase 6), see migration 0012_monthly_plan_sync.sql for the table definitions these
// map onto.
//
// Deliberately does NOT test anything requiring a live Supabase/Postgres connection or a live HTTP
// call — matching this project's established testing philosophy (see plaid.test.ts's own header).
//
// Run with: deno test --allow-env supabase/functions/_shared/monthlyPlan.test.ts

import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  buildMonthlyPlanIncomeSourceRow,
  buildMonthlyPlanRecurringExpenseRow,
  buildMonthlyPlanSettingsRow,
  isValidBareDateOrNull,
  isValidPlanFrequency,
  planMonthlyPlanIncomeSourceSync,
  planMonthlyPlanRecurringExpenseSync,
  splitByOwnershipConflict,
} from "./monthlyPlan.ts";

const UUID_PATTERN = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
function isValidUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

const OWNER_A = "11111111-1111-1111-1111-111111111111";
const OWNER_B = "22222222-2222-2222-2222-222222222222";
const SOURCE_ID = "33333333-3333-3333-3333-333333333333";
const EXPENSE_ID = "44444444-4444-4444-4444-444444444444";

// -------------------------------------------------------------------------------------------
// isValidPlanFrequency / isValidBareDateOrNull
// -------------------------------------------------------------------------------------------

Deno.test("isValidPlanFrequency: accepts every PlanFrequency raw value", () => {
  for (const value of ["weekly", "biweekly", "twiceMonthly", "monthly", "quarterly", "yearly", "oneTime"]) {
    assert(isValidPlanFrequency(value), `${value} should be valid`);
  }
});

Deno.test("isValidPlanFrequency: rejects an unknown value", () => {
  assert(!isValidPlanFrequency("daily"));
  assert(!isValidPlanFrequency(null));
});

Deno.test("isValidBareDateOrNull: accepts null/undefined (both mean 'no date')", () => {
  assert(isValidBareDateOrNull(null));
  assert(isValidBareDateOrNull(undefined));
});

Deno.test("isValidBareDateOrNull: accepts a well-formed YYYY-MM-DD string", () => {
  assert(isValidBareDateOrNull("2026-07-18"));
});

Deno.test("isValidBareDateOrNull: rejects an ISO8601 instant, never silently accepts a timestamp", () => {
  assert(!isValidBareDateOrNull("2026-07-18T00:00:00Z"));
});

Deno.test("isValidBareDateOrNull: rejects a malformed non-null string", () => {
  assert(!isValidBareDateOrNull("07-18-2026"));
  assert(!isValidBareDateOrNull(""));
});

// -------------------------------------------------------------------------------------------
// buildMonthlyPlanSettingsRow
// -------------------------------------------------------------------------------------------

const VALID_SETTINGS_INPUT = {
  monthly_savings_goal: "500.00",
  buffer_amount: "100.00",
  auto_update_weekly_budget_from_plan: true,
  created_at: "2026-07-18T12:00:00.000Z",
  updated_at: "2026-07-18T12:00:00.000Z",
};

Deno.test("buildMonthlyPlanSettingsRow: maps a fully-populated valid input to the exact row shape", () => {
  const result = buildMonthlyPlanSettingsRow(VALID_SETTINGS_INPUT, OWNER_A);
  assert("row" in result);
  assertEquals(result.row, {
    owner_user_id: OWNER_A,
    monthly_savings_goal: 500,
    buffer_amount: 100,
    auto_update_weekly_budget_from_plan: true,
    created_at: "2026-07-18T12:00:00.000Z",
    updated_at: "2026-07-18T12:00:00.000Z",
  });
});

Deno.test("buildMonthlyPlanSettingsRow: owner_user_id always comes from the caller-supplied parameter — there is no field on the input object to even spoof", () => {
  const result = buildMonthlyPlanSettingsRow(VALID_SETTINGS_INPUT, OWNER_B);
  assert("row" in result);
  assertEquals(result.row.owner_user_id, OWNER_B);
});

Deno.test("buildMonthlyPlanSettingsRow: buffer_amount defaults to null when omitted", () => {
  const { buffer_amount, ...withoutBuffer } = VALID_SETTINGS_INPUT;
  const result = buildMonthlyPlanSettingsRow(withoutBuffer, OWNER_A);
  assert("row" in result);
  assertEquals(result.row.buffer_amount, null);
});

Deno.test("buildMonthlyPlanSettingsRow: rejects a non-numeric monthly_savings_goal", () => {
  const result = buildMonthlyPlanSettingsRow({ ...VALID_SETTINGS_INPUT, monthly_savings_goal: "free" }, OWNER_A);
  assertEquals(result, { error: "invalid_monthly_savings_goal" });
});

Deno.test("buildMonthlyPlanSettingsRow: rejects a non-numeric buffer_amount", () => {
  const result = buildMonthlyPlanSettingsRow({ ...VALID_SETTINGS_INPUT, buffer_amount: "lots" }, OWNER_A);
  assertEquals(result, { error: "invalid_buffer_amount" });
});

Deno.test("buildMonthlyPlanSettingsRow: rejects a non-boolean auto_update_weekly_budget_from_plan", () => {
  const result = buildMonthlyPlanSettingsRow({ ...VALID_SETTINGS_INPUT, auto_update_weekly_budget_from_plan: "yes" }, OWNER_A);
  assertEquals(result, { error: "invalid_auto_update_weekly_budget_from_plan" });
});

// -------------------------------------------------------------------------------------------
// buildMonthlyPlanIncomeSourceRow
// -------------------------------------------------------------------------------------------

const VALID_INCOME_SOURCE_INPUT = {
  id: SOURCE_ID,
  name: "Paycheck",
  amount: "2500.00",
  frequency: "biweekly",
  is_active: true,
  next_pay_date: null,
  note: "Direct deposit",
  created_at: "2026-07-18T12:00:00.000Z",
  updated_at: "2026-07-18T12:00:00.000Z",
};

Deno.test("buildMonthlyPlanIncomeSourceRow: maps a fully-populated valid input to the exact row shape", () => {
  const result = buildMonthlyPlanIncomeSourceRow(VALID_INCOME_SOURCE_INPUT, OWNER_A, isValidUuid);
  assert("row" in result);
  assertEquals(result.row, {
    id: SOURCE_ID,
    owner_user_id: OWNER_A,
    name: "Paycheck",
    amount: 2500,
    frequency: "biweekly",
    is_active: true,
    next_pay_date: null,
    note: "Direct deposit",
    created_at: "2026-07-18T12:00:00.000Z",
    updated_at: "2026-07-18T12:00:00.000Z",
  });
});

Deno.test("buildMonthlyPlanIncomeSourceRow: a one-time source's next_pay_date of 2026-07-18 remains exactly 2026-07-18", () => {
  const result = buildMonthlyPlanIncomeSourceRow(
    { ...VALID_INCOME_SOURCE_INPUT, frequency: "oneTime", next_pay_date: "2026-07-18" },
    OWNER_A,
    isValidUuid,
  );
  assert("row" in result);
  assertEquals(result.row.next_pay_date, "2026-07-18");
});

Deno.test("buildMonthlyPlanIncomeSourceRow: owner_user_id always comes from the caller-supplied parameter, never the input object", () => {
  const spoofed = { ...VALID_INCOME_SOURCE_INPUT, owner_user_id: OWNER_B };
  const result = buildMonthlyPlanIncomeSourceRow(spoofed, OWNER_A, isValidUuid);
  assert("row" in result);
  assertEquals(result.row.owner_user_id, OWNER_A);
});

Deno.test("buildMonthlyPlanIncomeSourceRow: rejects an invalid id", () => {
  const result = buildMonthlyPlanIncomeSourceRow({ ...VALID_INCOME_SOURCE_INPUT, id: "not-a-uuid" }, OWNER_A, isValidUuid);
  assertEquals(result, { error: "invalid_id" });
});

Deno.test("buildMonthlyPlanIncomeSourceRow: rejects a frequency outside the locked enum", () => {
  const result = buildMonthlyPlanIncomeSourceRow({ ...VALID_INCOME_SOURCE_INPUT, frequency: "daily" }, OWNER_A, isValidUuid);
  assertEquals(result, { error: "invalid_frequency" });
});

Deno.test("buildMonthlyPlanIncomeSourceRow: rejects an ISO8601 instant passed as next_pay_date", () => {
  const result = buildMonthlyPlanIncomeSourceRow(
    { ...VALID_INCOME_SOURCE_INPUT, next_pay_date: "2026-07-18T00:00:00Z" },
    OWNER_A,
    isValidUuid,
  );
  assertEquals(result, { error: "invalid_next_pay_date" });
});

// -------------------------------------------------------------------------------------------
// buildMonthlyPlanRecurringExpenseRow
// -------------------------------------------------------------------------------------------

const VALID_RECURRING_EXPENSE_INPUT = {
  id: EXPENSE_ID,
  name: "Rent",
  amount: "1500.00",
  frequency: "monthly",
  is_active: true,
  due_date: null,
  is_essential: true,
  category_name: "Housing",
  note: "",
  created_at: "2026-07-18T12:00:00.000Z",
  updated_at: "2026-07-18T12:00:00.000Z",
};

Deno.test("buildMonthlyPlanRecurringExpenseRow: maps a fully-populated valid input to the exact row shape", () => {
  const result = buildMonthlyPlanRecurringExpenseRow(VALID_RECURRING_EXPENSE_INPUT, OWNER_A, isValidUuid);
  assert("row" in result);
  assertEquals(result.row, {
    id: EXPENSE_ID,
    owner_user_id: OWNER_A,
    name: "Rent",
    amount: 1500,
    frequency: "monthly",
    is_active: true,
    due_date: null,
    is_essential: true,
    category_name: "Housing",
    note: "",
    created_at: "2026-07-18T12:00:00.000Z",
    updated_at: "2026-07-18T12:00:00.000Z",
  });
});

Deno.test("buildMonthlyPlanRecurringExpenseRow: a one-time expense's due_date of 2026-07-18 remains exactly 2026-07-18", () => {
  const result = buildMonthlyPlanRecurringExpenseRow(
    { ...VALID_RECURRING_EXPENSE_INPUT, frequency: "oneTime", due_date: "2026-07-18" },
    OWNER_A,
    isValidUuid,
  );
  assert("row" in result);
  assertEquals(result.row.due_date, "2026-07-18");
});

Deno.test("buildMonthlyPlanRecurringExpenseRow: category_name defaults to null when omitted", () => {
  const { category_name, ...withoutCategory } = VALID_RECURRING_EXPENSE_INPUT;
  const result = buildMonthlyPlanRecurringExpenseRow(withoutCategory, OWNER_A, isValidUuid);
  assert("row" in result);
  assertEquals(result.row.category_name, null);
});

Deno.test("buildMonthlyPlanRecurringExpenseRow: rejects a non-boolean is_essential", () => {
  const result = buildMonthlyPlanRecurringExpenseRow({ ...VALID_RECURRING_EXPENSE_INPUT, is_essential: "yes" }, OWNER_A, isValidUuid);
  assertEquals(result, { error: "invalid_is_essential" });
});

// -------------------------------------------------------------------------------------------
// planMonthlyPlanIncomeSourceSync / planMonthlyPlanRecurringExpenseSync — batch behavior
// -------------------------------------------------------------------------------------------

Deno.test("planMonthlyPlanIncomeSourceSync: one malformed entry is reported and skipped, never blocks the rest of the batch", () => {
  const plan = planMonthlyPlanIncomeSourceSync(
    [VALID_INCOME_SOURCE_INPUT, { ...VALID_INCOME_SOURCE_INPUT, id: "not-a-uuid" }],
    OWNER_A,
    isValidUuid,
  );
  assertEquals(plan.rows.length, 1);
  assertEquals(plan.rejected.length, 1);
  assertEquals(plan.rejected[0], { id: "not-a-uuid", error: "invalid_id" });
});

Deno.test("planMonthlyPlanRecurringExpenseSync: two different owners' otherwise-identical inputs each keep their own owner_user_id — never collide", () => {
  const planA = planMonthlyPlanRecurringExpenseSync([VALID_RECURRING_EXPENSE_INPUT], OWNER_A, isValidUuid);
  const planB = planMonthlyPlanRecurringExpenseSync([VALID_RECURRING_EXPENSE_INPUT], OWNER_B, isValidUuid);
  assertEquals(planA.rows[0].owner_user_id, OWNER_A);
  assertEquals(planB.rows[0].owner_user_id, OWNER_B);
});

// -------------------------------------------------------------------------------------------
// splitByOwnershipConflict — the Phase 5B-lesson ownership-hijack guard, applied proactively here
// -------------------------------------------------------------------------------------------

Deno.test("splitByOwnershipConflict: a brand-new id (no existing owner) is allowed through", () => {
  const rows = [{ id: SOURCE_ID, value: "x" }];
  const result = splitByOwnershipConflict(rows, OWNER_A, new Map());
  assertEquals(result.ownedRows, rows);
  assertEquals(result.foreignConflictIds, []);
});

Deno.test("splitByOwnershipConflict: an id already owned by the SAME caller is allowed through (a genuine update)", () => {
  const rows = [{ id: SOURCE_ID, value: "x" }];
  const result = splitByOwnershipConflict(rows, OWNER_A, new Map([[SOURCE_ID, OWNER_A]]));
  assertEquals(result.ownedRows, rows);
  assertEquals(result.foreignConflictIds, []);
});

Deno.test("splitByOwnershipConflict: an id already owned by a DIFFERENT user is rejected, never upserted — the exact Phase 5B hijack class", () => {
  const rows = [{ id: SOURCE_ID, value: "HACKED" }];
  const result = splitByOwnershipConflict(rows, OWNER_B, new Map([[SOURCE_ID, OWNER_A]]));
  assertEquals(result.ownedRows, []);
  assertEquals(result.foreignConflictIds, [SOURCE_ID]);
});

Deno.test("splitByOwnershipConflict: a mixed batch splits correctly — one foreign conflict never blocks the others", () => {
  const ownId = "55555555-5555-5555-5555-555555555555";
  const foreignId = "66666666-6666-6666-6666-666666666666";
  const rows = [{ id: ownId, value: "mine" }, { id: foreignId, value: "not mine" }];
  const result = splitByOwnershipConflict(rows, OWNER_A, new Map([[foreignId, OWNER_B]]));
  assertEquals(result.ownedRows.map((r) => r.id), [ownId]);
  assertEquals(result.foreignConflictIds, [foreignId]);
});
