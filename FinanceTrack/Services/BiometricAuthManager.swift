import Foundation
import LocalAuthentication
import Observation

/// Wraps `LocalAuthentication` for the Face ID / Touch ID app lock. No credentials or network
/// calls involved — this only asks the OS to evaluate the device owner's biometric/passcode policy.
enum BiometricAvailability: Equatable {
    case available
    case unavailable(reason: String)
}

/// The seam between `BiometricAuthManager` and the real `LocalAuthentication` framework — exists
/// solely so unit tests can supply a fake that resolves instantly instead of touching a real
/// `LAContext`, whose `evaluatePolicy` can block indefinitely in a headless test host waiting for
/// system authentication UI that never appears. `LAContextBiometricAuthenticator` below is the
/// ONLY production implementation and is `BiometricAuthManager`'s default — every existing call
/// site (`BiometricAuthManager()` with no arguments) is unaffected by this seam's existence.
protocol BiometricAuthenticating {
    /// Mirrors `LAContext.canEvaluatePolicy(.deviceOwnerAuthentication, error:)`.
    func canEvaluateDeviceOwnerAuthentication() -> BiometricAvailability
    /// Mirrors `LAContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason:)` — returns
    /// the completed result, or throws (an `LAError` in the real implementation) exactly like the
    /// underlying API does for failure/cancellation/lockout.
    func evaluateDeviceOwnerAuthentication(reason: String) async throws -> Bool
}

/// The real, production-only `LocalAuthentication` implementation — behaviorally identical to
/// what `BiometricAuthManager` did inline before this seam existed (a fresh `LAContext` per call,
/// same `.deviceOwnerAuthentication` policy, same error-to-message mapping).
struct LAContextBiometricAuthenticator: BiometricAuthenticating {
    func canEvaluateDeviceOwnerAuthentication() -> BiometricAvailability {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable(reason: Self.friendlyUnavailableMessage(for: error))
        }
        return .available
    }

    func evaluateDeviceOwnerAuthentication(reason: String) async throws -> Bool {
        try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }

    fileprivate static func friendlyUnavailableMessage(for error: NSError?) -> String {
        guard let laError = error as? LAError else {
            return "Face ID and passcode aren't set up on this device."
        }
        switch laError.code {
        case .biometryNotEnrolled:
            return "Face ID isn't set up on this device yet."
        case .biometryNotAvailable:
            return "Face ID isn't available on this device."
        case .passcodeNotSet:
            return "Set a device passcode to use Face ID Lock."
        default:
            return "Face ID and passcode aren't set up on this device."
        }
    }
}

/// A brand-new user's "Use Face ID for future sign-in" choice, made on `CreateAccountView`
/// before any session/container exists yet — persisted (not held only in memory) because
/// sign-up may require email verification, which can involve backgrounding or even relaunching
/// the app before a real session is established, which would lose a purely in-memory flag.
/// Keyed by normalized email (no UID is known yet at mark time), consumed exactly once by
/// `RootView`'s bootstrap for whichever authenticated user that email resolves to, then removed
/// — so it can never be applied twice or leak to a different account that happens to reuse the
/// key. Stores only a boolean flag — never a credential, never anything sensitive.
enum PendingFaceIDOptIn {
    private static func key(for email: String) -> String {
        "pendingFaceIDOptIn.\(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    static func markPending(email: String) {
        UserDefaults.standard.set(true, forKey: key(for: email))
    }

    /// Returns whether this email had a pending opt-in — removes the marker either way, so it
    /// is only ever consumed once regardless of the outcome.
    @discardableResult
    static func consume(email: String) -> Bool {
        let resolvedKey = key(for: email)
        let wasPending = UserDefaults.standard.bool(forKey: resolvedKey)
        UserDefaults.standard.removeObject(forKey: resolvedKey)
        return wasPending
    }
}

@Observable
final class BiometricAuthManager {
    var isUnlocked: Bool = false
    var lastErrorMessage: String?
    /// Mirrors `BudgetSettings.requireFaceID`; `SettingsView` keeps this in sync.
    var isFaceIDRequired: Bool = false

    /// GRACE PERIOD (2026-08-18, Scott's explicit request for local testing convenience) — the
    /// timestamp of the most recent successful unlock, `nil` before the first one this session.
    /// Backing value for `lockIfGraceExpired()`'s "don't re-prompt for an hour" behavior below.
    private(set) var lastUnlockedAt: Date?

    /// How long an unlock stays valid across a background/foreground cycle before
    /// `lockIfGraceExpired()` will actually re-lock. A hard `lock()` (sign-out, "Lock Now", the
    /// new Dashboard lock icon) always bypasses this and locks immediately regardless.
    static let gracePeriod: TimeInterval = 3600

