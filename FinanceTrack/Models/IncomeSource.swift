import Foundation
import SwiftData

/// A recurring (or one-time) source of income used to plan a month — e.g. a paycheck or VA
/// benefits. Purely for forecasting: this never creates `FinanceTransaction` records on its own.
///
/// INCOME SCHEDULING PHASE — explicit deposit schedule, replacing reliance on the `timing` label
/// for recurring cash-flow timing (see `PlanTiming`'s own header: it is "purely descriptive," never
/// date math). Every new field below is OPTIONAL or has a `false` default, so every existing stored
/// record — created before this phase — remains fully readable via SwiftData's standard lightweight
/// migration (no existing property was removed, renamed, or retyped; nothing here can fail to
/// decode an old row). Which fields matter depends on `frequency`:
/// - `.weekly`/`.biweekly`: `nextPayDate` alone is the anchor (unchanged — already sufffcient,
///   already consumed by `ScenarioDateRangeCalculator`'s existing day-count stepping).
/// - `.monthly`: `dayOfMonth` (numeric) OR `monthlyDepositDayIsLastDay` (Last Day) — see
///   `monthlyDepositDay`.
/// - `.twiceMonthly`: BOTH `twiceMonthlyFirstDay(Number/IsLastDay)` AND
///   `twiceMonthlySecondDay(Number/IsLastDay)` — see `isTwiceMonthlyScheduleComplete`. A record
///   with only `nextPayDate` set (the pre-this-phase representation) and neither new pair
///   populated is INCOMPLETE — its second deposit day was never actually known, so nothing here
///   ever fabricates one; the record is flagged incomplete and excluded from timing-based cash
///   flow until a Primary user completes it in Add/Edit Income (see
///   `ScenarioCashFlowCalculator`/`AddEditIncomeSourceView`).
/// - `.yearly`: `nextPayDate` alone (its month+day) — unchanged; `ScenarioDateRangeCalculator`'s
///   per-year resolution (this phase) handles Feb 29 clamping in non-leap years.
/// - `.oneTime`: unchanged — no longer offered when creating/editing recurring income (this
///   phase), but existing `.oneTime` records are read and calculated exactly as before; see
///   `AddEditIncomeSourceView`'s own header for the full legacy-record policy.
@Model
final class IncomeSource {
    var id: UUID
    var name: String
    var amount: Decimal
    var frequency: PlanFrequency
    var timing: PlanTiming
    /// Day of the month this typically lands on (1...31) — for `.monthly` frequency, this is the
    /// deposit day itself (unless `monthlyDepositDayIsLastDay` is set); for other frequencies it
    /// remains purely descriptive, exactly as before this phase.
    var dayOfMonth: Int?
    /// For `.oneTime` income, the specific date it's expected. For `.weekly`/`.biweekly`/`.yearly`,
    /// the deposit anchor date. For `.monthly`/`.twiceMonthly`, an optional legacy reference only —
    /// the new day-based fields below are authoritative for those two frequencies once complete.
    var nextPayDate: Date?
    var isActive: Bool
    var note: String
    var createdAt: Date
    var updatedAt: Date

    /// INCOME SCHEDULING PHASE (new, additive, default `false`) — when `true` for `.monthly`
    /// frequency, the deposit lands on the target month's actual Last Day rather than
    /// `dayOfMonth`. See `monthlyDepositDay`.
    var monthlyDepositDayIsLastDay: Bool = false

    /// INCOME SCHEDULING PHASE (new, additive) — Twice-Monthly's first configured deposit day.
    /// `nil` (with `twiceMonthlyFirstDayIsLastDay == false`) means "not yet configured" — never a
    /// silently-fabricated default. See `twiceMonthlyFirstDeposit`/`isTwiceMonthlyScheduleComplete`.
    var twiceMonthlyFirstDayNumber: Int?
    var twiceMonthlyFirstDayIsLastDay: Bool = false
    /// INCOME SCHEDULING PHASE (new, additive) — Twice-Monthly's second configured deposit day.
    /// Same "nil means not yet configured" rule as the first day.
    var twiceMonthlySecondDayNumber: Int?
    var twiceMonthlySecondDayIsLastDay: Bool = false

