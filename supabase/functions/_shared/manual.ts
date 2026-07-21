// Shared helpers for the SpendSmart Manual Account/Transaction cloud-sync Edge Functions
// (sync-manual-data, get-manual-account-data) — Phase 5, see migration
// 0011_manual_accounts_transactions.sql for the table definitions these map onto.
//
// Deliberately a SEPARATE module from ../_shared/plaid.ts rather than folding into it: nothing
// here is Plaid-specific. Generic cross-cutting helpers (requireAuthenticatedUserId,
// createPrivilegedClient, isValidUuid, jsonResponse, logSafeError/SafeError/UnauthorizedError,
// logPlaidOperation-style structured logging) are already defined there in fully generic form —
// imported from there by both sync-manual-data/index.ts and get-manual-account-data/index.ts
// rather than duplicated here, matching this project's existing "one implementation, reused"
// discipline. Only pure functions specific to Manual Account/Transaction row-shape validation and
// mapping live in this file.

/// Mirrors the local `AccountType` enum's raw values exactly (Account.swift).
const VALID_ACCOUNT_TYPES: ReadonlySet<string> = new Set(["checking", "savings", "creditCard", "cash", "other"]);

export function isValidAccountType(value: unknown): value is string {
  return typeof value === "string" && VALID_ACCOUNT_TYPES.has(value);
}

/// Mirrors the local `TransactionType` enum's raw values exactly (TransactionType.swift).
const VALID_TRANSACTION_TYPES: ReadonlySet<string> = new Set([
  "expense",
  "income",
  "transfer",
  "creditCardPayment",
  "refund",
  "balanceAdjustment",
]);

export function isValidTransactionType(value: unknown): value is string {
  return typeof value === "string" && VALID_TRANSACTION_TYPES.has(value);
}

/// A bare "YYYY-MM-DD" calendar-date string check — deliberately does NOT parse it into a Date/
/// instant anywhere in this file (see migration 0011's own DATE SEMANTICS comment for why: the
/// client is responsible for resolving its local `Date` to local calendar components BEFORE this
/// string ever reaches here, and this file must never reintroduce a timezone-anchoring step by
/// constructing a `Date` from it). Only checks the literal shape.
const BARE_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

export function isValidBareDate(value: unknown): value is string {
  return typeof value === "string" && BARE_DATE_PATTERN.test(value);
}

/// The exact row shape upserted into public.manual_accounts. `owner_user_id` is supplied
/// separately by the caller (the Edge Function, from its own server-verified identity) — never
/// read from the client payload itself, so a client can never supply/spoof an owner_user_id (see
/// sync-manual-data/index.ts's own header for the full trust-boundary argument).
export interface ManualAccountRow {
  id: string;
  owner_user_id: string;
  name: string;
  account_type: string;
  current_balance: number;
  institution_name: string | null;
  last_four_digits: string | null;
  shows_in_recent_activity: boolean;
  created_at: string;
  updated_at: string;
}

/// Raw shape one Manual Account payload from the iOS client must have — validated field-by-field
/// by `buildManualAccountRow` below, never trusted as-is.
export interface RawManualAccountInput {
  id: unknown;
  name: unknown;
  account_type: unknown;
  current_balance: unknown;
  institution_name?: unknown;
  last_four_digits?: unknown;
  shows_in_recent_activity: unknown;
  created_at: unknown;
  updated_at: unknown;
}

export type ManualAccountValidationError =
  | "invalid_id"
  | "invalid_name"
  | "invalid_account_type"
  | "invalid_current_balance"
  | "invalid_shows_in_recent_activity"
  | "invalid_created_at"
  | "invalid_updated_at";

/// Pure validation + mapping — returns either a ready-to-upsert row or the specific reason it was
/// rejected (never throws). `isValidUuid` is passed in rather than imported directly so this file
/// stays independent of ../_shared/plaid.ts's own module (avoids a circular/needless coupling for
/// what is, structurally, a generic string-shape check with nothing Plaid-specific about it).
export function buildManualAccountRow(
  input: RawManualAccountInput,
  ownerUserId: string,
  isValidUuid: (value: unknown) => value is string,
): { row: ManualAccountRow } | { error: ManualAccountValidationError } {
  if (!isValidUuid(input.id)) return { error: "invalid_id" };
  if (typeof input.name !== "string" || input.name.length === 0) return { error: "invalid_name" };
  if (!isValidAccountType(input.account_type)) return { error: "invalid_account_type" };

  const currentBalance = typeof input.current_balance === "string" ? Number(input.current_balance) : NaN;
  if (!Number.isFinite(currentBalance)) return { error: "invalid_current_balance" };

  if (typeof input.shows_in_recent_activity !== "boolean") return { error: "invalid_shows_in_recent_activity" };

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
      account_type: input.account_type,
      current_balance: currentBalance,
      institution_name: typeof input.institution_name === "string" ? input.institution_name : null,
      last_four_digits: typeof input.last_four_digits === "string" ? input.last_four_digits : null,
      shows_in_recent_activity: input.shows_in_recent_activity,
      created_at: input.created_at,
      updated_at: input.updated_at,
    },
  };
}

