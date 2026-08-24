# SpendSmart (FinanceTrack) — Project Notes for Claude

iOS SwiftUI/SwiftData personal finance app ("SpendSmart" user-facing, "FinanceTrack" internal/repo
name) with a Supabase backend for Plaid bank-linking and household sharing. Single main developer
(Scott), long-running iterative sessions — this file exists so a fresh session doesn't have to
re-derive architecture/conventions from scratch.

## Current Status (as of 2026-08-21)

Migrations `0001`–`0027` and their Edge Functions are live on **Production** (confirmed via
`supabase migration list --linked` — every migration's `remote` matches `local`, and
`get-dashboard-summary`/`upsert-dashboard-summary`/`update-sharing-permission` all confirmed at
their latest deployed `version` via `supabase functions list`). Household sharing is complete
end-to-end (Primary invites/manages; Secondary auto-discovers/accepts/declines/shares back), with
five sharing categories live: `connectedAccounts`, `manualAccounts`, `monthlyPlan`,
`monthlySavings`, `savedViaTransfer`. Week-by-Week now shares all 4 month-aligned weeks (not just
the current one) between Primary and Secondary (migration 0026), and `user_profiles` has been
backfilled for pre-existing accounts that predated the sharing feature (migration 0027).

Swift test suite: **2779/2779 passing** as of 2026-08-21, zero new warnings.

There is **no in-progress code task**, but **the working tree is uncommitted** as of 2026-08-21 —
a large session's worth of client-side UX work (onboarding flow skeleton, Face ID grace period,
Dashboard/Settings polish — see Session Log below and `SESSION_HANDOFF.md` for full detail) has not
yet been committed or pushed. Do not commit without Scott explicitly asking, per the standing rule
below — but be aware `git status --short` will show real, intentional, tested work, not stray
cruft.

## Next Step

No follow-up phase has been requested — await Scott's next task brief. Genuinely open items, none
of which are unfinished code:

1. **Describe the "glitchy" account-switching symptom.** Scott reported sign-out/sign-in between
   household members feels glitchy but hasn't described exactly what he sees. Investigation (see
   Session Log, 2026-08-21) found theoretical risk windows but nothing was changed — this code sits
   close to previously-fixed real crash bugs, so get a concrete symptom before touching it.
2. **On-device onboarding testing not yet done.** Scott said he'd create test Primary/Secondary
   accounts and walk through each of the 5 onboarding paths. No bugs reported back yet.
3. **Production spot-check still owed** (carried over from 2026-08-15): has anyone confirmed a real
   Transfer-to-Savings entry now reaches `manual_transactions` on Production under the fixed
   allowlist (migration 0022)? Lower urgency than 1–2 above but still unconfirmed.
4. **Unconfirmed**: Xcode showed "Cannot find … in scope" errors (`QuickStatsSettings`,
   `SavedViaTransferCalculator`, `QuickStatID`, `SavedViaTransferSummarySyncService`,
   `QuickStatsConfigurationView`) after `xcodegen generate` regenerated the project file while Xcode
   was open. CLI `xcodebuild` built and tested clean *after* those errors appeared, so this is very
   likely a stale Xcode editor index, not a code problem. Fix is quit+reopen Xcode, fallback
   `DerivedData/Index.noindex`. Never confirmed resolved by Scott, and hasn't recurred/come up since.
5. **Unanswered question**: the `S&L_Development_Information_Security_Policy…docx` / `SLD-*.docx`
   files and `Calculator_App_Icon.png`/`Calculator_Icon.png` in the repo root are unrelated to this
   app by name and undocumented. Flagged to Scott, no answer yet. Do not touch until he clarifies.
6. Not started, explicitly out of scope until requested: Secondary-side Monthly Plan sharing.
7. Not started: a real onboarding paywall. `OnboardingPaywallStubView` (2026-08-18) only occupies
   that step in the new onboarding flow — Scott explicitly flagged the real paywall as still needed.

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
  *actual* test total from that run, never assume a remembered number. As of **2026-08-21** the
  suite is at **2779 tests** (it was 2719 on 2026-08-15 and 1020 on 2026-07-21 — treat any
  remembered figure as stale and re-run).
