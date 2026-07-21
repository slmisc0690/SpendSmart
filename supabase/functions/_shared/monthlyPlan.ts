// Shared helpers for the SpendSmart Monthly Plan cloud-sync Edge Functions (sync-monthly-plan-data,
// get-monthly-plan-data) — Phase 6, see migration 0012_monthly_plan_sync.sql for the table
// definitions these map onto.
//
// Deliberately a SEPARATE module from ../_shared/plaid.ts and ../_shared/manual.ts — nothing here
// is Plaid- or Manual-Account-specific. Generic cross-cutting helpers (requireAuthenticatedUserId,
// createPrivilegedClient, isValidUuid, jsonResponse, logSafeError/SafeError/UnauthorizedError,
// structured logging) are imported from ../_shared/plaid.ts by both Edge Functions rather than
// duplicated here, matching this project's established "one implementation, reused" discipline.

/// Mirrors the local `PlanFrequency` enum's raw values exactly (PlanFrequency.swift) — shared by
/// both IncomeSource and RecurringExpense, matching the local model's own "shared between both
/// models" design.
const VALID_PLAN_FREQUENCIES: ReadonlySet<string> = new Set([
  "weekly",
  "biweekly",
  "twiceMonthly",
  "monthly",
  "quarterly",
  "yearly",
  "oneTime",
]);

export function isValidPlanFrequency(value: unknown): value is string {
  return typeof value === "string" && VALID_PLAN_FREQUENCIES.has(value);
}

/// A bare "YYYY-MM-DD" calendar-date check — same discipline as manual.ts's isValidBareDate: never
/// parsed into a Date/instant anywhere in this file, only shape-checked.
const BARE_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

export function isValidBareDateOrNull(value: unknown): value is string | null | undefined {
  if (value === null || value === undefined) return true;
  return typeof value === "string" && BARE_DATE_PATTERN.test(value);
}

// ---------------------------------------------------------------------------------------------
// Monthly Plan settings (singleton per owner — see migration 0012's own header for why there is
// no separate client-supplied `id` for this table)
// ---------------------------------------------------------------------------------------------

export interface MonthlyPlanSettingsRow {
  owner_user_id: string;
  monthly_savings_goal: number;
  buffer_amount: number | null;
  auto_update_weekly_budget_from_plan: boolean;
  created_at: string;
  updated_at: string;
}

export interface RawMonthlyPlanSettingsInput {
  monthly_savings_goal: unknown;
  buffer_amount?: unknown;
  auto_update_weekly_budget_from_plan: unknown;
  created_at: unknown;
  updated_at: unknown;
}

export type MonthlyPlanSettingsValidationError =
  | "invalid_monthly_savings_goal"
  | "invalid_buffer_amount"
  | "invalid_auto_update_weekly_budget_from_plan"
  | "invalid_created_at"
  | "invalid_updated_at";

/// Pure validation + mapping — `owner_user_id` always comes from the caller-verified parameter,
/// never the input object (there is no `owner_user_id` field on `RawMonthlyPlanSettingsInput` at
/// all, structurally — the client cannot even attempt to supply one for this table).
export function buildMonthlyPlanSettingsRow(
  input: RawMonthlyPlanSettingsInput,
  ownerUserId: string,
): { row: MonthlyPlanSettingsRow } | { error: MonthlyPlanSettingsValidationError } {
  const savingsGoal = typeof input.monthly_savings_goal === "string" ? Number(input.monthly_savings_goal) : NaN;
  if (!Number.isFinite(savingsGoal)) return { error: "invalid_monthly_savings_goal" };

  let bufferAmount: number | null = null;
  if (input.buffer_amount !== null && input.buffer_amount !== undefined) {
    const parsed = typeof input.buffer_amount === "string" ? Number(input.buffer_amount) : NaN;
    if (!Number.isFinite(parsed)) return { error: "invalid_buffer_amount" };
    bufferAmount = parsed;
  }

  if (typeof input.auto_update_weekly_budget_from_plan !== "boolean") {
    return { error: "invalid_auto_update_weekly_budget_from_plan" };
  }
  if (typeof input.created_at !== "string" || Number.isNaN(Date.parse(input.created_at))) {
    return { error: "invalid_created_at" };
  }
  if (typeof input.updated_at !== "string" || Number.isNaN(Date.parse(input.updated_at))) {
    return { error: "invalid_updated_at" };
  }

  return {
    row: {
      owner_user_id: ownerUserId,
      monthly_savings_goal: savingsGoal,
      buffer_amount: bufferAmount,
      auto_update_weekly_budget_from_plan: input.auto_update_weekly_budget_from_plan,
      created_at: input.created_at,
      updated_at: input.updated_at,
    },
  };
}

