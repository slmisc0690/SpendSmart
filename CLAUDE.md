# SpendSmart (FinanceTrack) — Project Notes for Claude

iOS SwiftUI/SwiftData personal finance app ("SpendSmart" user-facing, "FinanceTrack" internal/repo
name) with a Supabase backend for Plaid bank-linking and household sharing. Single main developer
(Scott), long-running iterative sessions — this file exists so a fresh session doesn't have to
re-derive architecture/conventions from scratch.

## Current Status (as of 2026-07-21)

Phase 8F (Secondary Invitation + Share-Back Production Deployment) is complete: migration 0015 and
its 5 Edge Functions are live on Production, verified via a 25-section report (PASS). The full
household-sharing feature set — Primary invites/manages sharing, Secondary auto-discovers/accepts/
declines/shares back their own accounts — is now live end-to-end in Production for real users. See
Session Log below for this session's specifics. The working tree was committed for the first time
in this session after months of intentionally-uncommitted iterative work — see the git commit this
session produced for exactly what landed.

## Next Step

No specific follow-up phase has been requested yet — await Scott's next task brief. Known
candidates if asked: real end-to-end manual testing per Phase 8F's recommended sequence (invitation
popup on foreground return, Accept/Decline, Secondary share-back visibility to Primary), Secondary
Monthly Plan visibility polish, or investigating the `FinanceTrack 2.xcodeproj` anomaly (see Known
Issues below).

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
  *actual* test total from that run, never assume a remembered number. As of 2026-07-21 the suite
  is at **1020 tests**.
- **Final reports** follow a consistent numbered-section format (safety baseline → root
  cause/design → security → files → tests → validation → git summary → exclusions confirmed →
  deployment status with explicit YES/NO lines → RESULT: PASS/BLOCKED). Keep using that shape —
  it's what the user expects and cross-references against.
- **Never commit or push** unless explicitly asked. Historically the working tree was kept
  deliberately dirty across sessions with many completed-but-uncommitted features; the first commit
  landed 2026-07-21 (explicitly requested — see Session Log). This rule remains in force going
  forward: don't commit/push proactively just because a task finished.
- Known dirty working-tree baseline **immediately before the 2026-07-21 commit** (for historical
  reference — once committed this snapshot is obsolete; always check `git status --short` fresh
  rather than trusting a stored list):
  - Modified: `FinanceTrack.xcodeproj/project.pbxproj`, `FinanceTrack/App/FinanceTrackApp.swift`,
    `FinanceTrack/Services/AccountRelatedOptionsViewModel.swift`,
    `FinanceTrack/Sync/{HouseholdSharingPayload,HouseholdSharingService}.swift`,
    `FinanceTrack/Views/Settings/{AccountRelatedOptionsView,AccountView,SettingsView}.swift`,
    `FinanceTrackTests/FinanceTrackTests.swift`, `supabase/config.toml`,
    `supabase/functions/{accept-household-invitation,get-account-related-options,
    update-sharing-permission}/index.ts`.
  - New (untracked): `FinanceTrack/Services/PendingInvitationPopupViewModel.swift`,
    `FinanceTrack/Views/Settings/PendingInvitationPopupView.swift`,
    `supabase/functions/{decline-household-invitation,get-my-pending-household-invitation}/`,
    `supabase/migrations/0015_secondary_connected_account_sharing.sql`.
  - `Untitled 5.rtfd/` — unrelated macOS TextEdit document in the repo root. **Leave it untouched.**
    Do NOT delete, modify, move, stage, or add it to Xcode.
  - **Anomaly, not resolved**: `FinanceTrack 2.xcodeproj/` (a duplicate-project artifact) is already
    tracked in git history (not part of any pending change) — see Known Issues below.

## Known Issues / Anomalies

- **`FinanceTrack 2.xcodeproj/` duplicate project directory** exists alongside the real
  `FinanceTrack.xcodeproj/` and is already committed to git history. Looks like an accidental
  Xcode duplicate-project artifact, not something any task intentionally created. Not touched or
  investigated in this session — ask Scott before touching it if it comes up.
