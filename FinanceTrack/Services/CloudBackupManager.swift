import Foundation
import SwiftData
import Observation

/// Watches for SwiftData saves and, when enabled, writes a debounced backup into this app's own
/// iCloud Documents ubiquity container — the "restore after a fresh install/new device" answer for
/// Monthly Plan, Manual Accounts, and everything else `SpendSmartBackupService.Document` already
/// covers (Accounts, Transactions, Categories, Budget/Monthly Plan Settings, Income Sources,
/// Recurring Expenses). Mirrors `AutoBackupManager`'s exact shape (same `ModelContext.didSave`
/// observation, same debounce, same sign-out generation-check safety) — the only real differences
/// are the write destination (iCloud container instead of local Documents) and the filename/
/// retention rule: ONE file per calendar day (`SpendSmartBackupService.cloudBackupFilename`), so
/// repeated edits in the same day overwrite that day's file instead of accumulating, and anything
/// older than the configured retention (default 7, user-adjustable — see
/// `BudgetSettings.cloudBackupRetentionDays`'s own header) is deleted after every write. This is
/// change-triggered, not launch-triggered — a day with no edits simply produces no new file, which
/// is correct: nothing changed, so there is nothing new to preserve a restore point for.
@Observable
final class CloudBackupManager {
    /// Set after each attempted backup so the Data Backup screen can show whether the last one
    /// succeeded — mirrors `AutoBackupManager.lastBackupError` exactly, including its "never throw
    /// where the user can't see it" posture.
    private(set) var lastBackupError: String?

    private var observer: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private let debounceDelay: Duration
    /// Only ever used when no `BudgetSettings` row exists yet (a brand-new install, before
    /// `RootView`'s own bootstrap creates one) — every other path reads the live, user-adjustable
    /// `BudgetSettings.cloudBackupRetentionDays` instead, via `normalizedRetentionDays(_:)`.
    private let fallbackRetentionDays: Int
    /// Same proven sign-out/sign-in race fix as `AutoBackupManager.generation` — see that
    /// property's own doc comment for the exact crash this closes.
    private var generation = 0

    init(debounceDelay: Duration = .seconds(3), fallbackRetentionDays: Int = 7) {
        self.debounceDelay = debounceDelay
        self.fallbackRetentionDays = fallbackRetentionDays
    }

    /// `nil`, `0`, or negative all mean "use the default" — a literal 0-day retention would prune
    /// every backup immediately, including the one just written, silently defeating the whole
    /// feature. Never clamped to some other minimum (e.g. 1) beyond this: a user who deliberately
    /// enters 1 gets exactly 1 day of history, their own explicit choice.
    static func normalizedRetentionDays(_ stored: Int?, fallback: Int = 7) -> Int {
        guard let stored, stored > 0 else { return fallback }
        return stored
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// This app's iCloud Documents ubiquity container root — `nil` if iCloud Drive is off,
    /// unavailable, or the container hasn't finished provisioning yet. Every call site treats
    /// `nil` as "skip silently," matching `AutoBackupManager`'s own posture toward any backup
    /// failure: this is a best-effort convenience, never something that can block or interrupt the
    /// user's actual work.
    static func ubiquityBackupDirectory() -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
        let directory = container.appendingPathComponent("Documents", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// Starts observing `context`'s saves. Safe to call more than once — later calls replace the
    /// previous observation rather than stacking, matching `AutoBackupManager.startObserving`.
    func startObserving(context: ModelContext) {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        generation += 1
        let observationGeneration = generation
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: context,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleBackup(context: context, generation: observationGeneration)
        }
    }

    /// Stops observing entirely and cancels any pending debounced backup — called on sign-out, same
    /// reasoning and same call-site pairing as `AutoBackupManager.stopObserving`.
    func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        debounceTask?.cancel()
        debounceTask = nil
        generation += 1
    }

    private func scheduleBackup(context: ModelContext, generation callGeneration: Int) {
        guard callGeneration == generation else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounceDelay] in
            try? await Task.sleep(for: debounceDelay)
            guard !Task.isCancelled else { return }
            await self?.performBackup(context: context, generation: callGeneration)
        }
    }

    @MainActor
    private func performBackup(context: ModelContext, generation callGeneration: Int) async {
        guard callGeneration == generation else { return }
        do {
            let settings = try context.fetch(FetchDescriptor<BudgetSettings>()).first
            guard settings?.autoBackupEnabled ?? true else { return }
            guard let directory = Self.ubiquityBackupDirectory() else {
                // iCloud Drive off/unavailable — not an error the user needs surfaced here; the
                // existing local auto-backup (AutoBackupManager) still runs independently.
                return
            }

            let document = try SpendSmartBackupService.fetchAndMakeDocument(context: context)
            let data = try SpendSmartBackupService.encode(document)
            let url = directory.appendingPathComponent(SpendSmartBackupService.cloudBackupFilename())
            try data.write(to: url, options: .atomic)
            let retentionDays = Self.normalizedRetentionDays(settings?.cloudBackupRetentionDays, fallback: fallbackRetentionDays)
            Self.pruneExpiredCloudBackups(in: directory, retentionDays: retentionDays)
            lastBackupError = nil
        } catch {
            lastBackupError = error.localizedDescription
        }
    }

    /// Deletes every dated backup file older than `retentionDays` distinct calendar days — never
    /// throws (a stray extra file is harmless; failing silently here must never block the backup
    /// that was just successfully written), matching `pruneAutoBackups`'s own "never lose the new
    /// write over a prune failure" posture.
    static func pruneExpiredCloudBackups(in directory: URL, referenceDate: Date = .now, retentionDays: Int = 7) {
        for filename in SpendSmartBackupService.cloudBackupFilenames(in: directory)
        where SpendSmartBackupService.isCloudBackupExpired(filename: filename, referenceDate: referenceDate, retentionDays: retentionDays) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
        }
    }
}
