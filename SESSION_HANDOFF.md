# SESSION_HANDOFF.md

Generated: 2026-08-21, for continuation in a brand-new Claude Code session. This file is
self-contained — read it, don't rely on prior conversation history.

Repo: `/Users/scott/Documents/Apple Apps/FinanceTracker`, branch `main`.
App: "SpendSmart" (user-facing) / "FinanceTrack" (repo/internal name) — iOS SwiftUI/SwiftData
personal finance app with a Supabase backend (Plaid bank-linking + household sharing).

**IMPORTANT — also read `CLAUDE.md` in this same repo root.** It is the persistent project memory
(architecture landmarks, standing workflow rules, environment facts, full feature roadmap, session
log) and has just been refreshed to include everything in this handoff. This handoff covers the
same ground in more session-narrative detail; `CLAUDE.md` is the durable reference and takes
precedence on anything not repeated here.

---

## 1. Current objective

No application-code objective is currently open/in-progress. Everything described below is
implemented and, for client-side work, passing the full test suite; backend work is deployed to
both Preview and Production and verified live. **The working tree is uncommitted** (see Section 4)
— per this project's standing rule, do not commit or push without being explicitly asked.

Two genuinely open threads, both requiring the user's input, not further code:

1. **Describe the "glitchy" sign-out/sign-in symptom.** The user reported account-switching feels
   "glitchy" but has not yet described exactly what that looks like. Investigation surfaced three
   theoretical risk windows (see Section 9, item 1) but nothing was changed — deliberately, given
   how close this code sits to previously-fixed real crash bugs. Ask before touching it.
2. **On-device onboarding testing.** The user said they plan to create test Primary/Secondary
   accounts and walk through each onboarding scenario. No bug report has come back from that yet.

## 2. Work completed this session (chronological)