    /// FORCE-QUIT FIX (2026-08-18) — `lastUnlockedAt`/`isUnlocked` are plain in-memory properties;
    /// a force-quit terminates the whole process, so a purely in-memory grace period was
    /// worthless the moment the app was actually killed (as opposed to merely backgrounded) —
    /// exactly the scenario Scott reported still re-prompting. Persisting the unlock timestamp
    /// (never a credential, never anything more sensitive than a bare epoch-seconds `Double` —
    /// same risk class as `PendingFaceIDOptIn`'s own plain-`UserDefaults` boolean above) lets a
    /// fresh process reconstruct "was this unlocked within the last hour?" at `init` time, before
    /// `AppLockView` ever gets a chance to mount and prompt. Not `private` so tests (`@testable
    /// import`) can seed/clear a specific timestamp directly to exercise the fresh-vs-stale
    /// cold-launch paths without needing to actually wait an hour.
    static let lastUnlockedAtDefaultsKey = "BiometricAuthManager.lastUnlockedAt"

    /// Guards against overlapping `authenticate()` calls (e.g. SwiftUI re-running `.task` while a
    /// prior evaluation is still pending) — without this, two concurrent Face ID prompts can
    /// stack, and the OS cancelling one mid-flight can spuriously clear/set the other's result.
    private var isAuthenticating = false

    /// Whether the automatic (silent, `surfaceErrors: false`) Face ID attempt has already run for
    /// the CURRENT lock presentation — this is the explicit state `AppLockView` defers to via
    /// `authenticateAutomaticallyIfNeeded()` instead of relying purely on SwiftUI's own `.task`
    /// running-once-per-mount behavior, so "automatic attempt fires exactly once per lock
    /// screen appearance" is guaranteed by this manager's own state, not by view-lifecycle timing.
    /// Reset to `false` only by `lock()` (a fresh lock presentation) — never by a failed/cancelled
    /// automatic attempt itself, so a redraw, an unrelated `scenePhase` change, or the OS handing
    /// control back after the Face ID system UI can never cause a second automatic prompt for the
    /// same lock screen. The manual "Unlock with Face ID"/"Continue" button never checks this flag
    /// — it always calls `authenticate` directly — so the user can always retry as many times as
    /// they want; this flag only gates the one automatic attempt-on-appear.
    private(set) var hasAttemptedAutomaticUnlock = false

    /// Real `LocalAuthentication` in production (the default); a test double in unit tests — see
    /// `BiometricAuthenticating`'s own header for why this seam exists.
    private let authenticator: BiometricAuthenticating

    init(authenticator: BiometricAuthenticating = LAContextBiometricAuthenticator()) {
        self.authenticator = authenticator

        // FORCE-QUIT FIX — reconstruct "still within the grace period" from the PERSISTED
        // timestamp before this instance has ever run authenticate() itself, so a cold
        // launch/relaunch shortly after a force-quit starts already-unlocked instead of
        // re-prompting. A stale (or absent) persisted value leaves isUnlocked at its normal
        // `false` default, same as if this were the very first launch ever.
        if let stored = UserDefaults.standard.object(forKey: Self.lastUnlockedAtDefaultsKey) as? Double {
            let storedDate = Date(timeIntervalSince1970: stored)
            lastUnlockedAt = storedDate
            if Date().timeIntervalSince(storedDate) < Self.gracePeriod {
                isUnlocked = true
            }
        }
    }

