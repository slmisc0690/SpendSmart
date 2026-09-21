import Foundation

/// RUNTIME RELIABILITY PHASE — the "high-confidence deterministic fallback router" this feature's
/// own reliability brief calls for: a narrow, keyword/phrase-based interpreter for domains where
/// natural-language ambiguity is low and getting a wrong/missing answer is especially bad (Budget
/// Exclusions, at minimum, per that brief). This is NOT a replacement for Apple's on-device model —
/// `SystemAskSpendSmartService.send(_:)` still tries this router FIRST for a confident match (so the
/// literal reported failure, "give me the total of excluded transactions in the past two weeks,"
/// is answered with zero dependency on the model's own tool-selection judgment), and falls through
/// to the model unchanged for anything it doesn't recognize. Deliberately never imports
/// `FoundationModels` — plain Swift, directly unit-testable on every deployment target, exactly
/// like `AskSpendSmartToolContext` itself.
///
/// This intentionally does NOT attempt every domain in `AskSpendSmartToolContext` — only Budget
/// Exclusions, the domain with a concrete, reported, reproducible failure. Extending it to another
/// domain is a future, separately-scoped phase; adding one here "because it's easy" without a
/// concrete failure to fix would be exactly the kind of scope creep this app's own conventions
/// avoid.
enum AskSpendSmartFallbackRouter {
    enum Operation: Sendable, Equatable {
        case count
        case amount
        case both
        case list
        /// COMPOUND-REQUEST PHASE — a single question that asks for more than one distinct kind of
        /// answer at once ("how many excluded transactions this week, show me all of them, and a
        /// total") used to silently collapse to whichever keyword `matchOperationKeyword` happened
        /// to check first, discarding the rest of what was actually asked — not a data-access gap
        /// (`BudgetExclusionsResult` already carries count/total/list together on every fetch), a
        /// pure "which one do I mention" bug. `.all` means "present count, total, AND the list
        /// together," and is only ever produced when 2+ of those keyword categories are present in
        /// the same question.
        case all
    }

    struct RoutedBudgetExclusionsQuery: Sendable, Equatable {
        let operation: Operation
        /// `nil` means all-time — no date restriction, matching
        /// `AskSpendSmartToolContext.budgetExclusions(dateRange:)`'s own "nil = all-time" default.
        let dateRange: DateInterval?
        let dateRangeLabel: String
    }

    // MARK: - Domain recognition

    private static let budgetExclusionsKeywords = ["exclusion", "excluded"]

    /// Ordinary wording, not exact preset phrases — "budget exclusions," "excluded transactions,"
    /// "transactions I excluded," "excluded from my budget," "checked exclusions" all contain one
    /// of these two substrings. No other SpendSmart domain uses either word, so this carries
    /// negligible false-positive risk within this app's own vocabulary.
    static func matchesBudgetExclusionsDomain(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return budgetExclusionsKeywords.contains { normalized.contains($0) }
    }

    /// Returns `nil` when `text` doesn't confidently match the Budget Exclusions domain at all —
    /// the caller must fall through to the on-device model in that case, never treat `nil` as "zero
    /// exclusions."
    static func routeBudgetExclusions(_ text: String, now: Date, calendar: Calendar = .current) -> RoutedBudgetExclusionsQuery? {
        guard matchesBudgetExclusionsDomain(text) else { return nil }
        let normalized = text.lowercased()
        let operation = parseOperation(normalized)
        let (range, label) = parseDateRange(normalized, now: now, calendar: calendar)
        return RoutedBudgetExclusionsQuery(operation: operation, dateRange: range, dateRangeLabel: label)
    }

    // MARK: - Operation recognition

