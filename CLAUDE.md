# SpendSmart (FinanceTrack) — Project Notes for Claude

iOS SwiftUI/SwiftData personal finance app ("SpendSmart" user-facing, "FinanceTrack" internal/repo
name) with a Supabase backend for Plaid bank-linking and household sharing. Single main developer
(Scott), long-running iterative sessions — this file exists so a fresh session doesn't have to
re-derive architecture/conventions from scratch.

## Repository / environment facts

- Path: `/Users/scott/Documents/Apple Apps/FinanceTracker`, branch `main`.
- Xcode project is generated via `xcodegen` from `project.yml` — after any file add/move, run
  `xcodegen generate` before building.
- No Docker locally — `supabase db dump`/`diff` (schema-shadow-db features) and `deno test` are
  **not runnable locally**. Local verification is: full `xcodebuild build` + `xcodebuild test`,
  plus direct code review of SQL/Deno source. Live/empirical DB and Edge Function verification
  requires deploying to the **preview branch** (see below) and testing there over HTTPS via
  `curl`/`supabase db query --linked`.
- Supabase projects:
  - **Production**: ref `dlqjgpgnaguhubftfpel`, name "SpendSmart", region `ca-central-1`. This is
    what `supabase ... --linked` targets — confirmed via `supabase projects list`, but always
    double-check explicitly before any deploy, never assume.
  - **Preview branch**: `phase2-sharing-test`, project ref `kzyvkywpnfvxlgvrgkpm`, parent =
    Production. Use `supabase db push --db-url <preview-non-pooling-url>` (never `--linked`,
    which points at Production) to migrate the preview safely. Get its connection info via
    `supabase branches get phase2-sharing-test --project-ref dlqjgpgnaguhubftfpel --output json`.
  - Production has automatic daily physical backups (`walg_enabled: true`, `pitr_enabled: false`
    as of 2026-07). Check via `supabase backups list --project-ref dlqjgpgnaguhubftfpel` before
    any migration — this is the real backup/checkpoint, not a local file copy.

## Standing workflow rules (established over many turns, not just suggestions)

- **Never modify without explicit permission** — global rule from `~/.claude/CLAUDE.md`. In
  practice this project's owner gives long, itemized, phase-by-phase task briefs that already
  authorize specific actions (including deploys) — treat that itemized brief as the permission,
  don't re-ask for each line item inside it, but never go beyond its stated scope.
- **Preview before Production, always.** New migrations/Edge Functions get authored, then
  deployed+empirically tested on `phase2-sharing-test` first. Production deployment is a
  **separate, explicitly-requested task** with its own backup-verification and read-only
  post-deploy checks. Never deploy a migration/function to Production in the same turn it was
  written, unless the user's own instructions explicitly say so for that turn.
- **Backup before editing source**, per the global standing rule — for this repo that means a full
  working-tree copy (rsync) to `../FinanceTracker Backups/<label>-<timestamp>/`, **excluding**
  `.git`, `build/` (Xcode's local index cache — huge file count, not real source, rsync will stall
  copying it), and `*.xcuserstate`. Verify with `diff -rq` (same excludes) before editing.
- **Full Swift build + full test suite, zero new warnings**, before any "done" report. Report the
  *actual* test total from that run, never assume a remembered number.
- **Final reports** follow a consistent numbered-section format (safety baseline → root
  cause/design → security → files → tests → validation → git summary → exclusions confirmed →
  deployment status with explicit YES/NO lines → RESULT: PASS/BLOCKED). Keep using that shape —
  it's what the user expects and cross-references against.
- **Never commit or push** unless explicitly asked. The working tree is deliberately kept dirty
  across sessions with many completed-but-uncommitted features; don't "clean up" by committing
  without being told to.
- Known dirty working-tree baseline (uncommitted, intentional, as of 2026-07-19) — if `git status
  --short` ever shows something NOT in this list, stop and ask before touching anything:
  - Modified: `FinanceTrack.xcodeproj/project.pbxproj`, `FinanceTrack/App/FinanceTrackApp.swift`,
    `FinanceTrack/Auth/{AuthFlowView,AuthTextField,CreateAccountView,SignInView}.swift`,
    `FinanceTrack/Models/{Account,BudgetSettings,FinanceTransaction,IncomeSource,
    MonthlyPlanSettings,RecurringExpense}.swift`,
    `FinanceTrack/Services/{AutoBackupManager,BiometricAuthManager,MonthlyPlanCalculator,
    PlaidConnectionManager}.swift`,
    `FinanceTrack/Sync/{ConnectedAccountsDashboardPresenter,PlaidBackendService,
    PlaidTransactionImportService}.swift`,
    `FinanceTrack/Views/Dashboard/DashboardView.swift`,
    `FinanceTrack/Views/Monthly/MonthlyGoalEditView.swift`,
    `FinanceTrack/Views/Settings/{ConnectedAccountsView,SettingsView}.swift`,
    `FinanceTrack/Views/Weekly/WeeklyLimitEditView.swift`,
    `FinanceTrackTests/FinanceTrackTests.swift`, `supabase/config.toml`,
    `supabase/functions/_shared/plaid.ts`, `supabase/functions/create-link-token/index.ts`.
  - New (untracked/staged): `FinanceTrack/Services/{LegacyDataMigrator,UserDataStoreManager}.swift`,
    `FinanceTrack/Views/Components/RefreshPillButton.swift`,
    `FinanceTrackTests/UserDataIsolationTests.swift`,
    `supabase/functions/refresh-connected-account/index.ts`,
    `supabase/migrations/{0008_household_sharing_core,0009_connected_account_refresh_log}.sql`.
  - **Anomaly to flag, not silently fix**: a `FinanceTrack 2.xcodeproj/` directory appeared
    (staged `A`) alongside the real `FinanceTrack.xcodeproj/` — looks like an accidental Xcode
    duplicate-project artifact, not something any task intentionally created. Ask Scott about it
    before touching it.