- No new issues were found during Phase 8F (2026-07-21) — Production data checksums, unrelated
  Edge Function versions, and the Swift test suite all matched baseline exactly with zero anomalies.

## Feature Roadmap / Completed Features

- [x] Plaid transaction sync, normalization (`plaid_transactions`), local-midnight date parsing,
      and self-healing stale-UTC-midnight-date repair sweep
- [x] Per-account, rate-limited Connected Account Dashboard Refresh (cache-only Dashboard, enforced
      by a source-scan test)
- [x] Per-user local SwiftData isolation (`UserDataStoreManager` + `LegacyDataMigrator`)
- [x] Manual accounts/transactions cloud sync (owner path + shared-read path)
- [x] Monthly Plan settings/income-sources/recurring-expenses cloud sync (owner path, global-only
      sharing)
- [x] Household sharing core schema (households/household_members/household_invitations/
      sharing_permissions/user_profiles) + directionless `is_effectively_shared_for_user` evaluator
- [x] Primary-only Account Related Options UI (Connected/Manual per-item + global sharing toggles,
      Monthly Plan global toggle)
- [x] Manual household invitation flow (Primary generates link) + Secondary acceptance screen via
      deep link (migration 0014)
- [x] Optimistic sharing-toggle UI (eliminates visible write latency via
      `optimisticSharingOverrides`)
- [x] Sign Out / Delete Account styling + repositioning (red pill buttons, Delete Account last)
- [x] Secondary automatic pending-invitation discovery (no link/token needed) + Accept/Decline +
      foreground-return re-check (migration 0015, `PendingInvitationPopupViewModel`)
- [x] Secondary → Primary share-back for the Secondary's own Connected accounts and own Manual
      accounts (per-item, auto-bootstrapped category toggle, migration 0015)
- [x] **All of the above deployed and verified on Production** (migrations 0008–0015, all
      associated Edge Functions) — Phase 8F, 2026-07-21

Not yet built (explicitly out of scope until requested):
- [ ] Secondary-side Monthly Plan sharing/control — Secondary remains read-only via the Primary's
      global toggle; no Secondary Monthly Plan UI exists
- [ ] Resolution of the `FinanceTrack 2.xcodeproj` duplicate-project anomaly

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
- **Household sharing** (migration 0008, core schema; migrations 0013–0015, UI + invitation +
  share-back layers): households/household_members/household_invitations/sharing_permissions/
  user_profiles, with a directionless `is_effectively_shared_for_user` evaluator — `owner_user_id`
  can structurally be any active member (Primary or Secondary); the evaluator only checks active
  membership + an owner-marked share. **Fully built and live on Production as of 2026-07-21**:
  - Primary: `AccountRelatedOptionsView`/`AccountRelatedOptionsViewModel` — Connected/Manual
    per-item + global sharing toggles (optimistic UI), Monthly Plan global toggle, invitation
    send/manage.
  - Secondary discovery/accept/decline: `PendingInvitationPopupViewModel`/`PendingInvitationPopupView`
    — auto-checks once per session transition (`RootView.task`) and again on genuine
    foreground-return (`recheckOnForegroundIfNeeded()`, wired into `FinanceTrackApp`'s
    `.onChange(of: scenePhase)`), backed by `find_pending_invitation_for_email` (parameterless,
    enumeration-proof) + `accept_household_invitation_by_id`/`decline_household_invitation_by_id`.
  - Secondary share-back: `set_secondary_connected_account_sharing`/
    `set_secondary_manual_account_sharing` (migration 0015) — Secondary shares only their own
    accounts (re-verified ownership at both Edge Function and DB-function layers), auto-bootstraps
    the category's global toggle exactly once since Secondaries have no global toggle of their own.
  - Secondary has **no Monthly Plan control** — read-only via the Primary's global toggle, by
    design.