- **Some tests are raw source-string scans with a hardcoded `prefix(N)` window** over
  `DashboardView.swift`/`SettingsView.swift` (e.g. `testDashboardEveryQuickStatTileIsGatedByVisibility`).
  Adding code to a scanned property pushes the searched-for strings past the window and fails the
  test for a non-real reason. The correct fix is to **widen the `prefix()` argument, never to change
  what is asserted** — happened on 2026-08-15 (4 call sites) and again on 2026-08-21 (3 more sites,
  plus 1 test whose asserted literal string legitimately changed and was updated to match).
- **Final reports** follow a consistent numbered-section format (safety baseline → root
  cause/design → security → files → tests → validation → git summary → exclusions confirmed →
  deployment status with explicit YES/NO lines → RESULT: PASS/BLOCKED). Keep using that shape —
  it's what the user expects and cross-references against.
- **Never edit an already-shipped migration.** `0001`–`0027` have all been applied to at least one
  environment. Migration numbering is sequential and must never be reused or reordered — the next
  new migration is `0028_….sql`. Any further schema change is a new file, following the established
  dynamic-constraint-name-lookup pattern (`pg_constraint`/`pg_get_constraintdef` matching — never
  hardcode an auto-generated constraint name).
- **Never commit or push** unless explicitly asked. Historically the working tree was kept
  deliberately dirty across sessions with many completed-but-uncommitted features; the first commit
  landed 2026-07-21 (explicitly requested — see Session Log). This rule remains in force going
  forward: don't commit/push proactively just because a task finished.
- **Working-tree baseline as of 2026-08-21: dirty**, with a full session's worth of tested,
  intentional client-side UX work (onboarding flow, Face ID grace period, Dashboard/Settings
  polish — see Session Log) plus 4 already-Production-deployed migrations (`0024`–`0027`), none of
  it committed yet. This is expected, not a red flag — but always check `git status --short` fresh
  rather than trusting any stored list, and don't assume a clean-vs-dirty state from an old handoff.
  - `SESSION_HANDOFF.md` is **untracked and deliberately left untracked** — it is a per-session
    working document, not project content. It is *not* in `.gitignore` (unlike the sibling
    StreamDrop repo, which does ignore its own), so take care never to sweep it in with a blanket
    `git add -A`.
  - `Untitled 5.rtfd/` — unrelated macOS TextEdit document in the repo root. **Leave it untouched.**
    Do NOT delete, modify, move, stage, or add it to Xcode.
  - `_archive/` (`debug-screenshots/`, `scripts/`) holds old verification screenshots and a sandbox
    setup script moved out of the repo root on 2026-08-16. These are tracked moves, not deletions —
    the files remain in git history either way.

## Known Issues / Anomalies

- **RESOLVED 2026-08-16 — duplicate `.xcodeproj` shells.** `FinanceTrack 2` through
  `FinanceTrack 7.xcodeproj` had accumulated alongside the real `FinanceTrack.xcodeproj`, some
  already committed to git history. All six were confirmed unused (via Xcode's own recent-documents
  record: `strings ~/Library/Preferences/com.apple.dt.Xcode.plist | grep FinanceTrack`) and deleted;
  the deletion is committed. **Only `FinanceTrack.xcodeproj` should ever exist.** If Xcode produces
  another stray shell, flag it to Scott and confirm via that same method before deleting.
- **Xcode's Source Control panel has committed and pushed on its own.** Commit `d6d40ee`
  (2026-08-15) added `FinanceTrack 7.xcodeproj/*` to history and pushed it, outside any Claude
  session. Consequence: `git status` being clean does **not** prove a Claude session committed it,
  and this repo's "never commit unless asked" rule can be bypassed by the IDE. Always verify push
  state against the remote (`git ls-remote origin refs/heads/main`) rather than trusting a stored
  claim — the 2026-08-16 handoff asserted these commits were unpushed and was wrong.
- **`manual_transactions` had 0 rows on Production** as of the migration 0022 deploy. Expected (the
  bug being fixed was that they never reached the cloud), but the fix has not yet been confirmed
  against real usage — see Next Step item 1.
