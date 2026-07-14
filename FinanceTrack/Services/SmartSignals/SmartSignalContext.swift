import Foundation

/// Everything a `SmartSignalEngine` is allowed to read, built once per generation pass by the
/// caller (a future, not-yet-built UI/coordinator layer) and handed to every engine unchanged.
///
/// Deliberately NOT `Sendable`: `transactions`/`accounts`/`categories`/`incomeSources`/
/// `recurringExpenses` are SwiftData `@Model` reference types, which are not safely `Sendable`.
/// The Smart Signals foundation is local and synchronous — there is no genuine concurrency need
/// here, so this is left correctly un-annotated rather than silenced with `@unchecked Sendable`.
///
/// This type holds plain arrays and values only:
/// - no `ModelContext` (an engine must never fetch/query SwiftData itself — the caller fetches
///   once and passes the results in)
/// - no calculated totals (engines call `BudgetCalculator`/`MonthlyPlanCalculator`/
///   `CreditUtilizationCalculator`/`DateRangeHelper`/`AccountBalanceManager` themselves, using
///   this raw data — this type never pre-computes anything on their behalf)
/// - no Plaid or Supabase service references
struct SmartSignalContext {
    let transactions: [FinanceTransaction]
    let accounts: [Account]
    let categories: [Category]
    let incomeSources: [IncomeSource]
    let recurringExpenses: [RecurringExpense]
    let budgetSettings: BudgetSettings?
    let monthlyPlanSettings: MonthlyPlanSettings?
    /// The "current" moment every engine must treat as authoritative — always injected by the
    /// caller, never read from `Date()` inside a `SmartSignalEngine`, so every engine's output is
    /// fully deterministic and reproducible in tests.
    let now: Date
}