- **SQL convention** for every privileged function: `SECURITY DEFINER` + `SET search_path = ''` +
  full schema-qualification + explicit `REVOKE ... FROM PUBLIC, anon, authenticated, service_role`
  then `GRANT ... TO service_role` only. Rate-limit style tables use a single
  `INSERT ... ON CONFLICT ... DO UPDATE ... WHERE ... RETURNING` for atomic claim-with-limit (no
  separate SELECT-then-decide step — that's the race the pattern exists to avoid).
- **Calendar-day boundary** for any per-day server limit: UTC, always — there is no user-timezone
  storage anywhere in this schema, and inventing one has been repeatedly ruled out-of-scope.
- **Anti-enumeration**: every sharing/invitation-facing response is designed so a caller can never
  distinguish "doesn't exist" from "exists but not authorized/shared" (generic error messages,
  parameterless self-lookup functions where possible).

## Testing conventions

- Swift tests live in one large `FinanceTrackTests/FinanceTrackTests.swift` (plus a separate
  `UserDataIsolationTests.swift`) — follow existing naming/structure (`test<Subject><Behavior>`,
  `@MainActor` on anything touching a `ModelContext`/`ModelContainer`).
  `Self.calendar(timeZoneIdentifier:)` is the established helper for timezone-parameterized date
  tests — reuse it rather than inventing a new one.
  `makePlaidSyncTestContext()`/`makePlaidDTO(...)` are the established helpers for
  `PlaidTransactionImportService` tests.
  `FakeHouseholdSharingService` is the established test double for household-sharing view model
  tests (extend it with new result/call-count/hook properties rather than writing a new double).
  Prefer real decode → persist → reload → calendar-component assertions over pure source-string
  tests where feasible.
- Backend: `supabase/functions/_shared/plaid.test.ts` via `deno test --allow-env <path>` — not
  runnable locally (no deno installed), verify by code review; note this explicitly in any report
  rather than silently skipping it.
- If Xcode simulator DerivedData is cleared, SPM package checkouts go with it — run
  `xcodebuild -resolvePackageDependencies` before the next build or it fails with a "package
  manifest cannot be accessed" error (hit and fixed during Phase 8F, 2026-07-21).

## Session Log

### 2026-07-21 — Phase 8F: Secondary Invitation + Share-Back Production Deployment
- Deployed migration 0015 to Production: `set_secondary_connected_account_sharing`,
  `set_secondary_manual_account_sharing`, `find_pending_invitation_for_email`,
  `accept_household_invitation_by_id`, `decline_household_invitation_by_id`, plus widening the
  `household_invitations.status` CHECK constraint to add `'declined'`.
- Deployed 5 Edge Functions to Production: `get-my-pending-household-invitation` (new),
  `decline-household-invitation` (new), `accept-household-invitation` (v1→v2, dual token/
  invitation_id support), `update-sharing-permission` (v1→v2, Secondary share-back branch),
  `get-account-related-options` (v1→v2, Secondary own-accounts-only branch).
- Verified live: all 5 SQL functions correctly `SECURITY DEFINER`/`search_path=''`/service_role-
  only grants; all 15 unrelated Production Edge Functions byte-identical before/after; Production
  data (5 table checksums + 8 table counts) fully preserved with zero mutation; no-JWT smoke check
  returned 401 on all 5 new functions.
- Swift regression: clean build succeeded (after resolving SPM packages post DerivedData clear —
  see Testing conventions), 1020/1020 tests passing, same 6 pre-existing warnings, zero new ones.
- Pure deployment task — zero source files modified during this task itself.
- First commit of the working tree landed this session (see git log for exact contents) — ending
  months of intentionally-uncommitted iterative work across Phases 3 through 8F.
- This is the first Session Log entry; prior sessions' work (Phases 1 through 8E) is summarized in
  the Feature Roadmap and Architecture landmarks sections above rather than logged individually.