- No anomalies were found during Phase 8F (2026-07-21) — Production data checksums, unrelated Edge
  Function versions, and the Swift test suite all matched baseline exactly.

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
- [x] Sign Out / Delete Account styling + repositioning — superseded 2026-08-18/2026-08-21, see
      below (small centered capsules, Delete Account pinned to the true bottom of the screen)
- [x] Secondary automatic pending-invitation discovery (no link/token needed) + Accept/Decline +
      foreground-return re-check (migration 0015, `PendingInvitationPopupViewModel`)
- [x] Secondary → Primary share-back for the Secondary's own Connected accounts and own Manual
      accounts (per-item, auto-bootstrapped category toggle, migration 0015)
- [x] **All of the above deployed and verified on Production** (migrations 0008–0015, all
      associated Edge Functions) — Phase 8F, 2026-07-21
- [x] Secondary shared-data discovery + Connected-account balance parity (migrations 0016, 0017)
- [x] Monthly Savings sharing — `monthlySavings` global-only category, aggregate-mirror table
      (migration 0018)
- [x] Dashboard summary sharing + monthly-outlook week (migrations 0019, 0020)
- [x] Owner manual-accounts restore (migration 0021)
- [x] Transaction CSV import/export, Pay Bills, Users Guide, in-app calculator, biometric auth,
      exclude-from-reports — landed 2026-08-04 / 2026-08-15 (see Session Log caveat: reconstructed
      from git, not from a contemporaneous session record)
- [x] Connected (Plaid) savings accounts usable as a Transfer-To-Savings destination — Plaid
      `subtype` threaded through to `AddExpenseView` (2026-08-15)
- [x] **Backend transfer-type allowlist fix (data-loss bug)** — migration 0022 + widened
      `_shared/manual.ts` `VALID_TRANSACTION_TYPES`; client now also decodes the server's
      `rejected_transactions` field instead of silently dropping it (2026-08-15)
- [x] Saved via Transfer sharing — `savedViaTransfer` global-only category, its own aggregate-mirror
      table + 2 Edge Functions (migration 0023, 2026-08-15)
- [x] Settings → Quick Stats picker — `QuickStatID` / `QuickStatsSettings` /
      `QuickStatsConfigurationView`, replacing a static inert info card (2026-08-15)
- [x] **All of the above deployed and verified on both Preview and Production** (migrations
      0016–0023) — 2026-08-15
- [x] Week-by-Week full 4-week parity for Secondary — `weekly_comparisons jsonb` on
      `dashboard_summary` (migration 0026, 2026-08-21)
- [x] Secondary Connected Account balance restore + Quick Stats field parity (migrations 0024, 0025)
- [x] `user_profiles` backfill for pre-existing accounts (migration 0027, 2026-08-21)
- [x] `savedViaTransfer` Edge-Function-side allowlist drift fix (`_shared/household.ts`) — deployed
      2026-08-21
- [x] `sharedSavingsQuickStatVisible` now respects the Quick Stats picker, matching its
      `sharedSavedViaTransferQuickStatVisible` sibling (2026-08-21)
- [x] **All backend work above deployed and verified on both Preview and Production** (migrations
      0024–0027) — 2026-08-21
- [x] Onboarding flow skeleton — `OnboardingSetupPath` (5 cases)/`OnboardingSettings`/
      `OnboardingFlowView`/`OnboardingPathSelectionView`/`OnboardingInstructionsView` +
      `OnboardingPaywallStubView` (stub only — see Not yet built, below) (2026-08-18)
- [x] Face ID 1-hour grace period, survives force-quit — `BiometricAuthManager.gracePeriod`,
      UserDefaults-persisted `lastUnlockedAt` (2026-08-18)
- [x] Dashboard lock icon beside the Eye (hide-balances) icon (2026-08-18)
- [x] Settings "Lock Now" relocated under Account Related Options, centered (2026-08-18)
- [x] Shared Quick Stat loading placeholder + automatic retry-once (`SharedQuickStatLoadingPlaceholder`,
      `SharedMonthlySavingsViewModel`/`SharedSavedViaTransferViewModel`) (2026-08-18)
- [x] Sign Out / Delete Account resized to small centered capsules; Delete Account pinned to the true
      bottom of the screen (not just last in scroll order); sign-out sheet self-dismisses on success
      (2026-08-18 / 2026-08-21)
