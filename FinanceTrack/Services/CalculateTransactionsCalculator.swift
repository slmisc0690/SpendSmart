import Foundation

/// CALCULATE TRANSACTIONS PHASE — pure, read-only math/selection logic for the "Calculate
/// Transactions" Tool (Settings ▸ Tools). Deliberately mirrors `BudgetCalculator`'s own shape: a
/// stateless enum of static functions operating on plain `FinanceTransaction`/`Account` arrays,
/// directly testable with no `ModelContext` — never a mutation, never a network call, never a
/// SwiftData write. The SwiftUI screen (`CalculateTransactionsView`) is a thin presentation layer
/// over these functions; all the actual selection/total math lives here.
enum CalculateTransactionsCalculator {
    enum TotalMode: String, CaseIterable, Identifiable {
        case signed
        case absolute

        var id: String { rawValue }

        var label: String {
            switch self {
            case .signed: return "Signed"
            case .absolute: return "Absolute"
            }
        }
    }

    /// One selectable account for this calculator — either a Manual Account (by its stable
    /// `Account.id`) or a connected Plaid account (by its stable Plaid `account_id` string, the
    /// same identifier `FinanceTransaction.plaidAccountId`/`ConnectedAccountOptionPresenter`
    /// already key by). Never a fabricated third identity scheme.
    struct AccountOption: Identifiable, Equatable {
        enum Kind: Equatable {
            case manual(accountID: UUID)
            case connected(plaidAccountID: String)
        }

        /// A stable, screen-local string key — "manual-<uuid>" or "connected-<plaid id>" — used
        /// only for `Picker`/`ForEach` identity in the UI layer, never persisted.
        let id: String
        let kind: Kind
        let displayName: String
    }