    /// HONEST-MATCH PHASE — returns `nil` when NO operation keyword is present at all, so the
    /// caller can tell a genuine match from a silent default. Scott's own explicit requirement:
    /// "You have 12 excluded transactions totaling $847" is a true statement and a non-answer to
    /// "what are my excluded transactions" — presenting a default as if it were the answer is
    /// worse than admitting the question wasn't understood. "total" is deliberately its OWN
    /// confident match (not the fallthrough) — a bare "total of X" was already reasoned through as
    /// a genuine, intentional ambiguity between count and dollar total (see
    /// `testEndToEndPastTwoWeeksExcludedTransactionsTotal`'s own comment), not a failure to
    /// classify, so it must never trigger the "I'm not sure what you're asking" wording.
    /// COMPOUND-REQUEST PHASE — checks every category rather than returning on the first match, so
    /// a question naming more than one ("how many excluded transactions this week, show me all of
    /// them, and a total") is recognized as genuinely asking for all of them (`.all`) instead of
    /// silently collapsing to whichever category happened to be checked first.
    private static func matchOperationKeyword(_ normalized: String) -> Operation? {
        let hasCount = normalized.contains("how many") || normalized.contains("number of") || normalized.contains("count")
        let hasList = normalized.contains("list") || normalized.contains("show me") || normalized.contains("show my")
            || normalized.contains("which transaction") || normalized.contains("what transaction")
            || normalized.contains("what are") || normalized.contains("what were")
            || normalized.contains("break down") || normalized.contains("breakdown") || normalized.contains("itemize")
        let hasAmount = normalized.contains("how much")
        let hasTotalWord = normalized.contains("total")

        // "list" alongside ANY numeric ask (count/amount/"total") is the genuine compound case —
        // the user wants the itemized list AND a number, never just one or the other.
        if hasList && (hasCount || hasAmount || hasTotalWord) {
            return .all
        }
        // "total" ahead of a bare "how many" (no list): `.both`'s wording already states BOTH the
        // count and the dollar total, so "how many ... and what's the total" is already fully
        // answered by `.both` — checking it before `hasCount` here avoids re-introducing the exact
        // same "silently drop the total" bug this phase exists to fix, just for this pair instead
        // of pairing with `.list`.
        if hasTotalWord {
            return .both
        }
        if hasCount {
            return .count
        }
        if hasList {
            return .list
        }
        if hasAmount {
            return .amount
        }
        return nil
    }

    /// Preserves the exact prior behavior (no keyword → `.both`) for the ONE caller that doesn't
    /// need to distinguish a genuine match from a silent default — the follow-up-context path
    /// below, where a bare "what was that?" after an already-answered Budget Exclusions question
    /// defaulting to both is pre-existing behavior Scott did not ask to change. The Budget
    /// Exclusions plan-building branch calls `matchOperationKeyword` directly instead, specifically
    /// so it CAN tell the difference (see `operationWasExplicit` on `SpendAIQueryPlan`).
    private static func parseOperation(_ normalized: String) -> Operation {
        matchOperationKeyword(normalized) ?? .both
    }

    // MARK: - Date-range recognition (rolling windows are LOCAL to this router — see this type's
    // own header on why `DateRangeHelper` itself is never modified for this)