- [x] Dashboard "This Week" card tap gesture removed entirely (dead-ended at a read-only sheet)
      (2026-08-21)
- [x] Budget Settings' Weekly Spending Limit / Monthly Savings Goal rows now open the real Monthly
      Plan edit sheets on tap (`PlannedWeeklySpendingEditView`/`MonthlyPlanSettingsEditView`, same
      ones `MonthlyPlanView` itself uses) — values still always derived from Monthly Plan, never
      directly typable inline (2026-08-21)

Not yet built (explicitly out of scope until requested):
- [ ] Secondary-side Monthly Plan sharing/control — Secondary remains read-only via the Primary's
      global toggle; no Secondary Monthly Plan UI exists
- [ ] Real onboarding paywall — `OnboardingPaywallStubView` only occupies that step in the flow

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
- **Full shareable-category list** (as of migration 0023): `connectedAccounts` (per-item),
  `manualAccounts` (per-item), `monthlyPlan` (global-only), `monthlySavings` (global-only),
  `savedViaTransfer` (global-only). Every one plugs into the same
  `is_effectively_shared_for_user` evaluator — there is **no per-category bespoke authorization
  logic anywhere**, and the single trusted write path for any toggle is the `set_sharing_permission`
  SQL function called via the `update-sharing-permission` Edge Function.
- **Aggregate-mirror-table pattern** (used by `monthlySavings` and `savedViaTransfer`): one row per
  `owner_user_id` holding a pre-computed total. The **client always computes the aggregate locally
  and POSTs it; the server never aggregates, and raw entries never sync.** Push:
  `<Feature>SummarySyncService.sync(...)` — stateless, best-effort, no retry queue (the next
  successful trigger simply re-sends the current correct total). Pull:
  `Shared<Feature>ViewModel.load()` → `HouseholdSharingService.get<Feature>Summary(ownerUserId:)` →
  Edge Function → SQL function → canonical evaluator. Follow this shape for any future category;
  do not introduce a second raw-data sharing surface.
- **Adding a sharing category is a 3-layer hand-propagation, easy to half-finish**: the
  `get_secondary_shared_data` SQL function, the `get-account-related-options` Edge Function's
  hand-written field mapping, and the Swift DTO's hand-written field mapping each need the new field
  added separately — neither layer passes the other's JSON through verbatim. Verified by reading the
  Edge Function source directly, not assumed.
- **Identity always comes from the JWT, never the request body** for summary read/write functions
  (`requireAuthenticatedUserId`) — this is the anti-spoofing guarantee. Do not add a body-supplied
  identity parameter to any of them.
- **`TransactionType` (Swift) ↔ `_shared/manual.ts` `VALID_TRANSACTION_TYPES` ↔
  `manual_transactions.transaction_type` CHECK constraint must be kept in exact sync.** Drift here
  caused a silent server-side rejection / data-loss bug (fixed by migration 0022, 2026-08-15): three
  enum cases were added Swift-side and neither backend allowlist was widened, so those transactions
  never reached the cloud and would have been lost on restore. **Any future `TransactionType` case
  addition must update all three in the same change.**
- **Money is always wire-transmitted as JSON strings, never numbers** — universal convention across
  every Edge Function in this project.
- **`SavedViaTransferCalculator.savedThisMonth`** sums only `.transferToSavings` transactions using
  **half-open interval containment** (`>= start`, `< end`) and skips `isExcludedFromReports`. This
  matches `BudgetCalculator`'s boundary-fix precedent — changing it to a closed interval
  reintroduces a documented month-boundary double-count bug.
- **Quick Stats picker**: `QuickStatID` (enum, `allCases`) + `QuickStatsSettings` (SwiftData model,
  `hiddenRawIDs: [String]`, `resolveCanonicalRecord` dedup helper) + `QuickStatsConfigurationView`
  (picker UI) + `DashboardView.isQuickStatShown(_:)` (the gate every tile in `quickStatsSection`
  checks). Note `sharedSavedViaTransferQuickStatVisible` is a **separate** flag from
  `isQuickStatShown` — it gates whether the Secondary's shared-architecture card renders instead of
  a local reconstruction.
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
- **The category allowlist also lives, separately, in `supabase/functions/_shared/household.ts`**
  (`SharingCategory` type / `VALID_CATEGORIES` / `GLOBAL_ONLY_CATEGORIES`) — a 4th place a new
  sharing category must be added, beyond the 3 already documented above. `savedViaTransfer` was
  missing from this one specifically until 2026-08-21 (found by audit, not user-reported), even
  though the DB constraint and `set_sharing_permission` already allowed it. Check this file
  explicitly whenever adding a category, don't assume the DB layer being correct means every layer
  is.
