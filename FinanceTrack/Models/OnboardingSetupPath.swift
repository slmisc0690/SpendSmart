import Foundation

/// The 5 choices on the first-run "How do you want to get started?" screen. Persisted as
/// `OnboardingSettings.selectedPathRawValue` (reference only — nothing branches on it after
/// onboarding completes), and drives which instructional content `OnboardingInstructionsView`
/// shows. `.none` skips instructions entirely and goes straight to a fresh, empty Dashboard.
enum OnboardingSetupPath: String, CaseIterable, Identifiable {
    case connectedOnly
    case connectedAndMonthlyPlan
    case monthlyPlanAndManual
    case monthlyPlanOnly
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connectedOnly: return "Just a Connected Account"
        case .connectedAndMonthlyPlan: return "Connected Account + Monthly Plan"
        case .monthlyPlanAndManual: return "Monthly Plan + Manual Account"
        case .monthlyPlanOnly: return "Just a Monthly Plan"
        case .none: return "None of these"
        }
    }

    var subtitle: String {
        switch self {
        case .connectedOnly: return "Link a bank or card and see its activity — no budget"
        case .connectedAndMonthlyPlan: return "Link a bank or card and track it against a real budget"
        case .monthlyPlanAndManual: return "Budget with entries you log by hand, no bank linking"
        case .monthlyPlanOnly: return "A budget you track by hand, with no account at all"
        case .none: return "Skip setup — start with a completely empty app"
        }
    }

    var systemImageName: String {
        switch self {
        case .connectedOnly: return "building.columns"
        case .connectedAndMonthlyPlan: return "building.columns.fill"
        case .monthlyPlanAndManual: return "creditcard"
        case .monthlyPlanOnly: return "calendar.badge.clock"
        case .none: return "xmark.circle"
        }
    }

    /// Shown at the top of `OnboardingInstructionsView`, in each step's own numbered form.
    var setupSteps: [String] {
        switch self {
        case .connectedOnly:
            return [
                "Go to Settings → Connected Accounts and link your bank or card.",
                "Once it's linked, its transactions show up under its own tab on the Activity screen automatically.",
            ]
        case .connectedAndMonthlyPlan:
            return [
                "Go to Settings → Connected Accounts and link your bank or card.",
                "Go to Settings → Monthly Plan and add your income, recurring bills, and a savings goal.",
                "Go to Settings → \"Auto Calculate Weekly/Monthly Based on Transactions for:\" and turn on the account you just linked — this is the one step people miss. Without it, that account's spending shows up on Activity but never counts toward your budget.",
            ]
        case .monthlyPlanAndManual:
            return [
                "Go to Settings → Monthly Plan and add your income, recurring bills, and a savings goal.",
                "Go to the Manual Accounts tab and add an account (checking, savings, credit card — whatever you want to track).",
                "Log each expense by hand from that account, using the + button on the Dashboard or from the account itself.",
            ]
        case .monthlyPlanOnly:
            return [
                "Go to Settings → Monthly Plan and add your income, recurring bills, and a savings goal.",
                "Log expenses with the + button on the Dashboard — general entries not tied to any specific account.",
            ]
        case .none:
            return []
        }
    }

    /// Shown below the steps — what to actually expect on Dashboard/Activity/Weekly once set up
    /// this way, written to head off the exact "why is this showing $0" confusion each shape of
    /// setup produces.
    var whatToExpect: String {
        switch self {
        case .connectedOnly:
            return """
                Activity will show every transaction from your linked account, grouped by day, \
                under its own tab.

                Dashboard and Weekly Budget will keep showing $0 spent and a $0 limit — that's \
                expected. Without a Monthly Plan, there's no budget to compare against, so those \
                screens just aren't the ones to check. Activity is where you'll actually see your \
                transactions.
                """
        case .connectedAndMonthlyPlan:
            return """
                Once Auto Calculate is turned on for your linked account, its transactions count \
                toward your Weekly and Monthly spending automatically — no manual entry needed. \
                Dashboard's Quick Stats, Monthly Outlook, and Week-by-Week will all reflect real \
                numbers, and Weekly Budget's daily breakdown will show that account's activity. \
                Activity still shows every transaction individually if you want the full detail.
                """
        case .monthlyPlanAndManual:
            return """
                Every expense you log against your Manual Account counts toward your Weekly and \
                Monthly spending the moment you save it. Dashboard, Weekly Budget, and Activity \
                will all reflect it immediately — nothing to turn on, since Manual Account entries \
                are never optional the way Auto Calculate is for a Connected Account.
                """
        case .monthlyPlanOnly:
            return """
                Your Weekly and Monthly limits will show real numbers right away, based on your \
                Monthly Plan. Spent will stay at $0 until you log something — there's no account \
                to auto-track, so every expense has to be entered by hand from the Dashboard's + \
                button. That's the tradeoff for not linking or creating any account at all.
                """
        case .none:
            return ""
        }
    }
}