    private static func parseDateRange(_ normalized: String, now: Date, calendar: Calendar) -> (DateInterval?, String) {
        if normalized.contains("yesterday") {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
            return (DateRangeHelper.dayRangeContaining(yesterday, calendar: calendar), "yesterday")
        }
        if normalized.contains("today") {
            return (DateRangeHelper.dayRangeContaining(now, calendar: calendar), "today")
        }
        if containsAny(normalized, ["past two weeks", "last two weeks", "past 2 weeks", "last 2 weeks", "last 14 days", "past 14 days", "two weeks ago", "2 weeks ago"]) {
            return (rollingDays(14, endingAt: now, calendar: calendar), "the past 14 days")
        }
        if let days = matchExplicitDayCount(normalized) {
            return (rollingDays(days, endingAt: now, calendar: calendar), "the past \(days) days")
        }
        if containsAny(normalized, ["past week", "last 7 days", "past 7 days"]) {
            return (rollingDays(7, endingAt: now, calendar: calendar), "the past 7 days")
        }
        if normalized.contains("this week") {
            // NOTE: deliberately `weekRangeContaining(now, ...)`, never `currentWeekRange()` —
            // that convenience overload hardcodes `Date.now` internally and would silently ignore
            // the `now` this router was given (making both this router and any test of it
            // non-deterministic). `weekStartsOnSunday: true` matches `currentWeekRange`'s own
            // default; this router has no access to the user's actual weekday preference and a
            // wrong week-boundary choice here only affects THIS one phrase's date filter, never
            // any real budget calculation.
            return (DateRangeHelper.weekRangeContaining(now, weekStartsOnSunday: true, calendar: calendar), "this week")
        }
        if normalized.contains("last week") {
            let currentWeek = DateRangeHelper.weekRangeContaining(now, weekStartsOnSunday: true, calendar: calendar)
            guard let start = calendar.date(byAdding: .day, value: -7, to: currentWeek.start),
                  let end = calendar.date(byAdding: .day, value: -7, to: currentWeek.end) else {
                return (nil, "all time")
            }
            return (DateInterval(start: start, end: end), "last week")
        }
        if normalized.contains("this month") {
            return (DateRangeHelper.monthRangeContaining(now, calendar: calendar), "this month")
        }
        if normalized.contains("last month") {
            return (DateRangeHelper.lastMonthRange(relativeTo: now, calendar: calendar), "last month")
        }
        if normalized.contains("quarter") {
            return (DateRangeHelper.quarterRangeContaining(now, calendar: calendar), "this quarter")
        }
        return (nil, "all time")
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    /// Matches "last N days" / "past N days" for an arbitrary N not already covered by a named
    /// phrase above (e.g. "past 10 days").
    private static func matchExplicitDayCount(_ normalized: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"(?:past|last)\s+(\d+)\s+days"#) else { return nil }
        let range = NSRange(normalized.startIndex..., in: normalized)
        guard let match = regex.firstMatch(in: normalized, range: range),
              let numberRange = Range(match.range(at: 1), in: normalized) else { return nil }
        return Int(normalized[numberRange])
    }

    /// A rolling `days`-calendar-day window ENDING TODAY, INCLUSIVE — e.g. `days: 14` spans today
    /// and the 13 days before it. Half-open `[startOfDay, startOfDayAfterToday)`, always in the
    /// LOCAL calendar/time zone (never UTC, which could shift a local transaction to the wrong
    /// side of the boundary) — matching this phase's own explicit "past two weeks" semantics.
    private static func rollingDays(_ days: Int, endingAt referenceDate: Date, calendar: Calendar) -> DateInterval {
        let startOfToday = calendar.startOfDay(for: referenceDate)
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: startOfToday) ?? startOfToday
        return DateInterval(start: start, end: endExclusive)
    }

    // MARK: - Deterministic response formatting
    //
    // Used both (1) as the immediate answer when this router confidently recognizes the query, and
    // (2) per this feature's own "Part 5 STEP 4" requirement — if the on-device model's FINAL
    // WORDING call fails after a tool already executed successfully, the app formats the verified
    // result itself rather than discarding it behind a generic error.

    static func formatBudgetExclusionsAnswer(
        result: AskSpendSmartToolContext.BudgetExclusionsResult,
        operation: Operation,
        operationWasExplicit: Bool = true,
        dateRangeLabel: String
    ) -> String {
        guard result.isEnabled else {
            return "Budget Exclusions isn't turned on right now, so there are no excluded transactions."
        }
        guard result.totalMatchCount > 0 else {
            return dateRangeLabel == "all time"
                ? "You don't have any Budget Excluded transactions checked."
                : "I found no Budget Excluded transactions in \(dateRangeLabel)."
        }
        let rangePhrase = dateRangeLabel == "all time" ? "" : " in \(dateRangeLabel)"
        let plural = result.totalMatchCount == 1 ? "" : "s"
        switch operation {
        case .count:
            return "You have \(result.totalMatchCount) excluded transaction\(plural)\(rangePhrase)."
        case .amount:
            return "Your excluded transactions\(rangePhrase) total \(formattedAmount(result.totalAmount))."
        case .both:
            // HONEST-MATCH PHASE — `.both` is reached two different ways: a confident "total of X"
            // match (see `matchOperationKeyword`) and a genuine no-keyword-matched-at-all default.
            // `operationWasExplicit` distinguishes them so the second case never presents a default
            // as if it were a considered answer to the actual question asked.
            let uncertaintyPrefix = operationWasExplicit ? "" : "I'm not sure exactly what you're asking for, so here's the count and total: "
            return "\(uncertaintyPrefix)You have \(result.totalMatchCount) excluded transaction\(plural)\(rangePhrase), totaling \(formattedAmount(result.totalAmount))."
        case .list:
            // CAP RAISED FROM 5 TO 50 — matches `AskSpendSmartToolContext.budgetExclusions`'s own
            // `resultLimit: Int = 50` fetch cap exactly (Part 1c); `result.totalMatchCount` above
            // was ALREADY the true, uncapped total even before this change (verified directly
            // against that function's own `matched.count`, computed before any `resultLimit`
            // truncation) — only the itemized listing itself was ever short.
            let names = result.transactions.prefix(50).map { "\($0.description) (\(formattedAmount($0.amount)))" }.joined(separator: ", ")
            let more = result.truncated ? " — showing \(result.transactions.count) of \(result.totalMatchCount)" : ""
            return "You have \(result.totalMatchCount) excluded transaction\(plural)\(rangePhrase): \(names)\(more)."
        case .all:
            // COMPOUND-REQUEST PHASE — count, total, AND the itemized list together, never just
            // one of the three. Same 50-item cap and truncation wording as `.list` above.
            // Laid out as a list: a count line, one line per transaction with its amount, and the
            // final total last, so "list them and then give me a total" reads in that order.
            let lines = result.transactions.prefix(50).map { "\u{2022} \($0.description) \u{2014} \(formattedAmount($0.amount))" }.joined(separator: "\n")
            let more = result.truncated ? "\nShowing \(result.transactions.count) of \(result.totalMatchCount) transactions." : ""
            return "You have \(result.totalMatchCount) excluded transaction\(plural)\(rangePhrase):\n\(lines)\(more)\nFinal total: \(formattedAmount(result.totalAmount))"
        }
    }