- **`weekly_comparisons jsonb`** on `dashboard_summary` (migration 0026, 2026-08-21) carries all 4
  month-aligned weeks as one array — chosen over 32 flat columns since it's always read/written as
  one atomic unit, never SQL-filtered. `DashboardView.weekByWeekBlock(summary:)` prefers this field,
  falling back to the legacy single-week `currentPlanWeek` field only for stale cached rows that
  predate the migration. Extended additively via the established drop-old-overload-then-recreate
  pattern on `set_dashboard_summary`/`get_shared_dashboard_summary`.
- **`BiometricAuthManager`'s 1-hour grace period is UserDefaults-persisted, not just in-memory**
  (`lastUnlockedAtDefaultsKey`, internal not private so `@testable import` tests can seed/clear it
  directly) — this is what lets it survive a force-quit, not just app backgrounding.
  `lockIfGraceExpired(now:)` (called from `FinanceTrackApp`'s background scenePhase handler) only
  locks once the grace period has actually elapsed; `lock()` clears both the in-memory and
  persisted state. Getting this wrong (in-memory only) was an actual bug caught by Scott mid-session
  on 2026-08-18 — don't regress it back to in-memory-only.
- **Onboarding gate**: `RootView` checks `!isBootstrapped` then `!onboarding.hasCompletedOnboarding`
  before showing `OnboardingFlowView` instead of the normal `TabView`. `OnboardingSetupPath` has 5
  cases (connected-only / connected+plan / plan+manual / plan-only / none); `.none` skips the
  `.instructions` step and completes immediately. New `OnboardingSettings` rows default
  `hasCompletedOnboarding: !isFreshUser`, reusing the same `freshlyCreatedSettings != nil` signal the
  pre-existing Face ID opt-in bootstrap already used — existing users must never be retroactively
  onboarded. `OnboardingPaywallStubView` is a placeholder step only; no real paywall exists yet.
- **Shared Quick Stat cards' loading UX**: `.loading` now renders `SharedQuickStatLoadingPlaceholder`
  (matches `StatCard`'s exact shape so the grid never jumps) instead of `EmptyView()`; `.loaded(nil)`
  still deliberately renders nothing (anti-enumeration — see above — a Secondary must never be able
  to tell "not shared" apart from "doesn't exist"). `SharedMonthlySavingsViewModel`/
  `SharedSavedViaTransferViewModel.load()` both retry exactly once, immediately, on failure before
  setting `.failed` — deliberately no timer/backoff, matching the project's "no new scheduling
  mechanism" convention used elsewhere (e.g. the Face ID grace period reusing the existing
  scenePhase hook rather than a new timer).
- **Settings' Budget Settings rows are tap-to-edit, not inline-editable**: `SettingsView`'s Weekly
  Spending Limit / Monthly Savings Goal rows open the SAME real Monthly Plan edit sheets
  `MonthlyPlanView` itself presents (`PlannedWeeklySpendingEditView`/`MonthlyPlanSettingsEditView`)
  rather than a second, competing edit surface — the displayed amount itself is still never directly
  typable (`isDisabled: true`), only the row's tap target changed.
  `SettingsView.syncBudgetSettingsFromMonthlyPlan()` re-reconciles `BudgetSettings`' derived display
  values both on `onAppear` and whenever either edit sheet's `isPresented` flips back to `false`,
  since `SettingsView` stays mounted underneath its own sheets and nothing else would trigger a
  refresh.

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

### 2026-08-18/21 — Week-by-Week parity, user_profiles backfill, onboarding flow, Face ID grace
### period, Dashboard/Settings UX polish (large multi-topic session)
- **Week-by-Week full 4-week parity for Secondary**: root-caused to `dashboard_summary` only ever
  carrying the current week. Migration `0026_dashboard_summary_weekly_comparisons.sql` adds a
  `weekly_comparisons jsonb` column; `PrimaryDashboardSummarySyncService` now pushes all 4 weeks;
  `DashboardView.weekByWeekBlock` prefers the new field, falls back to the legacy single-week field
  for stale cached data. Migrations `0024`/`0025` (Connected Account balance restore + Quick Stats
  field parity) also landed and deployed this session. Deployed Preview → Production, verified live.
- **`user_profiles` backfill**: Scott's own account (pre-dated household sharing) wasn't showing up
  in `user_profiles` because the sync triggers only fire on INSERT/email-UPDATE, never
  retroactively. Migration `0027_backfill_user_profiles.sql`, deployed and confirmed 2 of 3
  Production accounts were missing a row and now have one.
- **`savedViaTransfer` allowlist drift bug** (found by audit): `_shared/household.ts`'s
  `SharingCategory`/`VALID_CATEGORIES`/`GLOBAL_ONLY_CATEGORIES` never got the category added, even
  though the DB layer already allowed it correctly. Fixed, deployed.
- **`sharedSavingsQuickStatVisible` picker-gating bug**: didn't check `isQuickStatShown`, unlike its
  sibling flag. Confirmed with Scott via AskUserQuestion that the picker should always win. Fixed.
- **Big multi-part feature request, all built**: onboarding flow skeleton (5-path picker + per-path
  instructions + paywall stub — see Architecture landmarks), Face ID 1-hour grace period (persisted
  to UserDefaults after Scott caught the first, in-memory-only implementation not surviving a
  force-quit), Dashboard lock icon, Settings "Lock Now" relocated under Account Related Options.
- **"Saved" Quick Stat flakiness on Secondary — investigated 3 times**: rebuild fixed it once
  (stale cache), the picker-gating bug above was the real fix once, and a third report turned out to
  be normal loading latency mistaken for a bug because a temporary debug overlay was visible during
  it. Scott's framing ("should always work, not be iffy") was treated as valid UX feedback
  regardless — led to `SharedQuickStatLoadingPlaceholder` + automatic retry-once on both shared
  view models (see Architecture landmarks).
- **Sign Out / Delete Account**: resized to small centered capsules; then, on a follow-up "should be
  at the very bottom" report, restructured `AccountView.body` so Delete Account is pinned to the
  true bottom of the screen (outside the `ScrollView`, via `Spacer(minLength: 0)`), not just last in
  scroll order. Sign-out sheet now also self-dismisses on success.
- **Dashboard "This Week" card**: removed its tap gesture entirely (Scott: it unexpectedly opened a
  read-only sheet) — also removed the now-dead `isPresentingSetBudget` state/sheet.
- **Budget Settings "won't let me edit it"**: confirmed this was intentional pre-existing behavior,
  not a regression. Scott's actual ask was to keep values derived from Monthly Plan but make the
  rows tap-to-edit — wired both rows to open the real Monthly Plan edit sheets (see Architecture
  landmarks for the exact mechanism).
- Tests: **2779/2779 passing**, zero new warnings, confirmed via a clean `xcodebuild test` run after
  every change in this session. Hit and fixed, per the standing convention: 3 `.prefix(N)`
  source-scan windows widened, 1 test's asserted literal string updated to match an intentional code
  change (never the assertion's underlying intent).
- Backend deployment verified via `supabase migration list --linked` (all `0001`–`0027` show
  `remote` = `local`) and `supabase functions list` (`get-dashboard-summary`/
  `upsert-dashboard-summary`/`update-sharing-permission` all confirmed at their latest deployed
  version, `status: ACTIVE`).
- **End-of-session state**: working tree is uncommitted (client-side work + already-deployed
  migrations, all real and tested — not a stray/incomplete state). Two open threads need Scott's
  input before continuing: describe the "glitchy" account-switching symptom (investigated,
  theoretical risk windows found, nothing changed without a concrete repro), and report back from
  on-device onboarding-flow testing once he's done it. Full narrative detail in
  `SESSION_HANDOFF.md`, generated fresh this session.

### 2026-08-16 — Handoff reconciliation + repo housekeeping (no app code)
- Compared the repo against `SESSION_HANDOFF.md`. Feature work all verified present and correct;
  found one wrong claim in the handoff — it said the 2026-08-15 commits were unpushed. They were
  already on GitHub (confirmed live via `git ls-remote`; reflog shows `update by push` at
  2026-08-15 11:09). Cause: Xcode's Source Control integration pushed them, not a Claude session.
- Committed the previously-uncommitted cleanup pass (`b3846de`): deleted 23 files across the six
  duplicate `FinanceTrack 2-7.xcodeproj` shells, and moved 16 debug screenshots + 1 sandbox script
  into `_archive/`. Git records the 17 moves as renames — nothing was lost. **Zero application
  source files touched** (no `.swift`/`.ts`/`.sql`/`.toml` in that commit). `SESSION_HANDOFF.md`
  deliberately left untracked.
- Updated this file, which had drifted badly: it still said 1020 tests (actual: 2719), still listed
  migrations as ending at 0015 (actual: 0023), and still carried the duplicate-`.xcodeproj` anomaly
  as unresolved. Two full sessions (2026-08-04, 2026-08-15) had never been logged here at all.
- **Not done, still owed:** the on-device Production spot-check of transfer-type manual transactions
  (Next Step item 1), and confirmation that the Xcode "cannot find in scope" errors cleared.

### 2026-08-15 — Saved via Transfer sharing, transfer-type data-loss fix, Quick Stats picker
- Commit `a131a13` (40 files). Three pieces of work plus one rebuild:
  1. **Connected Savings support for Transfer To Savings** — Plaid `subtype` threaded through to
     `AddExpenseView` so a Connected account typed `savings` can be a transfer destination, not
     just Manual Accounts. No backend change.
  2. **Backend transfer-type allowlist fix** — found by audit, *not* user-reported. See the
     Architecture landmark on `TransactionType` sync for the full description; migration 0022 +
     widened `_shared/manual.ts`. `ManualDataSyncResult` now also decodes `rejected_transactions`
     (previously silently dropped) and logs it in DEBUG — closing the blind spot that hid this.
  3. **`savedViaTransfer` sharing category** (migration 0023) — new global-only category mirroring
     `monthlySavings` exactly; 2 new Edge Functions, full client stack, Dashboard wiring, Account
     Related Options toggle.
  4. **Settings → Quick Stats** rebuilt from a static info card into a working picker.
- Deployed to **Preview first, then Production** (both migrations, all 4 new/updated Edge
  Functions), verified live: SQL function/constraint checks, no-JWT smoke checks returning 401 on
  all 4, and before/after row counts confirming zero data mutation.
- Tests: **2719/2719 passing**, zero new warnings. Five pre-existing source-scan tests broke on the
  new code and were fixed by widening their `prefix()` windows — see Testing conventions.
- Two build gotchas hit and resolved: new Swift files aren't picked up until `xcodegen generate` is
  re-run; and running `xcodegen` while Xcode is open leaves Xcode's index stale (see Next Step 2).
- Commit `d6d40ee` landed after this, **not from a Claude session** — it added
  `FinanceTrack 7.xcodeproj/*` and pushed. See Known Issues.

### 2026-08-04 and 2026-08-15 (early) — not logged at the time
- Commits `4c0d20a` (107 files) and `12df617` (60 files). **These were never documented here, and
  the entries below are reconstructed from git stats after the fact — treat them as an index of
  where to look, not as a verified account of what was decided or why.**
- `4c0d20a` added migrations **0016–0021** (secondary shared-data discovery, Connected-account
  balance parity, monthly-savings sharing, dashboard-summary sharing + monthly-outlook week, owner
  manual-accounts restore) and their Edge Functions (`get-dashboard-summary`,
  `upsert-dashboard-summary`, `get-monthly-savings-summary`, `upsert-savings-summary`,
  `get-my-manual-accounts`, and the invitation functions), plus `SharedPrimaryDataViews.swift`.
- `12df617` was client-side and large: transaction CSV import/export, Pay Bills, Users Guide,
  in-app calculator, biometric auth changes, exclude-from-reports, bill-payment backfill,
  transaction amount/bill-tag editing, and a ~5800-line test expansion.
- If precise detail on either is ever needed, read the commits directly rather than trusting this
  summary.

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