## Architecture landmarks

- **Plaid sync chain**: `supabase/functions/sync-transactions` (backend, sends bare
  `authorized_date`/`date` strings) → `PlaidBackendService.BackendTransactionDTO` (custom decode,
  `parseBareDate` builds **local-midnight** `Date` via `Calendar.current`, never UTC-anchored) →
  `PlaidTransactionImportService.applySync` (upsert by `externalTransactionId`, pending→posted
  merge, and a **self-healing stale-date repair sweep** — see below) → SwiftData
  `FinanceTransaction` → Dashboard/Activity display (both read `transaction.date` directly, no
  separate day-bucketing logic).
- **Stale-date repair** (`PlaidTransactionImportService.repairStaleUTCMidnightDate`): corrects
  transactions imported before the local-midnight parser fix shipped. Detects the old bug's exact
  signature (`Date` reading back as precisely UTC midnight) and reconstructs local midnight for
  the same Y/M/D — lossless, safe, no schema change, runs on every `applySync` call over ALL
  existing `source == .plaid` rows (not just this sync's payload), since Plaid's delta-cursor never
  redelivers an unchanged transaction so waiting for redelivery alone would never fix old rows.
- **Connected Account Dashboard Refresh** (per-account, rate-limited): `RefreshPillButton` (UI) →
  `DashboardView` (owns `refreshingAccountKeys`/`rateLimitedAccountKeys` state, keyed by
  `Display.id`) → `PlaidConnectionManager.refreshAccountBalance(connectionId:accountId:)` — this is
  the ONLY place allowed to reference `PlaidBackendService` for this flow, because
  `DashboardView.swift` has a literal source-scan test
  (`testDashboardStillNeverCallsPlaidDirectlyAfterRawBalanceRestore`) asserting it never contains
  the strings `PlaidBackendService`/`syncBalances`/`refreshPlaidAccounts` — Dashboard balance
  display must stay cache-only. → `refresh-connected-account` Edge Function → migration 0009's
  `claim_connected_account_refresh`/`release_connected_account_refresh` (atomic, UTC-calendar-day,
  max 2/day per user+account, claim-before-Plaid-call with release-on-failure so a network/Plaid
  error never costs the user an attempt).
- **Per-user local isolation** (Phase 3): `UserDataStoreManager` + `LegacyDataMigrator` give each
  authenticated user their own SwiftData container; `PlaidConnectionManager` is namespaced per
  user too.
- **Household sharing** (migration 0008): households/household_members/household_invitations/
  sharing_permissions/user_profiles — schema exists and is applied to Production, but the
  Primary/Secondary sharing UI itself has **not been built yet** ("Phase 4", repeatedly explicitly
  out of scope until asked for).
- **SQL convention** for every privileged function: `SECURITY DEFINER` + `SET search_path = ''` +
  full schema-qualification + explicit `REVOKE ... FROM PUBLIC, anon, authenticated, service_role`
  then `GRANT ... TO service_role` only. Rate-limit style tables use a single
  `INSERT ... ON CONFLICT ... DO UPDATE ... WHERE ... RETURNING` for atomic claim-with-limit (no
  separate SELECT-then-decide step — that's the race the pattern exists to avoid).
- **Calendar-day boundary** for any per-day server limit: UTC, always — there is no user-timezone
  storage anywhere in this schema, and inventing one has been repeatedly ruled out-of-scope.

## Testing conventions

- Swift tests live in one large `FinanceTrackTests/FinanceTrackTests.swift` (plus a separate
  `UserDataIsolationTests.swift`) — follow existing naming/structure (`test<Subject><Behavior>`,
  `@MainActor` on anything touching a `ModelContext`/`ModelContainer`).
  `Self.calendar(timeZoneIdentifier:)` is the established helper for timezone-parameterized date
  tests — reuse it rather than inventing a new one.
  `makePlaidSyncTestContext()`/`makePlaidDTO(...)` are the established helpers for
  `PlaidTransactionImportService` tests.
  Prefer real decode → persist → reload → calendar-component assertions over pure source-string
  tests where feasible.
- Backend: `supabase/functions/_shared/plaid.test.ts` via `deno test --allow-env <path>` — not
  runnable locally (no deno installed), verify by code review; note this explicitly in any report
  rather than silently skipping it.
