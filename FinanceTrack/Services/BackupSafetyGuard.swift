import Foundation

/// Decides whether a freshly built backup is safe to keep, so a bad (empty, half-loaded or
/// truncated) store can never overwrite or push out a good backup.
enum BackupSafetyGuard {
    enum Decision: Equatable {
        case allow
        case reject(String)

        var isAllowed: Bool { self == .allow }
    }

    /// A backup smaller than this fraction of the previous good one is treated as damaged.
    static let minimumTransactionFraction = 0.5
    /// Below this many previous transactions, the size comparison is skipped (too little data to judge).
    static let minimumPreviousTransactionsForComparison = 20

    static func evaluate(new: SpendSmartBackupService.Document, previous: SpendSmartBackupService.Document?) -> Decision {
        let looksEmpty = new.transactions.isEmpty && new.accounts.isEmpty && new.budgetSettings.isEmpty
        if looksEmpty { return .reject("the app has no data to back up right now") }

        guard let previous else { return verified(new) }

        if !previous.accounts.isEmpty && new.accounts.isEmpty {
            return .reject("all accounts are missing compared with your last good backup")
        }
        if !previous.budgetSettings.isEmpty && new.budgetSettings.isEmpty {
            return .reject("your settings are missing compared with your last good backup")
        }
        if previous.transactions.count >= minimumPreviousTransactionsForComparison,
           Double(new.transactions.count) < Double(previous.transactions.count) * minimumTransactionFraction {
            return .reject("only \(new.transactions.count) transactions were found, against \(previous.transactions.count) in your last good backup")
        }
        if previous.extras != nil && new.extras == nil {
            return .reject("the device-only settings could not be read")
        }
        return verified(new)
    }

    /// The backup must survive an encode, decode round trip with the same counts before it is kept.
    private static func verified(_ document: SpendSmartBackupService.Document) -> Decision {
        guard let data = try? SpendSmartBackupService.encode(document),
              let decoded = try? SpendSmartBackupService.decode(data),
              decoded.transactions.count == document.transactions.count,
              decoded.accounts.count == document.accounts.count,
              decoded.budgetSettings.count == document.budgetSettings.count
        else { return .reject("the backup could not be verified after writing") }
        return .allow
    }

    /// The newest readable backup in `directory` whose filename starts with any of `prefixes`.
    static func loadLatest(in directory: URL, prefixes: [String]) -> SpendSmartBackupService.Document? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let candidates = files
            .filter { url in url.pathExtension == "json" && prefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l > r
            }
        for url in candidates {
            if let data = try? Data(contentsOf: url), let document = try? SpendSmartBackupService.decode(data) { return document }
        }
        return nil
    }
}