    /// Every account eligible for this calculator: a Manual Account or connected Plaid account
    /// that actually HAS at least one transaction — an account with no transactions has nothing
    /// meaningful to calculate and is silently omitted (never shown as a dead/empty choice).
    /// Reuses the app's existing canonical presenters/fields rather than inventing a second
    /// account-name mapping system: `ConnectedAccountOptionPresenter.options(for:)` for connected
    /// accounts (its own institution/mask ambiguity handling is used as-is), and `Account.name`
    /// plus `Account.lastFourDigits`/`institutionName` for Manual Accounts, disambiguated the same
    /// "only append when the plain name collides" way. Sorted alphabetically by the FINAL
    /// (possibly disambiguated) display name.
    static func accountOptions(
        manualAccounts: [Account],
        transactions: [FinanceTransaction],
        connections: [PlaidConnection]
    ) -> [AccountOption] {
        struct Raw {
            let id: String
            let kind: AccountOption.Kind
            let name: String
            let disambiguator: String?
        }

        var raw: [Raw] = []

        for account in manualAccounts where !account.isArchived {
            let hasTransactions = transactions.contains {
                $0.account?.id == account.id || $0.transferDestinationAccount?.id == account.id
            }
            guard hasTransactions else { continue }
            var disambiguator: String?
            if let lastFour = account.lastFourDigits, !lastFour.isEmpty {
                disambiguator = "\u{2022}\u{2022}\u{2022}\u{2022}\(lastFour)"
            } else if let institution = account.institutionName, !institution.isEmpty {
                disambiguator = institution
            }
            raw.append(Raw(id: "manual-\(account.id.uuidString)", kind: .manual(accountID: account.id), name: account.name, disambiguator: disambiguator))
        }

        for option in ConnectedAccountOptionPresenter.options(for: connections) {
            let hasTransactions = transactions.contains { $0.source == .plaid && $0.plaidAccountId == option.id }
            guard hasTransactions else { continue }
            // `option.label` is already institution/mask-disambiguated by
            // `ConnectedAccountOptionPresenter` itself — never re-disambiguated here.
            raw.append(Raw(id: "connected-\(option.id)", kind: .connected(plaidAccountID: option.id), name: option.label, disambiguator: nil))
        }

        let nameCounts = Dictionary(grouping: raw, by: \.name).mapValues(\.count)
        let resolved = raw.map { entry -> AccountOption in
            let isAmbiguous = (nameCounts[entry.name] ?? 0) > 1
            let displayName: String
            if isAmbiguous, let disambiguator = entry.disambiguator {
                displayName = "\(entry.name) \(disambiguator)"
            } else {
                displayName = entry.name
            }
            return AccountOption(id: entry.id, kind: entry.kind, displayName: displayName)
        }

        return resolved.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// ALL of an account's transactions, unfiltered by date — the canonical per-account fetch
    /// pattern this app already uses (`CreditCardDetailView`/`ManualAccountDetailView` for Manual
    /// Accounts, `ActivityTabPresenter.transactions(for:in:)` for connected accounts), never a new
    /// predicate/query. This is the set Account Subtotal/Select All/Clear Account all key off of —
    /// NOT the date-filtered visible list — so a selection made before a filter change is never
    /// silently lost from the math.
    static func allTransactions(for option: AccountOption, in transactions: [FinanceTransaction]) -> [FinanceTransaction] {
        switch option.kind {
        case .manual(let accountID):
            return transactions.filter { $0.account?.id == accountID || $0.transferDestinationAccount?.id == accountID }
        case .connected(let plaidAccountID):
            return transactions.filter { $0.source == .plaid && $0.plaidAccountId == plaidAccountID }
        }
    }

    /// The VISIBLE list for the transaction picker — the account's full set, restricted to the
    /// active date filter (`nil` interval = "All", no restriction), sorted newest-first. `sorted`
    /// is a stable sort (guaranteed by the Swift standard library), so transactions sharing an
    /// identical date keep their original relative order rather than shuffling on every re-render.
    static func visibleTransactions(from accountTransactions: [FinanceTransaction], dateInterval: DateInterval?) -> [FinanceTransaction] {
        let filtered: [FinanceTransaction]
        if let dateInterval {
            filtered = accountTransactions.filter { dateInterval.contains($0.date) }
        } else {
            filtered = accountTransactions
        }
        return filtered.sorted { $0.date > $1.date }
    }

    /// The canonical signed-amount convention, matching `TransactionRow`/`ConnectedTransactionRow`'s
    /// own established display sign exactly (expense/transferWithdrawal/transferToSavings are
    /// negative; refund/income/transferDeposit are positive; transfer/creditCardPayment/
    /// balanceAdjustment display with no sign prefix — i.e. their plain positive magnitude).
    /// `FinanceTransaction.amount` is always stored as a non-negative magnitude; the sign is
    /// entirely derived here from `type`, never read from a negative stored value.
    static func signedAmount(for transaction: FinanceTransaction) -> Decimal {
        switch transaction.type {
        case .expense, .transferWithdrawal, .transferToSavings:
            return -transaction.amount
        case .refund, .income, .transferDeposit, .transfer, .creditCardPayment, .balanceAdjustment:
            return transaction.amount
        }
    }

    /// The amount a single transaction contributes to a total, in the given `mode`. Absolute mode
    /// always uses the magnitude (`abs`) — defensive even though `amount` is already non-negative
    /// by convention, per this feature's own explicit "add magnitudes only" requirement.
    static func contribution(of transaction: FinanceTransaction, mode: TotalMode) -> Decimal {
        switch mode {
        case .signed: return signedAmount(for: transaction)
        case .absolute: return abs(transaction.amount)
        }
    }

    /// The selected subset of `transactions` — pure `Set<UUID>` membership, `FinanceTransaction.id`
    /// being the stable identity this whole feature keys off of (never a row index).
    static func selected(from transactions: [FinanceTransaction], selectedIDs: Set<UUID>) -> [FinanceTransaction] {
        transactions.filter { selectedIDs.contains($0.id) }
    }

    /// Decimal, deterministic, app-local math — sums every selected transaction's `contribution`.
    /// `$0.00` for an empty list, never NaN/blank. Never routed through SpendAI/FoundationModels.
    static func total(of transactions: [FinanceTransaction], mode: TotalMode) -> Decimal {
        transactions.reduce(Decimal(0)) { $0 + contribution(of: $1, mode: mode) }
    }

    /// One row of the "Selected Transactions" cross-account summary — one account's selected
    /// count + subtotal, in the SAME order `accountOptions` already sorts by (alphabetical display
    /// name), never a separate ordering.
    struct SelectedAccountSummary: Identifiable, Equatable {
        let option: AccountOption
        let selectedCount: Int
        let subtotal: Decimal
        var id: String { option.id }
    }

    /// Builds the per-account summary rows for every option that has at least one selected
    /// transaction (an account with zero selections is omitted — never a "0 selected" row).
    ///
    /// PERFORMANCE PHASE — kept for direct-array callers/tests; re-derives each account's
    /// transactions from the FULL table on every call (an O(accounts × transactions) scan). The
    /// view itself now calls the `accountTransactionsByOptionID:` overload below instead, which
    /// reuses `CalculateTransactionsViewModel`'s already-precomputed per-account index — see that
    /// overload's own header for why this one must never be called from `body`.
    static func selectedSummaries(
        options: [AccountOption],
        allTransactions: [FinanceTransaction],
        selectedIDs: Set<UUID>,
        mode: TotalMode
    ) -> [SelectedAccountSummary] {
        var byOptionID: [String: [FinanceTransaction]] = [:]
        for option in options {
            byOptionID[option.id] = Self.allTransactions(for: option, in: allTransactions)
        }
        return selectedSummaries(options: options, accountTransactionsByOptionID: byOptionID, selectedIDs: selectedIDs, mode: mode)
    }

    /// PERFORMANCE PHASE — the fast path: `accountTransactionsByOptionID` is a PRECOMPUTED index
    /// (built once by `CalculateTransactionsViewModel.prepare(...)` whenever the underlying data
    /// actually changes, never on every SwiftUI `body` pass), so recomputing this on every
    /// selection change costs O(accounts × selectedCount) — a dictionary lookup plus a filter over
    /// each account's own (small) transaction list — never a fresh O(accounts × ALL transactions)
    /// scan of the whole table.
    static func selectedSummaries(
        options: [AccountOption],
        accountTransactionsByOptionID: [String: [FinanceTransaction]],
        selectedIDs: Set<UUID>,
        mode: TotalMode
    ) -> [SelectedAccountSummary] {
        options.compactMap { option in
            let accountTransactions = accountTransactionsByOptionID[option.id] ?? []
            let selectedForAccount = selected(from: accountTransactions, selectedIDs: selectedIDs)
            guard !selectedForAccount.isEmpty else { return nil }
            return SelectedAccountSummary(
                option: option,
                selectedCount: selectedForAccount.count,
                subtotal: total(of: selectedForAccount, mode: mode)
            )
        }
    }

    /// CANONICAL BUDGET EXCLUSION MEMBERSHIP — mirrors `BudgetCalculator`'s own exact gating: an
    /// `excludedTransactionIDs` entry only actually excludes anything while the feature's master
    /// toggle (`excludeTransactionsEnabled`) is on; `nil`/`false` means "off," treated as if the
    /// list were empty regardless of its stored contents — the SAME "as if it never existed" rule
    /// `BudgetSettings.excludeTransactionsEnabled`'s own header documents. Never a second,
    /// independently-invented exclusion concept — this reads the exact same `BudgetSettings`
    /// fields Budget Exclusions itself owns, and never writes to either.
    static func budgetExcludedIDs(excludeTransactionsEnabled: Bool?, excludedTransactionIDs: [UUID]?) -> Set<UUID> {
        guard excludeTransactionsEnabled == true else { return [] }
        return Set(excludedTransactionIDs ?? [])
    }

    /// EXCLUDED-ONLY MODE — filters an already-gathered pool of transactions (typically
    /// `CalculateTransactionsViewModel.allEligibleTransactions`, i.e. every eligible account's
    /// transactions already deduplicated) down to just the ones whose id is in the canonical
    /// Budget Exclusions set. Pure/stateless, directly testable — never touches `BudgetSettings`,
    /// never mutates a transaction. This is what the "Excluded Transactions" toggle uses to REPLACE
    /// the selected-account list (an override, not an additive include) once it's ON.
    static func excludedOnly(from transactions: [FinanceTransaction], excludedIDs: Set<UUID>) -> [FinanceTransaction] {
        transactions.filter { excludedIDs.contains($0.id) }
    }

    /// PERFORMANCE PHASE — the fast path for resolving the full selection set: `transactionsByID`
    /// is `CalculateTransactionsViewModel`'s precomputed `[UUID: FinanceTransaction]` index, so
    /// this costs O(selectedCount) — a dictionary lookup per selected id — never an O(allTransactions)
    /// scan of the whole table (which is what a naive `allTransactions.filter { selectedIDs.contains($0.id) }`
    /// would cost, and what made the Grand Total recompute expensive on every single checkbox tap
    /// before this phase — see this feature's own performance audit).
    static func selectedTransactions(selectedIDs: Set<UUID>, transactionsByID: [UUID: FinanceTransaction]) -> [FinanceTransaction] {
        selectedIDs.compactMap { transactionsByID[$0] }
    }
}

/// CALCULATE TRANSACTIONS PHASE — the calculator's compact date-range filter, reusing
/// `DateRangeHelper`'s existing interval math directly rather than duplicating it. `.all` (`nil`
/// interval) is the deliberate "no restriction" case.
enum CalculateTransactionsDateFilter: String, CaseIterable, Identifiable {
    case thisWeek
    case thisMonth
    case lastMonth
    case quarter
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thisWeek: return "This Week"
        case .thisMonth: return "This Month"
        case .lastMonth: return "Last Month"
        case .quarter: return "Quarter"
        case .all: return "All"
        }
    }

    func interval(referenceDate: Date = .now) -> DateInterval? {
        switch self {
        case .thisWeek: return DateRangeHelper.currentWeekRange()
        case .thisMonth: return DateRangeHelper.currentMonthRange()
        case .lastMonth: return DateRangeHelper.lastMonthRange(relativeTo: referenceDate)
        case .quarter: return DateRangeHelper.currentQuarterRange()
        case .all: return nil
        }
    }
}
