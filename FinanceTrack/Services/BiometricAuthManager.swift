import Foundation
import LocalAuthentication
import Observation

/// Wraps `LocalAuthentication` for the Face ID / Touch ID app lock. No credentials or network
/// calls involved — this only asks the OS to evaluate the device owner's biometric/passcode policy.
enum BiometricAvailability: Equatable {
    case available
    case unavailable(reason: String)
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

    /// Guards against overlapping `authenticate()` calls (e.g. SwiftUI re-running `.task` while a
    /// prior evaluation is still pending) — without this, two concurrent Face ID prompts can
    /// stack, and the OS cancelling one mid-flight can spuriously clear/set the other's result.
    private var isAuthenticating = false

    /// Whether this device can evaluate Face ID/Touch ID/passcode at all right now, and if not, why.
    func availability() -> BiometricAvailability {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable(reason: Self.friendlyUnavailableMessage(for: error))
        }
        return .available
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
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastErrorMessage = Self.friendlyUnavailableMessage(for: error)
            // No biometrics/passcode configured on this device — there's no way to secure the
            // lock screen, so don't strand the user behind it.
            isUnlocked = true
            return
        }

        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            isUnlocked = success
        } catch let authError as LAError {
            isUnlocked = false
            lastErrorMessage = surfaceErrors ? Self.friendlyMessage(for: authError) : nil
        } catch {
            isUnlocked = false
            lastErrorMessage = surfaceErrors ? "We couldn't verify your identity. Please try again." : nil
        }
    }

    /// Manually re-locks the app (e.g. a "Lock Now" button in Settings).
    func lock() {
        isUnlocked = false
        lastErrorMessage = nil
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

    private static func friendlyUnavailableMessage(for error: NSError?) -> String {
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