/// The exact row shape upserted into public.manual_transactions. Same anti-spoofing posture as
/// `ManualAccountRow` — `owner_user_id` is never read from the client payload.
export interface ManualTransactionRow {
  id: string;
  manual_account_id: string;
  owner_user_id: string;
  amount: number;
  transaction_type: string;
  transaction_date: string;
  note: string;
  category_name: string | null;
  is_pending: boolean;
  created_at: string;
  updated_at: string;
}

export interface RawManualTransactionInput {
  id: unknown;
  manual_account_id: unknown;
  amount: unknown;
  transaction_type: unknown;
  transaction_date: unknown;
  note: unknown;
  category_name?: unknown;
  is_pending: unknown;
  created_at: unknown;
  updated_at: unknown;
}

export type ManualTransactionValidationError =
  | "invalid_id"
  | "invalid_manual_account_id"
  | "invalid_amount"
  | "invalid_transaction_type"
  | "invalid_transaction_date"
  | "invalid_note"
  | "invalid_is_pending"
  | "invalid_created_at"
  | "invalid_updated_at";

/// Pure validation + mapping. Does NOT verify that `manual_account_id` belongs to `ownerUserId` —
/// that requires a database lookup (which account ids this caller actually owns), so it is the
/// caller's (sync-manual-data/index.ts's) responsibility, checked BEFORE calling this function for
/// each transaction (see that file's own header for why: a transaction whose account isn't owned
/// by the caller must be skipped, never silently reassigned or upserted anyway).
export function buildManualTransactionRow(
  input: RawManualTransactionInput,
  ownerUserId: string,
  isValidUuid: (value: unknown) => value is string,
): { row: ManualTransactionRow } | { error: ManualTransactionValidationError } {
  if (!isValidUuid(input.id)) return { error: "invalid_id" };
  if (!isValidUuid(input.manual_account_id)) return { error: "invalid_manual_account_id" };

  const amount = typeof input.amount === "string" ? Number(input.amount) : NaN;
  if (!Number.isFinite(amount)) return { error: "invalid_amount" };

  if (!isValidTransactionType(input.transaction_type)) return { error: "invalid_transaction_type" };
  if (!isValidBareDate(input.transaction_date)) return { error: "invalid_transaction_date" };
  if (typeof input.note !== "string") return { error: "invalid_note" };
  if (typeof input.is_pending !== "boolean") return { error: "invalid_is_pending" };

  if (typeof input.created_at !== "string" || Number.isNaN(Date.parse(input.created_at))) {
    return { error: "invalid_created_at" };
  }
  if (typeof input.updated_at !== "string" || Number.isNaN(Date.parse(input.updated_at))) {
    return { error: "invalid_updated_at" };
  }

  return {
    row: {
      id: input.id,
      manual_account_id: input.manual_account_id,
      owner_user_id: ownerUserId,
      amount,
      transaction_type: input.transaction_type,
      transaction_date: input.transaction_date,
      note: input.note,
      category_name: typeof input.category_name === "string" ? input.category_name : null,
      is_pending: input.is_pending,
      created_at: input.created_at,
      updated_at: input.updated_at,
    },
  };
}

/// Splits a batch of Manual Account payloads into validated rows and rejected entries (with their
/// specific reason), so sync-manual-data can upsert the valid ones and report exactly which ids
/// were skipped and why — never silently drop a malformed entry with no explanation, and never let
/// one malformed entry block the rest of the batch.
export interface ManualAccountSyncPlan {
  rows: ManualAccountRow[];
  rejected: { id: unknown; error: ManualAccountValidationError }[];
}

export function planManualAccountSync(
  inputs: RawManualAccountInput[],
  ownerUserId: string,
  isValidUuid: (value: unknown) => value is string,
): ManualAccountSyncPlan {
  const rows: ManualAccountRow[] = [];
  const rejected: { id: unknown; error: ManualAccountValidationError }[] = [];
  for (const input of inputs) {
    const result = buildManualAccountRow(input, ownerUserId, isValidUuid);
    if ("row" in result) rows.push(result.row);
    else rejected.push({ id: input.id, error: result.error });
  }
  return { rows, rejected };
}

/// Same shape as `planManualAccountSync`, plus `skippedForeignAccount` for transactions whose
/// `manual_account_id` doesn't resolve to an account THIS caller owns — populated by the caller
/// (sync-manual-data/index.ts), which is the one with database access to check ownership; this
/// function only separates "structurally valid" from "structurally invalid."
export interface ManualTransactionSyncPlan {
  rows: ManualTransactionRow[];
  rejected: { id: unknown; error: ManualTransactionValidationError }[];
}

export function planManualTransactionSync(
  inputs: RawManualTransactionInput[],
  ownerUserId: string,
  isValidUuid: (value: unknown) => value is string,
): ManualTransactionSyncPlan {
  const rows: ManualTransactionRow[] = [];
  const rejected: { id: unknown; error: ManualTransactionValidationError }[] = [];
  for (const input of inputs) {
    const result = buildManualTransactionRow(input, ownerUserId, isValidUuid);
    if ("row" in result) rows.push(result.row);
    else rejected.push({ id: input.id, error: result.error });
  }
  return { rows, rejected };
}