// ---------------------------------------------------------------------------------------------
// Income sources
// ---------------------------------------------------------------------------------------------

export interface MonthlyPlanIncomeSourceRow {
  id: string;
  owner_user_id: string;
  name: string;
  amount: number;
  frequency: string;
  is_active: boolean;
  next_pay_date: string | null;
  note: string | null;
  created_at: string;
  updated_at: string;
}

export interface RawMonthlyPlanIncomeSourceInput {
  id: unknown;
  name: unknown;
  amount: unknown;
  frequency: unknown;
  is_active: unknown;
  next_pay_date?: unknown;
  note?: unknown;
  created_at: unknown;
  updated_at: unknown;
}

export type MonthlyPlanIncomeSourceValidationError =
  | "invalid_id"
  | "invalid_name"
  | "invalid_amount"
  | "invalid_frequency"
  | "invalid_is_active"
  | "invalid_next_pay_date"
  | "invalid_created_at"
  | "invalid_updated_at";

export function buildMonthlyPlanIncomeSourceRow(
  input: RawMonthlyPlanIncomeSourceInput,
  ownerUserId: string,
  isValidUuid: (value: unknown) => value is string,
): { row: MonthlyPlanIncomeSourceRow } | { error: MonthlyPlanIncomeSourceValidationError } {
  if (!isValidUuid(input.id)) return { error: "invalid_id" };
  if (typeof input.name !== "string" || input.name.length === 0) return { error: "invalid_name" };

  const amount = typeof input.amount === "string" ? Number(input.amount) : NaN;
  if (!Number.isFinite(amount)) return { error: "invalid_amount" };

  if (!isValidPlanFrequency(input.frequency)) return { error: "invalid_frequency" };
  if (typeof input.is_active !== "boolean") return { error: "invalid_is_active" };
  if (!isValidBareDateOrNull(input.next_pay_date)) return { error: "invalid_next_pay_date" };

  if (typeof input.created_at !== "string" || Number.isNaN(Date.parse(input.created_at))) {
    return { error: "invalid_created_at" };
  }
  if (typeof input.updated_at !== "string" || Number.isNaN(Date.parse(input.updated_at))) {
    return { error: "invalid_updated_at" };
  }

  return {
    row: {
      id: input.id,
      owner_user_id: ownerUserId,
      name: input.name,
      amount,
      frequency: input.frequency,
      is_active: input.is_active,
      next_pay_date: (input.next_pay_date as string | null | undefined) ?? null,
      note: typeof input.note === "string" ? input.note : null,
      created_at: input.created_at,
      updated_at: input.updated_at,
    },
  };
}

export interface MonthlyPlanIncomeSourceSyncPlan {
  rows: MonthlyPlanIncomeSourceRow[];
  rejected: { id: unknown; error: MonthlyPlanIncomeSourceValidationError }[];
}

export function planMonthlyPlanIncomeSourceSync(
  inputs: RawMonthlyPlanIncomeSourceInput[],
  ownerUserId: string,
  isValidUuid: (value: unknown) => value is string,
): MonthlyPlanIncomeSourceSyncPlan {
  const rows: MonthlyPlanIncomeSourceRow[] = [];
  const rejected: { id: unknown; error: MonthlyPlanIncomeSourceValidationError }[] = [];
  for (const input of inputs) {
    const result = buildMonthlyPlanIncomeSourceRow(input, ownerUserId, isValidUuid);
    if ("row" in result) rows.push(result.row);
    else rejected.push({ id: input.id, error: result.error });
  }
  return { rows, rejected };
}

// ---------------------------------------------------------------------------------------------
// Recurring expenses
// ---------------------------------------------------------------------------------------------

export interface MonthlyPlanRecurringExpenseRow {
  id: string;
  owner_user_id: string;
  name: string;
  amount: number;
  frequency: string;
  is_active: boolean;
  due_date: string | null;
  is_essential: boolean;
  category_name: string | null;
  note: string | null;
  created_at: string;
  updated_at: string;
}

export interface RawMonthlyPlanRecurringExpenseInput {
  id: unknown;
  name: unknown;
  amount: unknown;
  frequency: unknown;
  is_active: unknown;
  due_date?: unknown;
  is_essential: unknown;
  category_name?: unknown;
  note?: unknown;
  created_at: unknown;
  updated_at: unknown;
}

export type MonthlyPlanRecurringExpenseValidationError =
  | "invalid_id"
  | "invalid_name"
  | "invalid_amount"
  | "invalid_frequency"
  | "invalid_is_active"
  | "invalid_due_date"
  | "invalid_is_essential"
  | "invalid_created_at"
  | "invalid_updated_at";

