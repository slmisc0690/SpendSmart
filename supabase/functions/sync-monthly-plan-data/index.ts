// Supabase Edge Function: sync-monthly-plan-data
//
// PHASE 6 — MONTHLY PLAN CLOUD SYNCHRONIZATION FOUNDATION. Authored as backend foundation work;
// NOT deployed. One compact function handling every OWNER write operation (settings upsert,
// income source create/update/delete, recurring expense create/update/delete) in a single
// authenticated batch call — same "one function, multiple operations" design already established
// by sync-manual-data (Phase 5), per this phase's own instruction to inspect whether one function
// can safely cover multiple operations before creating several.
//
// TRUST BOUNDARY: iOS -> this function -> requireAuthenticatedUserId() -> server-verified caller
// identity -> upsert/delete against public.monthly_plan_settings/monthly_plan_income_sources/
// monthly_plan_recurring_expenses, via this function's own privileged (service_role) client. The
// request body carries NO owner_user_id field anywhere — every row's owner_user_id is set here,
// from the verified caller identity only. Settings' primary key IS owner_user_id itself, so an
// upsert there can only ever target the caller's own row — no separate ownership-conflict check
// is possible or needed for settings (see migration 0012's own header). Income sources and
// recurring expenses each have an independent client-supplied `id`, so BOTH get the exact same
// pre-upsert ownership-conflict check discovered necessary for manual_accounts in Phase 5B (see
// splitByOwnershipConflict in ../_shared/monthlyPlan.ts) — an id already owned by someone else is
// skipped and reported, never upserted, never silently reassigned.
//
// IDEMPOTENCY: every upsert targets its table's primary key as the conflict key (`owner_user_id`
// for settings, `id` for income sources/recurring expenses) — replaying the exact same sync
// updates the same row(s) in place, never duplicates them.
//
// DELETES: scoped by `id = ANY(...) AND owner_user_id = <verified caller>` for both income
// sources and recurring expenses — never a bare id match — so a caller can never delete a row
// they don't own even if a foreign id somehow appeared in their delete list. Settings has no
// delete path (a singleton row is only ever upserted, matching the local model's own
// "singleton-style settings record" design — there is nothing to individually delete).
//
// FAILURE ISOLATION: this function's entire job is server-side sync bookkeeping — a failure here
// must never be capable of touching, let alone corrupting or deleting, the caller's local
// SwiftData store, which remains authoritative for that owner's own UI in this phase. This
// function performs no local-data-affecting response at all; it only acknowledges what was/wasn't
// synced.
//
// AUTH: verify_jwt = false at the gateway (same reason as every other user-invoked function in
// this project — see ../_shared/plaid.ts's file header).

import {
  createPrivilegedClient,
  isValidUuid,
  jsonResponse,
  logPlaidOperation,
  logSafeError,
  requireAuthenticatedUserId,
  SafeError,
  UnauthorizedError,
} from "../_shared/plaid.ts";
import {
  buildMonthlyPlanSettingsRow,
  planMonthlyPlanIncomeSourceSync,
  planMonthlyPlanRecurringExpenseSync,
  type RawMonthlyPlanIncomeSourceInput,
  type RawMonthlyPlanRecurringExpenseInput,
  type RawMonthlyPlanSettingsInput,
  splitByOwnershipConflict,
} from "../_shared/monthlyPlan.ts";

function asArray<T>(value: unknown): T[] {
  return Array.isArray(value) ? (value as T[]) : [];
}