    /// Records a successful unlock both in-memory and persisted (see `lastUnlockedAtDefaultsKey`'s
    /// own header for why this must survive a force-quit, not just live in `lastUnlockedAt`).
    private func recordUnlock(at date: Date) {
        lastUnlockedAt = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.lastUnlockedAtDefaultsKey)
    }

    /// Whether this device can evaluate Face ID/Touch ID/passcode at all right now, and if not, why.
    func availability() -> BiometricAvailability {
        authenticator.canEvaluateDeviceOwnerAuthentication()
    }

    /// Attempts Face ID/Touch ID/passcode authentication.
    ///
    /// - Parameter surfaceErrors: When `false` (used for the automatic prompt that fires the
    ///   instant the lock screen appears), a failure is recorded internally but never shown to
    ///   the user — an unattended first attempt failing isn't a real "wrong face" failure worth
    ///   alarming anyone over, it's usually just the OS not having had a chance to recognize
    ///   anything yet. Pass `true` for anything the user explicitly triggered (tapping "Unlock
    ///   with Face ID"), where a failure is real feedback worth showing.
    ///
    ///   Simulator testing note: Face ID in the Simulator does nothing on its own. Enroll it via
    ///   Features > Face ID > Enrolled, then trigger a result via Features > Face ID > Matching
    ///   Face (succeeds) or Non-matching Face (fails) while the prompt is active. Without doing
    ///   this, an automatic attempt will always fail instantly — which is exactly the case
    ///   `surfaceErrors: false` exists to keep quiet.
    @MainActor
    func authenticate(reason: String = "Unlock SpendSmart", surfaceErrors: Bool = true) async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        lastErrorMessage = nil

        let availability = authenticator.canEvaluateDeviceOwnerAuthentication()
        guard case .available = availability else {
            if case .unavailable(let unavailableReason) = availability {
                lastErrorMessage = unavailableReason
            }
            // No biometrics/passcode configured on this device — there's no way to secure the
            // lock screen, so don't strand the user behind it.
            isUnlocked = true
            recordUnlock(at: .now)
            return
        }

        do {
            let success = try await authenticator.evaluateDeviceOwnerAuthentication(reason: reason)
            isUnlocked = success
            if success { recordUnlock(at: .now) }
        } catch let authError as LAError {
            isUnlocked = false
            lastErrorMessage = surfaceErrors ? Self.friendlyMessage(for: authError) : nil
        } catch {
            isUnlocked = false
            lastErrorMessage = surfaceErrors ? "We couldn't verify your identity. Please try again." : nil
        }
    }

    /// The single entry point for the lock screen's automatic (silent) Face ID attempt —
    /// `AppLockView.task` calls this instead of `authenticate` directly, so "exactly one
    /// automatic attempt per lock presentation" is enforced here rather than depending on
    /// SwiftUI's own `.task`-runs-once-per-mount timing. A no-op if the automatic attempt has
    /// already run for the current lock presentation (see `hasAttemptedAutomaticUnlock`); does
    /// not affect the user's own manual retries, which always call `authenticate` directly.
    @MainActor
    func authenticateAutomaticallyIfNeeded() async {
        guard !hasAttemptedAutomaticUnlock else { return }
        hasAttemptedAutomaticUnlock = true
        await authenticate(surfaceErrors: false)
    }

    /// Manually re-locks the app (e.g. a "Lock Now" button in Settings) — this is also the one
    /// place `hasAttemptedAutomaticUnlock` resets, since re-locking is exactly what starts a new
    /// lock presentation that deserves its own fresh automatic attempt.
    func lock() {
        isUnlocked = false
        lastErrorMessage = nil
        hasAttemptedAutomaticUnlock = false
        // FORCE-QUIT FIX — clears the persisted timestamp too, not just the in-memory one, so an
        // explicit lock (or a grace period that has genuinely expired) actually forces
        // re-authentication on the very next cold launch, not just the next foreground return.
        lastUnlockedAt = nil
        UserDefaults.standard.removeObject(forKey: Self.lastUnlockedAtDefaultsKey)
    }

    /// GRACE PERIOD — the app's background-transition handler calls this instead of `lock()`, so
    /// a brief app-switch (checking another app, answering a text) doesn't force Face ID again:
    /// only re-locks if it's been at least `gracePeriod` since the last successful unlock. Never
    /// unlocks anything itself — it can only leave `isUnlocked` as it already was, or flip it to
    /// `false`. A `nil` `lastUnlockedAt` (never yet unlocked this session) locks unconditionally,
    /// the same as if the grace period had already elapsed.
    func lockIfGraceExpired(now: Date = .now) {
        guard isUnlocked else { return }
        guard let lastUnlockedAt, now.timeIntervalSince(lastUnlockedAt) < Self.gracePeriod else {
            lock()
            return
        }
    }

    /// Maps an `LAError` from a failed `evaluatePolicy` attempt to plain-English text. Returns
    /// `nil` for cases the user triggered on purpose (tapping Cancel, choosing the passcode
    /// fallback) — those aren't failures worth alarming them about.
    private static func friendlyMessage(for error: LAError) -> String? {
        switch error.code {
        case .userCancel, .appCancel, .systemCancel, .userFallback:
            return nil
        case .biometryNotAvailable:
            return "Face ID isn't available on this device."
        case .biometryNotEnrolled:
            return "Face ID isn't set up on this device yet."
        case .biometryLockout:
            return "Face ID is temporarily locked. Try again later or use your passcode."
        case .authenticationFailed:
            return "That didn't match. Try again."
        default:
            return "We couldn't verify your identity. Please try again."
        }
    }
}
