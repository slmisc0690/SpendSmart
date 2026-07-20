import Foundation
import SwiftData
import Observation

/// Watches for SwiftData saves and, when enabled, writes a debounced local auto-backup to the
/// app's Documents directory — never anywhere off-device. This is the single place that wires
/// every "add/edit/delete an account, transaction, bill, income source, Monthly Plan setting, or
/// budget setting" trigger listed in the Data Backup spec: rather than calling "back up now" from
/// every save site across the app (a large, error-prone surface), this observes
/// `ModelContext.didSave` — the notification SwiftData posts after *any* save, explicit or
/// autosaved — so it can't miss a trigger point, and touches no other screen's code.
@Observable
final class AutoBackupManager {
    /// Set after each attempted backup so the Data Backup screen can show whether the last one
    /// succeeded, without throwing anywhere the user can't see it.
    private(set) var lastBackupError: String?

    private var observer: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private let debounceDelay: Duration

    init(debounceDelay: Duration = .seconds(3)) {
        self.debounceDelay = debounceDelay
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Starts observing `context`'s saves. Safe to call more than once (e.g. across view
    /// re-appearances) — later calls replace the previous observation rather than stacking.
    /// Whether auto-backup is actually enabled is re-checked fresh from SwiftData inside the
    /// debounced, main-actor `performBackup` step rather than here, so it can't go stale if the
    /// settings record is ever replaced (e.g. by a backup restore) after this is called.
    func startObserving(context: ModelContext) {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: context,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleBackup(context: context)
        }
    }

    /// Stops observing entirely and cancels any pending debounced backup — called on sign-out so
    /// no backup for the outgoing user's `ModelContext` can fire after its owning container
    /// reference has been (or is about to be) released elsewhere. Safe to call even if never
    /// started. The next user's `RootView.task` calling `startObserving(context:)` re-arms this
    /// for their own context; `deinit` mirrors this same cleanup for the (never-exercised, since
    /// this is a single app-lifetime instance) case of the instance itself being deallocated.
    func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Cancels any pending debounced backup and restarts the debounce window — repeated saves in
    /// quick succession (e.g. typing) keep pushing the actual write back rather than firing one
    /// per keystroke.
    private func scheduleBackup(context: ModelContext) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounceDelay] in
            try? await Task.sleep(for: debounceDelay)
            guard !Task.isCancelled else { return }
            await self?.performBackup(context: context)
        }
    }

    @MainActor
    private func performBackup(context: ModelContext) async {
        do {
            let settings = try context.fetch(FetchDescriptor<BudgetSettings>()).first
            guard settings?.autoBackupEnabled ?? true else { return }

            let document = try SpendSmartBackupService.fetchAndMakeDocument(context: context)
            try SpendSmartBackupService.writeAutoBackup(document, to: SpendSmartBackupService.documentsDirectory())
            lastBackupError = nil
        } catch {
            // Auto-backup failures are silent-but-visible: never interrupt the user's flow, but
            // surface the last error on the Data Backup screen so it isn't invisible forever.
            lastBackupError = error.localizedDescription
        }
    }
}