    private static func formattedAmount(_ amountString: String) -> String {
        guard let decimal = Decimal(string: amountString, locale: Locale(identifier: "en_US_POSIX")) else { return amountString }
        return CurrencyFormat.string(from: decimal)
    }

    // MARK: - GENERALIZED ORCHESTRATOR PHASE — multi-domain routing

    /// Domain keywords, checked in this ORDER (most specific/unambiguous first) — this is what
    /// keeps e.g. "what does Budget Exclusions do" (App Feature) from being misrouted ahead of
    /// "how many Budget Exclusions do I have" (Budget Exclusions itself). Not an exhaustive NLP
    /// classifier — a narrow, high-precision reliability layer per Phase E's own "high-confidence"
    /// framing; anything genuinely ambiguous is intentionally left for Apple's model to plan.
    static func routeGeneralized(_ text: String, now: Date, calendar: Calendar = .current, followUp: SpendAIFollowUpContext? = nil) -> SpendAIQueryPlan? {
        let normalized = text.lowercased()

        // Follow-ups ("what was the total?", "how much are they?") with no domain wording of
        // their own inherit the PRIOR domain/date range — Phase L's own explicit requirement.
        if let followUp, !mentionsAnyDomain(normalized) {
            let operation = parseOperation(normalized)
            return SpendAIQueryPlan(
                domain: followUp.domain,
                operation: generalizedOperation(from: operation, domain: followUp.domain),
                dateRange: followUp.dateRange,
                dateRangeLabel: followUp.dateRangeLabel
            )
        }

        // "What does X do"/"what is X"/"explain X" for a KNOWN FEATURE NAME is checked before
        // Budget Exclusions' own bare "exclusion"/"excluded" match, so "what does Budget
        // Exclusions do" routes to App Feature Information, not the Budget Exclusions DATA domain.
        if containsAny(normalized, ["what does", "what is", "explain"]), let topic = matchFeatureTopicKeyword(normalized) {
            return SpendAIQueryPlan(domain: .appFeatureInformation, operation: .explanation, featureTopic: topic)
        }

        if matchesBudgetExclusionsDomain(normalized) {
            let matchedOperation = matchOperationKeyword(normalized)
            let (range, label) = parseDateRange(normalized, now: now, calendar: calendar)
            return SpendAIQueryPlan(
                domain: .budgetExclusions,
                operation: generalizedOperation(from: matchedOperation ?? .both, domain: .budgetExclusions),
                dateRange: range,
                dateRangeLabel: label,
                operationWasExplicit: matchedOperation != nil
            )
        }

        if containsAny(normalized, ["what if", "hypothetical"]) || (normalized.contains("if i") && (normalized.contains("save") || normalized.contains("saved"))) {
            guard let amount = extractDollarAmount(normalized) else { return nil }
            return SpendAIQueryPlan(domain: .hypotheticalScenario, operation: .hypothetical, hypotheticalAmount: amount)
        }

        if normalized.contains("calculate transactions") || normalized.contains("the calculator") || containsAny(normalized, ["signed versus absolute", "signed vs absolute", "multi-account selection", "multi account selection"]) {
            return SpendAIQueryPlan(domain: .calculateTransactions, operation: .explanation)
        }

        if normalized.contains("auto calculate") || normalized.contains("autocalculate") {
            return SpendAIQueryPlan(domain: .autoCalculate, operation: .status)
        }

        if containsAny(normalized, ["register", "manual account", "manual checking", "check number"]) {
            return SpendAIQueryPlan(domain: .manualAccounts, operation: .status, accountFilter: extractAccountName(normalized))
        }

        if normalized.contains("balance") || containsAny(normalized, ["connected account", "last updated", "connection status"]) {
            return SpendAIQueryPlan(domain: .connectedAccounts, operation: .status, accountFilter: extractAccountName(normalized))
        }

        // "Monthly Plan"-flavored phrasing is checked BEFORE the generic Bills keyword, so "how
        // much can I spend this month after bills and savings" (a Monthly Plan question that
        // happens to mention "bills") isn't misrouted to the Bills domain.
        if containsAny(normalized, ["monthly plan", "flexible spending", "after bills", "monthly remaining", "what can i spend this month", "left to spend"]) {
            return SpendAIQueryPlan(domain: .monthlyPlan, operation: .summary)
        }

        if containsAny(normalized, ["bill", "pay bills"]) {
            return SpendAIQueryPlan(domain: .bills, operation: .status)
        }

        if containsAny(normalized, ["saving", "save more", "remaining to save", "need to save", "to save"]) {
            return SpendAIQueryPlan(domain: .savings, operation: .status)
        }

        if normalized.contains("quick stat") || containsAny(normalized, ["planned versus actual", "planned vs actual", "planned and actual", "spending summary"]) {
            return SpendAIQueryPlan(domain: .quickStats, operation: .summary)
        }

        if normalized.contains("spent on"), let category = extractAfter(normalized, phrase: "spent on") {
            let (range, label) = parseDateRange(normalized, now: now, calendar: calendar)
            return SpendAIQueryPlan(domain: .categories, operation: .summary, dateRange: range, dateRangeLabel: label, categoryFilter: category)
        }
        if normalized.contains("categor") {
            let (range, label) = parseDateRange(normalized, now: now, calendar: calendar)
            return SpendAIQueryPlan(domain: .categories, operation: .summary, dateRange: range, dateRangeLabel: label)
        }

        if containsAny(normalized, ["this week", "weekly budget", "spent this week", "remaining this week", "over budget"]) {
            return SpendAIQueryPlan(domain: .weekly, operation: .status)
        }

        if normalized.contains("spent at"), let merchant = extractAfter(normalized, phrase: "spent at") {
            let (range, label) = parseDateRange(normalized, now: now, calendar: calendar)
            return SpendAIQueryPlan(domain: .transactions, operation: .search, dateRange: range, dateRangeLabel: label, merchantFilter: merchant)
        }

        let explicitDateRange = parseExplicitDate(normalized, now: now, calendar: calendar)
        let exactAmount = extractDollarAmount(normalized)
        if containsAny(normalized, ["transaction", "purchase", "charge", "merchant", "find my"]) || explicitDateRange != nil || exactAmount != nil {
            let (fallbackRange, fallbackLabel) = parseDateRange(normalized, now: now, calendar: calendar)
            let range = explicitDateRange ?? fallbackRange
            let label = explicitDateRange != nil ? "that date" : fallbackLabel
            return SpendAIQueryPlan(domain: .transactions, operation: .search, dateRange: range, dateRangeLabel: label, exactAmount: exactAmount)
        }

        return nil
    }