export function buildMonthlyPlanRecurringExpenseRow(
  input: RawMonthlyPlanRecurringExpenseInput,
  ownerUserId: string,
  isValidUuid: (value: unknown) => value is string,
): { row: MonthlyPlanRecurringExpenseRow } | { error: MonthlyPlanRecurringExpenseValidationError } {
  if (!isValidUuid(input.id)) return { error: "invalid_id" };
  if (typeof input.name !== "string" || input.name.length === 0) return { error: "invalid_name" };

  const amount = typeof input.amount === "string" ? Number(input.amount) : NaN;
  if (!Number.isFinite(amount)) return { error: "invalid_amount" };

  if (!isValidPlanFrequency(input.frequency)) return { error: "invalid_frequency" };
  if (typeof input.is_active !== "boolean") return { error: "invalid_is_active" };
  if (!isValidBareDateOrNull(input.due_date)) return { error: "invalid_due_date" };
  if (typeof input.is_essential !== "boolean") return { error: "invalid_is_essential" };

  if (typeof input.created_at !== "string" || Number.isNaN(Date.parse(input.created_at))) {
    return { error: "invalid_created_at" };
  }
  if (typeof input.updated_at !== "string" || Number.isNaN(Date.parse(input.updated_at))) {
    return { error: "invalid_updated_at" };
  }

  return {
    row: {
      id: input.id,
      owner_user_id: ownerUserId,
      name: input.name,
      amount,
      frequency: input.frequency,
      is_active: input.is_active,
      due_date: (input.due_date as string | null | undefined) ?? null,
      is_essential: input.is_essential,
      category_name: typeof input.category_name === "string" ? input.category_name : null,
      note: typeof input.note === "string" ? input.note : null,
      created_at: input.created_at,
      updated_at: input.updated_at,
    },
  };
}

export interface MonthlyPlanRecurringExpenseSyncPlan {
  rows: MonthlyPlanRecurringExpenseRow[];
  rejected: { id: unknown; error: MonthlyPlanRecurringExpenseValidationError }[];
}

export function planMonthlyPlanRecurringExpenseSync(
  inputs: RawMonthlyPlanRecurringExpenseInput[],
  ownerUserId: string,
  isValidUuid: (value: unknown) => value is string,
): MonthlyPlanRecurringExpenseSyncPlan {
  const rows: MonthlyPlanRecurringExpenseRow[] = [];
  const rejected: { id: unknown; error: MonthlyPlanRecurringExpenseValidationError }[] = [];
  for (const input of inputs) {
    const result = buildMonthlyPlanRecurringExpenseRow(input, ownerUserId, isValidUuid);
    if ("row" in result) rows.push(result.row);
    else rejected.push({ id: input.id, error: result.error });
  }
  return { rows, rejected };
}

// ---------------------------------------------------------------------------------------------
// Ownership-conflict filtering — generic helper shared by both income sources and recurring
// expenses (each has an independent, client-supplied `id`, so each needs this same guard; see
// migration 0012's own header for why this is necessary — the exact hijack class fixed for
// manual_accounts in Phase 5B). Settings never needs this: its primary key IS owner_user_id, so
// an upsert can only ever target the caller's own row.
// ---------------------------------------------------------------------------------------------

export interface OwnershipConflictSplit<T extends { id: string }> {
  ownedRows: T[];
  foreignConflictIds: string[];
}

/// Splits `rows` into ones whose `id` is either brand-new or already owned by `ownerUserId`
/// (safe to upsert) versus ones whose `id` already exists under a DIFFERENT owner (must be
/// skipped, never upserted — upserting would silently reassign that existing row's ownership).
/// `existingOwnersById` is the caller's own pre-fetched lookup (id -> current owner_user_id) for
/// exactly the ids being synced — fetching that lookup requires a database call, which is the
/// caller's (the Edge Function's) responsibility, not this pure function's.
export function splitByOwnershipConflict<T extends { id: string }>(
  rows: T[],
  ownerUserId: string,
  existingOwnersById: ReadonlyMap<string, string>,
): OwnershipConflictSplit<T> {
  const ownedRows: T[] = [];
  const foreignConflictIds: string[] = [];
  for (const row of rows) {
    const existingOwner = existingOwnersById.get(row.id);
    if (existingOwner !== undefined && existingOwner !== ownerUserId) {
      foreignConflictIds.push(row.id);
    } else {
      ownedRows.push(row);
    }
  }
  return { ownedRows, foreignConflictIds };
}