    /// The Supabase auth user UUID that locally owns this row on this device. `nil` for any row
    /// created before per-user local data isolation existed (or not yet backfilled) — a `nil`
    /// value must never be treated as "belongs to the current user." Optional in this phase by
    /// design (see `UserDataStoreManager`/`LegacyDataMigrator`); not yet enforced or required.
    var ownerUserID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        amount: Decimal,
        frequency: PlanFrequency = .monthly,
        timing: PlanTiming = .beginningMonth,
        dayOfMonth: Int? = nil,
        nextPayDate: Date? = nil,
        monthlyDepositDayIsLastDay: Bool = false,
        twiceMonthlyFirstDayNumber: Int? = nil,
        twiceMonthlyFirstDayIsLastDay: Bool = false,
        twiceMonthlySecondDayNumber: Int? = nil,
        twiceMonthlySecondDayIsLastDay: Bool = false,
        isActive: Bool = true,
        note: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        ownerUserID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.frequency = frequency
        self.timing = timing
        self.dayOfMonth = dayOfMonth
        self.nextPayDate = nextPayDate
        self.monthlyDepositDayIsLastDay = monthlyDepositDayIsLastDay
        self.twiceMonthlyFirstDayNumber = twiceMonthlyFirstDayNumber
        self.twiceMonthlyFirstDayIsLastDay = twiceMonthlyFirstDayIsLastDay
        self.twiceMonthlySecondDayNumber = twiceMonthlySecondDayNumber
        self.twiceMonthlySecondDayIsLastDay = twiceMonthlySecondDayIsLastDay
        self.isActive = isActive
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.ownerUserID = ownerUserID
    }

    /// The Monthly deposit day, typed — `nil` if neither a numeric day nor Last Day has been set
    /// (an old/blank record). Only meaningful for `.monthly` frequency.
    var monthlyDepositDay: MonthlyDepositDay? {
        .from(dayNumber: dayOfMonth, isLastDay: monthlyDepositDayIsLastDay)
    }

    /// Twice-Monthly's first deposit day, typed — `nil` if not yet configured.
    var twiceMonthlyFirstDeposit: MonthlyDepositDay? {
        .from(dayNumber: twiceMonthlyFirstDayNumber, isLastDay: twiceMonthlyFirstDayIsLastDay)
    }

    /// Twice-Monthly's second deposit day, typed — `nil` if not yet configured.
    var twiceMonthlySecondDeposit: MonthlyDepositDay? {
        .from(dayNumber: twiceMonthlySecondDayNumber, isLastDay: twiceMonthlySecondDayIsLastDay)
    }

    /// `true` for any frequency other than `.twiceMonthly` (nothing to complete). For
    /// `.twiceMonthly`, `true` only once BOTH deposit days are explicitly configured — a legacy
    /// record with just an old `nextPayDate` and neither new pair set is `false` (incomplete),
    /// exactly the "do not fabricate an unknown second date" rule this phase requires.
    var isTwiceMonthlyScheduleComplete: Bool {
        guard frequency == .twiceMonthly else { return true }
        return twiceMonthlyFirstDeposit != nil && twiceMonthlySecondDeposit != nil
    }

    /// SCHEDULE UX PHASE — Part 7: whether this income has enough deposit-schedule information for
    /// timing-based Scenario cash flow to include it. Mirrors
    /// `ScenarioDateRangeCalculator.isItemSchedulable(_:)`'s per-frequency rule exactly, kept here
    /// too so Monthly Plan can flag an incomplete schedule (and offer "Complete Deposit Schedule")
    /// directly against the real `IncomeSource`, without first converting to a `ScenarioLineItem`.
    var hasCompleteDepositSchedule: Bool {
        switch frequency {
        case .twiceMonthly:
            return isTwiceMonthlyScheduleComplete
        case .monthly:
            return monthlyDepositDay != nil || nextPayDate != nil
        default:
            return nextPayDate != nil
        }
    }
}
