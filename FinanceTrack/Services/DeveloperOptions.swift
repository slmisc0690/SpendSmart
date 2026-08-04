#if DEBUG
import Foundation

/// DEBUG-BUILD-ONLY developer preferences. The ENTIRE file is wrapped in `#if DEBUG` — nothing
/// here compiles into a Release/TestFlight/App Store build, so there is no code path, symbol, or
/// stored key for a Release build to accidentally reach.
///
/// `refreshLimitEnabledKey` is a plain standard-`UserDefaults` key, deliberately NOT one of this
/// project's per-user-namespaced settings (see `UserDataStoreManager`) — this is a developer's own
/// machine-level testing preference, identical in spirit to a scheme flag, never tied to any
/// authenticated user's data and never synced to Supabase/cloud/household state.
enum DeveloperOptions {
    static let refreshLimitEnabledKey = "dev.refreshLimitEnabled"
}
#endif
