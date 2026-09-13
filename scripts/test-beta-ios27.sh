#!/bin/bash
# SpendSmart (FinanceTrack) — DELIBERATE iOS 27.0 BETA CHECK. Not the default suite.
#
# Use this only when you specifically want to know "is the next iOS about to change
# something under me." For everyday work, use scripts/test.sh (pinned to the stable iOS 26.5
# default) instead — never this script for normal red/green feedback on your own changes.
#
#   scripts/test.sh          red = MY CODE BROKE.
#   scripts/test-beta-ios27.sh red = THE NEXT iOS CHANGED SOMETHING UNDER ME.
#
# These two mean different things and must never be confused for each other. If you're not
# sure which one you want, you want scripts/test.sh.
#
# CURRENT KNOWN FINDING ON THIS RUNTIME (as of 2026-09-13, iOS 27.0 build 24A5408d):
#   testRollbackBehaviorOnCurrentSDKDoesNotRestoreBalanceButProductionDoesNotDependOnIt
#   fails here (and only here — it passes on both iOS 26.3 and iOS 26.5). The test mutates an
#   Account's balance in-memory (5000 -> 4104) without saving, then calls
#   ModelContext.rollback(), then asserts the balance is STILL 4104 — i.e. that rollback()
#   discards unsaved inserts but does NOT revert an in-place property mutation, which is the
#   behavior this project has observed on every non-beta SDK to date. On iOS 27.0 beta, that
#   assertion fails because the balance comes back as 5000 instead: rollback() now DOES
#   revert the in-place mutation too. In plain terms: SwiftData's rollback() got MORE
#   thorough in iOS 27 beta, not less — the opposite direction from a data-loss risk.
#   This is a WARNING, not a break: PayBillsView.submit() deliberately never calls
#   rollback() at all — it uses its own explicit recovery (capture original balance, delete
#   exactly the transactions this attempt created, reset the balance directly), proven by
#   testPayBillsSubmitUsesExplicitRecoveryNotRollback and
#   testExplicitRecoveryRestoresTransactionsAndBalanceOnSaveFailure, neither of which is
#   affected by this change either way. So this finding means "Apple changed rollback()
#   again in iOS 27," not "Pay Bills is broken." Do not mute, skip, or delete the rollback
#   test over this finding — it is accurately reporting real framework behavior on a real
#   (beta) OS, per this project's own CLAUDE.md Session Log.
#
# Usage:
#   scripts/test-beta-ios27.sh test
#   scripts/test-beta-ios27.sh test -only-testing:FinanceTrackTests/FinanceTrackTests/<testName>
set -euo pipefail
cd "$(dirname "$0")/.."

DESTINATION="platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0"

echo "*** DELIBERATE iOS 27.0 BETA CHECK — this is NOT the default suite. ***" >&2
echo "*** A failure here means \"the next iOS may change something,\" not \"my code broke.\" ***" >&2

exec xcodebuild -project FinanceTrack.xcodeproj -scheme FinanceTrack -destination "$DESTINATION" "$@"