### A. Week-by-Week / Weekly Budget parity fixes (Primary vs Secondary)
- Diagnosed and fixed the Secondary's Week-by-Week view only ever showing the current week instead
  of all 4 month-aligned weeks — root cause was `dashboard_summary` only ever carried the current
  week's numbers. **Migration `0026_dashboard_summary_weekly_comparisons.sql`** adds a
  `weekly_comparisons jsonb` column (one array holding all 4 weeks, chosen over 32 flat columns
  since it's always read/written as one atomic unit, never SQL-filtered) and extends
  `set_dashboard_summary`/`get_shared_dashboard_summary` additively.
- Updated `upsert-dashboard-summary`/`get-dashboard-summary` Edge Functions (new
  `parseOptionalWeeklyComparisons` validator, `formatWeeklyComparisons` responder) and
  `PrimaryDashboardSummarySyncService` to push all 4 weeks, not just the current one.
  `DashboardView.weekByWeekBlock(summary:)` now reads `summary.weeklyComparisons` first, falling
  back to the legacy `summary.currentPlanWeek` field for old cached data.
- Also present from earlier in this session (migrations `0024`/`0025`, confirmed live —
  see Section 3) which independently fixed a Secondary's Connected Account balances silently
  dropping out of `get_secondary_shared_data`, and general Quick Stats field parity between
  Primary/Secondary dashboards.
- **Deployed Preview → Production, verified live. Client + backend both done.**

### B. `user_profiles` visibility gap
- User asked why their own account (created before household sharing existed) didn't show up in
  `user_profiles` while a newer account did. Root cause: `sync_user_profile()`'s two triggers
  (`AFTER INSERT`/`AFTER UPDATE OF email` on `auth.users`) only ever fire for *new* rows or email
  changes — they never ran retroactively for pre-existing `auth.users` rows.
- **Migration `0027_backfill_user_profiles.sql`**: one-time idempotent
  `INSERT ... SELECT ... WHERE NOT EXISTS` backfill. Deployed Preview → Production; confirmed live
  that 2 of 3 Production accounts had been missing a profile row and now have one.

### C. `savedViaTransfer` category missing from Edge-Function-side allowlist (bug found by audit)
- `supabase/functions/_shared/household.ts`'s `SharingCategory` type / `VALID_CATEGORIES` /
  `GLOBAL_ONLY_CATEGORIES` never got `"savedViaTransfer"` added when that category shipped
  (migration 0023, prior session) — even though the DB CHECK constraint and `set_sharing_permission`
  SQL function already allowed it correctly. Classic "one layer updated, sibling layer missed" bug,
  matching a risk this codebase's own `CLAUDE.md` explicitly calls out.
- Fixed, redeployed `update-sharing-permission` (the only function that imports this validator) to
  Preview then Production, verified live via curl.

### D. `sharedSavingsQuickStatVisible` ignored the Quick Stats picker
- `DashboardView.swift`'s Secondary-side "Saved This Month" visibility flag never checked
  `isQuickStatShown(.savedThisMonth)`, unlike its sibling `sharedSavedViaTransferQuickStatVisible`
  which always did — contradicted an old "LOCKED PRODUCT RULE" comment. Confirmed with the user via
  AskUserQuestion that the picker should always win consistently, for both.
- Fixed: `sharedSavingsQuickStatVisible` now starts with `isQuickStatShown(.savedThisMonth) && ...`.

### E. Big multi-part request — onboarding flow, Face ID grace period, lock icon, Lock Now placement
One large user message asked for all of the following; all were built:
- **Onboarding flow skeleton**: `OnboardingSetupPath` (enum, 5 cases: connected-only,
  connected+plan, plan+manual, plan-only, none), `OnboardingSettings` (SwiftData model,
  `hasCompletedOnboarding`/`selectedPathRawValue`), `OnboardingFlowView` (`.paywall` →
  `.pathSelection` → `.instructions(path)`, `.none` skips straight to completion),
  `OnboardingPathSelectionView`, `OnboardingInstructionsView`, `OnboardingPaywallStubView` (a real
  paywall is explicitly NOT built yet — this is a stub step in the flow only). `RootView` gates on
  `!onboarding.hasCompletedOnboarding`. New `OnboardingSettings` rows default
  `hasCompletedOnboarding: !isFreshUser` so existing users are never retroactively onboarded — reuses
  the same `freshlyCreatedSettings != nil` signal the pre-existing Face ID opt-in bootstrap already
  used.
- **Face ID 1-hour grace period**: `BiometricAuthManager.gracePeriod: TimeInterval = 3600`;
  `lockIfGraceExpired(now:)` only locks if the grace period has actually elapsed; wired into
  `FinanceTrackApp`'s background scenePhase handler in place of an unconditional `lock()`.
  **Critical follow-up fix** (user pushback: "you didn't fix the login face id... if I force
  close"): the first implementation was in-memory only, so a force-quit (not just backgrounding)
  destroyed the grace period. Fixed by persisting the unlock timestamp to
  `UserDefaults.standard["BiometricAuthManager.lastUnlockedAt"]`, reconstructed in `init()` before
  any UI mounts. `lock()` clears both the in-memory and persisted state.
- **Dashboard lock icon**: added beside the existing Eye (hide-balances) icon, gated on
  `biometricAuth.isFaceIDRequired`, calls `biometricAuth.lock()` directly.
- **Settings "Lock Now" relocated**: moved out of the Security section, now directly under the
  Account Related Options card, centered.
- All built and tested; suite was at 2771/2771 at that checkpoint.

### F. "Saved" Quick Stat flakiness on Secondary — investigated 3 times, 1 real fix
User reported the shared "Saved" Quick Stat sometimes missing after switching to the Secondary
account. Investigated three separate times using live SQL + the in-app Debug diagnostics screen
(`SharedDataDiagnosticsView.swift`, which permanently gained a new "Saved (Transfers) Shared" row
during this):
1. First report — resolved by a rebuild (stale simulator/build cache, not a real bug).
2. Second report — this WAS a real bug: item D above (the picker-gating fix).
3. Third report ("it's as if it keeps trying to render it... something was in its place, like
   code") — this was normal async loading latency after an account switch, misread because a
   temporary `#if DEBUG` diagnostic text block I'd added for troubleshooting happened to be visible
   during that loading window. Removed the debug text; no code bug found.
- User's final framing ("but it should always work and not be iffy") was accepted as valid UX
  feedback regardless — led directly to item G below.

### G. Shared Quick Stat loading reliability (the "iffy" fix)
- New `SharedQuickStatLoadingPlaceholder` (private SwiftUI view in `DashboardView.swift`) — matches
  `StatCard`'s exact background/stroke/padding so the grid never visually jumps; spinner + "Loading…"
  text. Shown only for `.loading`; `.loaded(nil)` (confirmed-not-shared, anti-enumeration) still
  renders `EmptyView()`.
- `SharedMonthlySavingsViewModel.load()` / `SharedSavedViaTransferViewModel.load()` (in
  `SharedPrimaryDataViewModels.swift`) both now retry exactly once, immediately, on failure before
  giving up — extracted a private `fetch()` helper, called twice (once, then once more inside
  `catch`). Deliberately no timer/backoff, matching this codebase's "no new scheduling mechanism"
  convention.
- New test double `FlakyOnceHouseholdSharingService` (full 18-method protocol conformance, throws
  once then succeeds for the two methods under test) + two new tests confirming exactly 2 calls and
  a `.loaded` end state.
- Hit one pre-existing source-scan test with a hardcoded `.prefix(1800)` window that broke once the
  new retry code pushed its target strings further into the file — widened to `2600`, per this
  project's established convention (widen the window, never change what's asserted).

### H. Sign Out / Delete Account button sizing + placement
- `AccountView.swift`: both buttons changed from full-width `headlineFont` red pills to smaller,
  intrinsic-width, centered `Capsule()` pills (Sign Out: `bodyFont`; Delete Account: the even
  smaller `captionFont`).
- **Follow-up correction this session**: user said "the Delete Account should be at the very bottom
  of the screen" — it was already the *last item in scroll order*, but on a short screen it wasn't
  pinned to the actual visible bottom. Restructured `AccountView.body` so Delete Account sits outside
  the `ScrollView`, pushed to the true bottom of the screen via a `Spacer(minLength: 0)`, always
  visible regardless of scroll position.
- **Also fixed in the same pass**: the sign-out confirmation sheet now dismisses itself immediately
  when sign-out succeeds, instead of waiting for the user to tap Done — small polish, same
  `.confirmationDialog` flow.

### I. Dashboard "This Week" card — tap gesture removed entirely
- User reported tapping the card unexpectedly opened a *read-only* Weekly Limit sheet (no longer
  useful now that `WeeklyLimitEditView` has been auto-derived-only for a while). Removed the whole
  tap affordance: `.onTapGesture`, `.accessibilityAddTraits(.isButton)`, `.accessibilityHint`, plus
  the now-dead `isPresentingSetBudget` `@State` and its `.sheet`. `WeeklyBudgetView`'s own separate
  hero card still opens the same sheet via its own unrelated entry point — untouched.

### J. Weekly Spending Limit "won't let me edit it" → wired to the REAL Monthly Plan editors
- User was confused Budget Settings' Weekly Spending Limit field couldn't be typed into. Confirmed
  this is intentional, pre-existing, documented behavior (always derived from Monthly Plan) — not a
  regression from this session's other changes.
- User's actual ask: keep the values derived from Monthly Plan, but make **tapping** the row open a
  real edit popup. Implemented in `SettingsView.swift`:
  - "Weekly Spending Limit" row now opens `PlannedWeeklySpendingEditView` (the SAME sheet
    `MonthlyPlanView` itself presents — Automatic vs. Custom override), passing a newly-extracted
    `automaticPlannedWeeklySpending` (the raw, override-ignoring Flexible Spending ÷ 4 figure).
  - "Monthly Savings Goal" row now opens `MonthlyPlanSettingsEditView` (same sheet MonthlyPlanView
    uses — savings goal + buffer).
  - `labeledAmountField` reworked from a static disabled row into a `Button` with a trailing
    chevron; the amount itself is still non-typable (`isDisabled: true` unchanged) — only the row's
    tap action is new.
  - New `syncBudgetSettingsFromMonthlyPlan()` helper (extracted from the existing `onAppear` logic)
    is now also called via `.onChange` when either new sheet's `isPresented` flips back to `false`,
    since `SettingsView` stays mounted underneath its own sheets and would otherwise show stale
    numbers until next full appearance.
  - Refactored `currentEffectivePlannedWeeklySpending` to share a new
    `currentMonthFlexibleSpendingAvailable` private var with the new `automaticPlannedWeeklySpending`
    var, rather than duplicating the income/fixed-expenses/goal/buffer formula twice.

All of A–J are complete. **A, B, C are deployed backend work** (Preview → Production, verified
live). **D–J are client-only** — no backend deploy needed; verified via full local test suite only.

## 3. Exact files touched this session

**New Swift files (untracked):**
- `FinanceTrack/Models/OnboardingSettings.swift`, `FinanceTrack/Models/OnboardingSetupPath.swift`
- `FinanceTrack/Services/WeeklyOutlookBreakdownCalculator.swift`
- `FinanceTrack/Views/Dashboard/MonthlyOutlookBreakdownView.swift`
- `FinanceTrack/Views/Onboarding/OnboardingFlowView.swift`,
  `OnboardingInstructionsView.swift`, `OnboardingPathSelectionView.swift`,
  `OnboardingPaywallStubView.swift`

**New backend files (untracked), all deployed and confirmed live on Production:**
- `supabase/migrations/0024_restore_secondary_connected_account_balances.sql`
- `supabase/migrations/0025_dashboard_summary_quick_stats_parity.sql`
- `supabase/migrations/0026_dashboard_summary_weekly_comparisons.sql`
- `supabase/migrations/0027_backfill_user_profiles.sql`

**Modified (uncommitted) Swift files:**
`FinanceTrack.xcodeproj/project.pbxproj` (xcodegen-regenerated), `FinanceTrack/App/FinanceTrackApp.swift`
(grace-period-aware background lock), `FinanceTrack/Services/BiometricAuthManager.swift`
(grace period + UserDefaults persistence), `FinanceTrack/Services/PrimaryDashboardSummarySyncService.swift`
(all-4-weeks push), `FinanceTrack/Services/SharedPrimaryDataViewModels.swift` (retry-once),
`FinanceTrack/Services/UserDataStoreManager.swift` (onboarding schema registration + bootstrap),
`FinanceTrack/Sync/HouseholdSharingPayload.swift` (weeklyComparisons DTOs),
`FinanceTrack/Sync/PlaidTransactionImportService.swift`, `FinanceTrack/Views/Dashboard/DashboardView.swift`
(week-by-week source switch, loading placeholder, lock icon, This Week tap-gesture removal, picker-gating fix),
`FinanceTrack/Views/Debug/SharedDataDiagnosticsView.swift` (new "Saved (Transfers) Shared" row),
`FinanceTrack/Views/Expenses/ExpenseListView.swift`, `FinanceTrack/Views/Settings/AccountView.swift`
(button sizing + Delete Account pinned to bottom + sheet auto-dismiss),
`FinanceTrack/Views/Settings/SettingsView.swift` (Lock Now relocation, budget rows now open real editors),
`FinanceTrack/Views/Settings/SharedPrimaryDataViews.swift`, `FinanceTrack/Views/Weekly/WeeklyBudgetView.swift`,
`FinanceTrackTests/FinanceTrackTests.swift` (large set of new/updated tests throughout).

**Modified (uncommitted) backend files:**
`supabase/functions/_shared/household.test.ts`, `supabase/functions/_shared/household.ts`
(`savedViaTransfer` allowlist fix — deployed), `supabase/functions/get-dashboard-summary/index.ts`,
`supabase/functions/upsert-dashboard-summary/index.ts` (both deployed, confirmed `version: 4` live).

## 4. Current git status

Branch `main`, HEAD `8fa1047` ("Bring CLAUDE.md current — it had drifted two sessions behind").
**Nothing from this session has been committed.** `git status --short` at end of session:
20 modified files + 9 new untracked paths (listed in Section 3), matching exactly what's described
above — no unexplained changes. Do not commit or push without the user explicitly asking, per this
project's standing rule (see `CLAUDE.md`).

## 5. Decisions made and why

- **Preview before Production, always** — every backend change this session (migrations
  0024–0027, `update-sharing-permission`, `get-dashboard-summary`, `upsert-dashboard-summary`) went
  to Preview (`kzyvkywpnfvxlgvrgkpm`) first, verified, then Production only after confirming a
  recent backup existed.
- **No new scheduling/timer mechanisms** — the Quick Stat retry is a single immediate retry, not a
  backoff loop; the Face ID grace period reuses the existing scenePhase hook rather than a new
  background timer. Matches an existing project-wide test convention
  (`testNoNewLockTimeoutOrSchedulingWasInvented`-style guards).
- **Widen `.prefix(N)` test windows, never change what's asserted** — hit repeatedly this session
  (DashboardView quick-stats scan, SettingsView budgetSection scan) — this is a standing, explicit
  project convention, not something invented this session.
- **Reuse the real Monthly Plan edit sheets from Settings rather than building parallel ones** —
  `PlannedWeeklySpendingEditView`/`MonthlyPlanSettingsEditView` are now presented from two call
  sites (`MonthlyPlanView` and `SettingsView`) instead of duplicating edit UI, keeping Monthly Plan
  as the single source of truth the user asked to preserve.
- **Onboarding paywall is a stub, deliberately** — user explicitly flagged "(which we still need to
  do)" for the paywall itself; `OnboardingPaywallStubView` exists only to occupy that step in the
  flow, not as a real paywall implementation.
- **Existing users never retroactively onboarded** — reused the established
  `freshlyCreatedSettings != nil` bootstrap signal so `OnboardingSettings.hasCompletedOnboarding`
  defaults to `true` for anyone who already had local data, `false` only for genuinely new users.

## 6. Current architecture relevant to this work

(Full reference lives in `CLAUDE.md` — this is the delta needed to orient quickly.)

- **`weekly_comparisons jsonb`** on `dashboard_summary` (migration 0026) is the new canonical
  4-week payload; `DashboardView.weekByWeekBlock` prefers it, falls back to the legacy
  `currentPlanWeek` single-week field only for stale cached rows that predate this migration.
- **`syncBudgetSettingsFromMonthlyPlan()`** (`SettingsView.swift`) is now the single place that
  reconciles `BudgetSettings.weeklySpendingLimit`/`monthlyGoal` to the Monthly Plan's derived
  values — called from `onAppear` AND from both new edit sheets' dismissal, so the screen never
  shows stale numbers while it stays mounted underneath a sheet.
  `currentMonthFlexibleSpendingAvailable` is the shared formula piece both
  `currentEffectivePlannedWeeklySpending` (override-aware) and `automaticPlannedWeeklySpending`
  (override-ignoring, for the Automatic-mode display) are built from.
- **`BiometricAuthManager.lastUnlockedAt` is now UserDefaults-persisted**, not just in-memory —
  `BiometricAuthManager.lastUnlockedAtDefaultsKey` (internal, not private, so `@testable import`
  tests can seed/clear it directly). `init()` reconstructs `isUnlocked` from this before any UI
  mounts, which is what makes the 1-hour grace period survive a force-quit, not just backgrounding.
- **Onboarding gate**: `RootView` checks `!isBootstrapped` then `!onboarding.hasCompletedOnboarding`
  before showing `OnboardingFlowView` instead of the normal `TabView`. `OnboardingFlowView.Step`:
  `.paywall` → `.pathSelection` → `.instructions(OnboardingSetupPath)`, with `.none` skipping
  `.instructions` and calling `onComplete(path)` directly.
- **Shared Quick Stat cards' 3-state contract** (`.loading` / `.loaded(nil)` / `.loaded(summary)`)
  is unchanged — only `.loading`'s rendering changed (placeholder card instead of `EmptyView()`).
  `.loaded(nil)` still deliberately renders nothing, preserving the anti-enumeration guarantee (a
  Secondary can never tell "not shared" apart from "doesn't exist" from the UI alone).

## 7. Tests run and results

Final, most authoritative run this session:
```
xcodebuild test -project FinanceTrack.xcodeproj -scheme FinanceTrack \
  -destination 'platform=iOS Simulator,id=A7CFCFD4-0B4F-4337-AC88-AFC7DF6172F7'
```
Result: **2779/2779 tests passing, 0 failures, TEST SUCCEEDED.** No new warnings — the handful of
compiler warnings present are all pre-existing, in unrelated test fixture code (CSV import
scenarios, date-range helpers), confirmed via `git diff` to be untouched by anything this session.

Along the way, 3 pre-existing source-scan tests broke from new code shifting their target strings
past a hardcoded `.prefix(N)` window, and 1 test asserted an exact old code string that legitimately
changed — all 4 fixed per the established "widen the window / update to the new intentional string,
never change the underlying assertion's intent" convention (see Section 5).

Backend: `supabase/functions/_shared/household.test.ts` updated for the `savedViaTransfer` allowlist
fix, but per this project's standing limitation, **not runnable locally** (no `deno` installed) —
verified by code review + live Production behavior only.

## 8. Deployment verification performed

- `supabase migration list --linked` confirms all of **0001–0027** show `remote` = `local` (fully
  applied to Production).
- `supabase functions list --project-ref dlqjgpgnaguhubftfpel` confirms `get-dashboard-summary`
  and `upsert-dashboard-summary` are both at `version: 4` (the version that includes
  `weekly_comparisons`), and `update-sharing-permission` is at `version: 4` (includes the
  `savedViaTransfer` allowlist fix) — all `status: ACTIVE`.
- Earlier in the session: live SQL checks against `user_profiles` (backfill confirmed for the 2
  previously-missing Production accounts), no-JWT smoke checks on updated functions returning 401.

## 9. Known issues, bugs, or unresolved questions

1. **"Glitchy" account sign-out/sign-in switching — investigated, not fixed.** User reported this
   but has not described the exact visible symptom. Investigation found three theoretical risk
   windows: a deferred container-detach that could create a brief inconsistent-state window during
   switch, `AccountRelatedOptionsViewModel`'s reset causing a real `.hidden` visibility window
   during refetch, and confirmed sign-in correctly re-runs the full cold-launch bootstrap (no stale
   `@Query` flash found). **Nothing was changed** — this code sits close to several already-fixed
   real crash bugs (see `AccountView.swift`'s own extensive doc comments on the sign-out
   `dismiss()` race), so a fix should not be attempted without a concrete symptom to target. Ask the
   user first.
2. **On-device onboarding testing not yet done.** The user said they'll create test Primary/
   Secondary accounts and try each of the 5 onboarding paths. No bugs reported yet from that — but
   also no confirmation the flow works end-to-end on-device, only that it builds and its unit/
   source-scan tests pass.
3. Carried over, still true, still unconfirmed: whether Xcode's own editor ever showed stale
   "cannot find in scope" errors again after a `xcodegen generate` run while Xcode was open (see
   `CLAUDE.md` Next Step item 2 — was never confirmed resolved, and has not come up again this
   session either way).
4. Carried over, still unanswered: the `SLD-*.docx`/`S&L_Development_Information_Security_Policy...`
   files and `Calculator_*.png` files in the repo root remain unexplained and untouched.

## 10. Anything attempted that did not work (and how it was resolved)

- Simulator infra failures (`Mach error -308`, `Simulator device failed to launch`) hit repeatedly
  from many consecutive `xcodebuild` runs — not code bugs. Fixed each time with
  `xcrun simctl shutdown <id>` then `boot <id>`, occasionally `erase` first, then retried.
- Attempted to mint a live Supabase Auth session (magic-link) for the user's own Secondary account
  to get definitive live evidence during the "Saved" Quick Stat investigation (item F) — **this was
  blocked by the auto-mode permission classifier**. Respected immediately, no workaround attempted;
  pivoted to in-app `#if DEBUG` diagnostics instead, which is how the actual root causes (a picker
  bug, then normal loading latency) were found.
- Invalid `#if DEBUG ... else { ... } #endif` Swift syntax attempted once (wrapping only an `else`
  clause in conditional compilation inside a `@ViewBuilder`) — produced "Expected expression"
  compile errors. Fixed by restructuring as a fully independent standalone `if`, never splitting an
  `if`/`else` chain's braces across a `#if`/`#endif` boundary.

## 11. Exact next step for the new session

**No queued application-code task.** Correct next step:
1. Ask the user what they'd like to work on next, OR
2. If they mention account-switching glitchiness again, ask for the concrete symptom (Section 9,
   item 1) before touching any session/auth code.
3. If they've done on-device onboarding testing, ask what they found (Section 9, item 2).

Do not begin any new phase of items A–J above — all are complete, tested, and (where backend work
was involved) deployed to Production already.

## 12. Areas/files that must NOT be changed without explicit new instruction

- **`Untitled 5.rtfd/`** — unrelated macOS TextEdit document, repo root. Do not touch.
- **Already-shipped SQL migrations (`0001`–`0027`)** — never edit an applied migration. Any further
  schema change is a new file, `0028_....sql`.
- **`SLD-*.docx` / `S&L_Development_Information_Security_Policy...` / `Calculator_*.png`** files in
  the repo root — unexplained, flagged, not confirmed with the user.
- **`FinanceTrack.xcodeproj`** — only ever regenerate via `xcodegen generate` from `project.yml`;
  never hand-edit `project.pbxproj`.
- **Do not create additional duplicate `.xcodeproj` shells.** If Xcode produces one, confirm via
  `strings ~/Library/Preferences/com.apple.dt.Xcode.plist | grep FinanceTrack` before deleting.
- **`../FinanceTracker Backups/`** (sibling dir, outside git) — never delete without the same kind
  of explicit, itemized user approval used in past sessions.

## 13. Important calculations, constants, IDs, thresholds, APIs that must remain unchanged

- **Supabase project refs**: Production `dlqjgpgnaguhubftfpel` (region `ca-central-1`); Preview
  branch `phase2-sharing-test`, ref `kzyvkywpnfvxlgvrgkpm`, parent = Production. Always confirm via
  `supabase projects list` before any deploy — never assume from memory.
- **Migration numbering is sequential, never reused/reordered** — next new migration is
  `0028_....sql`.
- **`BiometricAuthManager.gracePeriod = 3600`** (1 hour) — do not change without the user asking;
  this exact value was explicitly requested.
- **`weekly_comparisons` is additive** — `set_dashboard_summary`/`get_shared_dashboard_summary` were
  extended via the established drop-old-overload-then-recreate pattern; the legacy single-week
  columns/fields still exist and must keep working for old cached client data.
- **`savedViaTransfer` remains global-only** (`item_id IS NULL` enforced at the DB layer) — do not
  make it per-item without a new, deliberate product decision.
- **Money fields are always wire-transmitted as JSON strings, never numbers** — universal convention
  across every Edge Function in this project.
- **Identity always comes from the JWT (`requireAuthenticatedUserId`), never a client-supplied body
  field**, for every summary read/write function — anti-spoofing guarantee, do not weaken.

## 14. Commands needed to build/test the project

```bash
cd "/Users/scott/Documents/Apple Apps/FinanceTracker"

# After any new/moved/renamed Swift file:
xcodegen generate

# List available simulator destinations:
xcodebuild -showdestinations -project FinanceTrack.xcodeproj -scheme FinanceTrack

# Full test suite (this session's simulator UUID — re-check availability first):
xcodebuild test -project FinanceTrack.xcodeproj -scheme FinanceTrack \
  -destination 'platform=iOS Simulator,id=A7CFCFD4-0B4F-4337-AC88-AFC7DF6172F7'

# If the simulator won't launch (Mach error -308 / "Simulator device failed to launch"):
xcrun simctl shutdown A7CFCFD4-0B4F-4337-AC88-AFC7DF6172F7
xcrun simctl boot A7CFCFD4-0B4F-4337-AC88-AFC7DF6172F7
```

**Supabase — Preview deploy:**
```bash
supabase branches get phase2-sharing-test --project-ref dlqjgpgnaguhubftfpel --output json
# extract POSTGRES_URL_NON_POOLING, then:
supabase db push --db-url "<preview-non-pooling-url>"   # NEVER --linked here (targets Production)
supabase functions deploy <function-name> --project-ref kzyvkywpnfvxlgvrgkpm
```

**Supabase — Production deploy (separate, explicit step only):**
```bash
supabase projects list                                      # confirm target ref explicitly
supabase backups list --project-ref dlqjgpgnaguhubftfpel     # confirm a recent backup exists
supabase migration list --linked
supabase db push --linked
supabase functions deploy <function-name> --project-ref dlqjgpgnaguhubftfpel
```

Backend Deno tests (`supabase/functions/_shared/*.test.ts`) are **not runnable locally** (no `deno`
installed) — verify by code review, and say so explicitly in any report.