    // MARK: - Several asks in one question

    /// A question that asks for more than one thing ("how many excluded transactions do I have, and
    /// what are my bills?") is split into its parts and each part routed on its own. Returns `nil`
    /// unless there are at least two parts AND every part routes to a plan by itself, so a question
    /// that only looks like two asks (one clause with no subject of its own) is left to the ordinary
    /// single-plan path rather than guessed at.
    static func routeMultiple(_ text: String, now: Date, calendar: Calendar = .current) -> [SpendAIQueryPlan]? {
        let parts = splitIntoAsks(text)
        guard parts.count >= 2 else { return nil }
        var plans: [SpendAIQueryPlan] = []
        for part in parts {
            guard let plan = routeGeneralized(part, now: now, calendar: calendar, followUp: nil),
                  SpendAIQueryPlanValidator.validate(plan)
            else { return nil }
            plans.append(plan)
        }
        return plans
    }

    static func splitIntoAsks(_ text: String) -> [String] {
        var working = text
        for separator in ["?", ";", " and then ", " then ", " and also ", " also ", " as well as ", ", and ", " and "] {
            working = working.replacingOccurrences(of: separator, with: "|", options: .caseInsensitive)
        }
        return working
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func mentionsAnyDomain(_ normalized: String) -> Bool {
        matchesBudgetExclusionsDomain(normalized)
            || containsAny(normalized, ["bill", "saving", "week", "month", "balance", "register", "category", "categories", "transaction", "purchase", "charge", "merchant", "calculate transactions", "auto calculate", "quick stat", "what if", "hypothetical"])
    }

    /// Maps the Budget-Exclusions-era `Operation` enum onto the generalized `SpendAIOperation` —
    /// kept as a small translation rather than unifying the two enums, so the original 55 tests
    /// exercising `Operation`/`routeBudgetExclusions` never need to change.
    private static func generalizedOperation(from operation: Operation, domain: SpendAIDomain) -> SpendAIOperation {
        switch operation {
        case .count: return .count
        case .amount: return .total
        case .both: return .both
        case .list: return .list
        case .all: return .all
        }
    }

    private static func matchFeatureTopicKeyword(_ normalized: String) -> String? {
        let keywords = ["budget exclusion", "auto calculate", "monthly plan", "quick stat", "manual account", "manual register", "account register", "activity", "weekly budget", "saving", "bill", "pay bills"]
        return keywords.first { normalized.contains($0) }
    }

    private static func extractAccountName(_ normalized: String) -> String? {
        let knownNames = ["american express", "amex", "chase", "wells fargo", "checking", "savings"]
        return knownNames.first { normalized.contains($0) }
    }

    private static func extractAfter(_ normalized: String, phrase: String) -> String? {
        guard let range = normalized.range(of: phrase) else { return nil }
        let after = normalized[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let stopWords = [" this", " last", " during", " in", " on", " since", " for", "?", "."]
        var word = after
        for stopWord in stopWords {
            if let stopRange = word.range(of: stopWord) {
                word = String(word[..<stopRange.lowerBound])
            }
        }
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Extracts the first dollar figure mentioned, e.g. "$34.75" or "1,000" → `1000`. Used for
    /// both an exact-transaction-amount filter and a hypothetical-scenario amount.
    private static func extractDollarAmount(_ normalized: String) -> Decimal? {
        guard let regex = try? NSRegularExpression(pattern: #"\$?([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?)"#) else { return nil }
        let range = NSRange(normalized.startIndex..., in: normalized)
        guard let match = regex.firstMatch(in: normalized, range: range),
              let numberRange = Range(match.range(at: 1), in: normalized) else { return nil }
        let cleaned = normalized[numberRange].replacingOccurrences(of: ",", with: "")
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Explicit "August 23"-style single-day dates (Phase K's own required "explicit month/day"
    /// support). Resolves against `now`'s year — this router has no year context beyond that.
    private static func parseExplicitDate(_ normalized: String, now: Date, calendar: Calendar) -> DateInterval? {
        let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        for (index, month) in monthNames.enumerated() {
            guard let monthRange = normalized.range(of: month) else { continue }
            let afterMonth = String(normalized[monthRange.upperBound...])
            guard let dayRegex = try? NSRegularExpression(pattern: #"\d{1,2}"#),
                  let dayMatch = dayRegex.firstMatch(in: afterMonth, range: NSRange(afterMonth.startIndex..., in: afterMonth)),
                  let dayRange = Range(dayMatch.range, in: afterMonth),
                  let day = Int(afterMonth[dayRange]) else { continue }
            var components = calendar.dateComponents([.year], from: now)
            components.month = index + 1
            components.day = day
            guard let date = calendar.date(from: components) else { continue }
            return DateRangeHelper.dayRangeContaining(date, calendar: calendar)
        }
        return nil
    }
}
