#!/bin/bash
# SpendSmart (FinanceTrack) — THE default test/build destination.
#
# Pinned to iOS 26.5 on "iPhone 17 Pro" — the newest NON-BETA simulator runtime installed on
# the machine this was written on, as of 2026-09-13. This is the ONLY authoritative default
# destination for this project; do not hardcode a destination string anywhere else.
#
# WHY THIS EXISTS: before this script, `-destination 'platform=iOS Simulator,name=iPhone 17
# Pro'` (no OS pinned) was used directly in ad-hoc commands. With three simulators sharing
# that exact name (iOS 26.3, 26.5, and a 27.0 BETA), that unpinned form resolved to
# "whichever is newest" — silently the 27.0 beta on this machine — with nothing in any test
# report saying which OS actually ran. That made every red/green result unreproducible and
# let a real iOS 27 SwiftData behavior change (see testRollbackBehaviorOnCurrentSDKDoes...
# in FinanceTrackTests.swift, and this project's CLAUDE.md Session Log, 2026-09-13) get
# graded against production expectations as if it were a random flake.
#
# For a DELIBERATE check against the iOS 27.0 beta, use scripts/test-beta-ios27.sh instead —
# never this script. The two must never be confused: this one answers "did my code break,"
# that one answers "did the next iOS break something under me."
#
# Usage:
#   scripts/test.sh build
#   scripts/test.sh test
#   scripts/test.sh clean test
#   scripts/test.sh test -only-testing:FinanceTrackTests/FinanceTrackTests/<testName>
set -euo pipefail
cd "$(dirname "$0")/.."

DESTINATION="platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5"

exec xcodebuild -project FinanceTrack.xcodeproj -scheme FinanceTrack -destination "$DESTINATION" "$@"