function asIdArray(value: unknown): string[] {
  return asArray<unknown>(value).filter((v): v is string => isValidUuid(v));
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  console.log("[sync-monthly-plan-data] handler entered");

  const supabase = createPrivilegedClient();

  let userId: string;
  try {
    userId = await requireAuthenticatedUserId(req, supabase);
  } catch (error) {
    logSafeError("sync-monthly-plan-data auth failed", error);
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const body = await req.json().catch(() => ({}));
  const settingsInput = body.settings as RawMonthlyPlanSettingsInput | undefined;
  const incomeSourceInputs = asArray<RawMonthlyPlanIncomeSourceInput>(body.income_sources);
  const recurringExpenseInputs = asArray<RawMonthlyPlanRecurringExpenseInput>(body.recurring_expenses);
  const deletedIncomeSourceIds = asIdArray(body.deleted_income_source_ids);
  const deletedRecurringExpenseIds = asIdArray(body.deleted_recurring_expense_ids);

  try {
    // 1. Settings — upsert keyed on owner_user_id itself (see this file's own header for why no
    // ownership-conflict check is needed here).
    let settingsSynced = false;
    let settingsRejectedReason: string | null = null;
    if (settingsInput) {
      const settingsResult = buildMonthlyPlanSettingsRow(settingsInput, userId);
      if ("row" in settingsResult) {
        const { error: settingsUpsertError } = await supabase
          .from("monthly_plan_settings")
          .upsert(settingsResult.row, { onConflict: "owner_user_id" });
        if (settingsUpsertError) throw settingsUpsertError;
        settingsSynced = true;
      } else {
        settingsRejectedReason = settingsResult.error;
      }
    }

    // 2. Income sources — structural validation, then ownership-conflict filtering (Phase 5B
    // lesson applied proactively) before upserting.
    const incomeSourcePlan = planMonthlyPlanIncomeSourceSync(incomeSourceInputs, userId, isValidUuid);
    let ownedIncomeSourceRows = incomeSourcePlan.rows;
    let skippedForeignIncomeSourceIds: string[] = [];
    if (incomeSourcePlan.rows.length > 0) {
      const requestedIds = incomeSourcePlan.rows.map((row) => row.id);
      const { data: existingRows, error: existingError } = await supabase
        .from("monthly_plan_income_sources")
        .select("id, owner_user_id")
        .in("id", requestedIds);
      if (existingError) throw existingError;
      const existingOwnersById = new Map((existingRows ?? []).map((row) => [row.id as string, row.owner_user_id as string]));
      const split = splitByOwnershipConflict(incomeSourcePlan.rows, userId, existingOwnersById);
      ownedIncomeSourceRows = split.ownedRows;
      skippedForeignIncomeSourceIds = split.foreignConflictIds;
    }
    if (ownedIncomeSourceRows.length > 0) {
      const { error: incomeUpsertError } = await supabase
        .from("monthly_plan_income_sources")
        .upsert(ownedIncomeSourceRows, { onConflict: "id" });
      if (incomeUpsertError) throw incomeUpsertError;
    }

    // 3. Recurring expenses — identical treatment to income sources.
    const recurringExpensePlan = planMonthlyPlanRecurringExpenseSync(recurringExpenseInputs, userId, isValidUuid);
    let ownedRecurringExpenseRows = recurringExpensePlan.rows;
    let skippedForeignRecurringExpenseIds: string[] = [];
    if (recurringExpensePlan.rows.length > 0) {
      const requestedIds = recurringExpensePlan.rows.map((row) => row.id);
      const { data: existingRows, error: existingError } = await supabase
        .from("monthly_plan_recurring_expenses")
        .select("id, owner_user_id")
        .in("id", requestedIds);
      if (existingError) throw existingError;
      const existingOwnersById = new Map((existingRows ?? []).map((row) => [row.id as string, row.owner_user_id as string]));
      const split = splitByOwnershipConflict(recurringExpensePlan.rows, userId, existingOwnersById);
      ownedRecurringExpenseRows = split.ownedRows;
      skippedForeignRecurringExpenseIds = split.foreignConflictIds;
    }
    if (ownedRecurringExpenseRows.length > 0) {
      const { error: expenseUpsertError } = await supabase
        .from("monthly_plan_recurring_expenses")
        .upsert(ownedRecurringExpenseRows, { onConflict: "id" });
      if (expenseUpsertError) throw expenseUpsertError;
    }

    // 4. Deletes — scoped by id AND owner_user_id, never a bare id match.
    let deletedIncomeSourceIdsResult: string[] = [];
    if (deletedIncomeSourceIds.length > 0) {
      const { data: deletedRows, error: deleteError } = await supabase
        .from("monthly_plan_income_sources")
        .delete()
        .in("id", deletedIncomeSourceIds)
        .eq("owner_user_id", userId)
        .select("id");
      if (deleteError) throw deleteError;
      deletedIncomeSourceIdsResult = (deletedRows ?? []).map((row) => row.id as string);
    }

    let deletedRecurringExpenseIdsResult: string[] = [];
    if (deletedRecurringExpenseIds.length > 0) {
      const { data: deletedRows, error: deleteError } = await supabase
        .from("monthly_plan_recurring_expenses")
        .delete()
        .in("id", deletedRecurringExpenseIds)
        .eq("owner_user_id", userId)
        .select("id");
      if (deleteError) throw deleteError;
      deletedRecurringExpenseIdsResult = (deletedRows ?? []).map((row) => row.id as string);
    }

    logPlaidOperation({
      operation: "sync-monthly-plan-data",
      outcome: "success",
      accountCount: ownedIncomeSourceRows.length + ownedRecurringExpenseRows.length,
    });

    return jsonResponse({
      settings_synced: settingsSynced,
      settings_rejected_reason: settingsRejectedReason,
      synced_income_source_ids: ownedIncomeSourceRows.map((r) => r.id),
      synced_recurring_expense_ids: ownedRecurringExpenseRows.map((r) => r.id),
      deleted_income_source_ids: deletedIncomeSourceIdsResult,
      deleted_recurring_expense_ids: deletedRecurringExpenseIdsResult,
      rejected_income_sources: incomeSourcePlan.rejected,
      rejected_recurring_expenses: recurringExpensePlan.rejected,
      skipped_foreign_income_source_id_conflicts: skippedForeignIncomeSourceIds,
      skipped_foreign_recurring_expense_id_conflicts: skippedForeignRecurringExpenseIds,
    });
  } catch (error) {
    logSafeError("sync-monthly-plan-data failed", error);
    if (error instanceof UnauthorizedError) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }
    if (error instanceof SafeError) {
      return jsonResponse({ error: error.message }, 500);
    }
    return jsonResponse({ error: "Failed to sync monthly plan data" }, 500);
  }
});
