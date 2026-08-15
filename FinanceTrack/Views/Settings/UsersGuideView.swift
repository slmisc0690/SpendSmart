import SwiftUI

/// A complete, start-to-finish walkthrough of the app for someone brand new to it — no financial
/// background assumed. Reachable from Settings ▸ About ▸ User's Guide. Purely informational, like
/// `SecurityNotesView`, which this mirrors the structure of.
struct UsersGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    VStack(spacing: Theme.Spacing.sm) {
                        Image("SpendSmartLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        Text("User's Guide")
                            .font(Theme.titleFont)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Everything you need to get started, start to finish")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Spacing.md)

                    guideCard(
                        icon: "flag.checkered",
                        title: "1. Where to Start",
                        body: """
                            SpendSmart tracks your money two ways at once: an account balance (how \
                            much you have) and a running list of transactions (everything you spent \
                            or received). You can use either or both:

                            • Connect a real bank/card account so it syncs automatically, or
                            • Add a Manual Account and enter things yourself, or
                            • Do both — some accounts connected, some tracked by hand.

                            A simple first-day plan: open the Dashboard tab, add at least one \
                            account (Manual or Connected), then decide whether you want to fill in \
                            a Monthly Plan (Settings ▸ Planning) or just set a simple weekly \
                            spending amount. Either is a fine way to begin — you can always add more \
                            detail later.
                            """
                    )

                    guideCard(
                        icon: "building.columns.fill",
                        title: "2. Connected Accounts — how they work",
                        body: """
                            A Connected Account is a real bank or credit card account you link \
                            through Plaid, a secure service banks use to safely share your \
                            transaction data with apps like this one. You link it from Settings ▸ \
                            Data ▸ Connected Accounts.

                            Your bank username and password are typed only into Plaid's own secure \
                            screen — never into SpendSmart itself, and SpendSmart never sees or \
                            stores them.

                            Once connected, the account's balance and transactions sync in \
                            automatically. Whether those transactions actually count toward your \
                            Spent This Week/Month is a separate choice: go to Settings ▸ Auto \
                            Calculate and turn ON any connected account whose transaction names \
                            you're comfortable with. Left OFF, a connected account's activity still \
                            shows up in your Activity tab for your records, but never adds to your \
                            spending totals.

                            You can refresh a connected account's balance and latest transactions \
                            from its own screen — there's a small daily limit on how often, to keep \
                            things running smoothly.

                            Connecting a bank is entirely optional. Nothing about the app requires it.
                            """
                    )

                    guideCard(
                        icon: "creditcard.fill",
                        title: "3. Manual Accounts — how they work",
                        body: """
                            A Manual Account is one you track entirely by hand — no bank connection \
                            needed. Add one from the Manual Accounts tab. Good examples: a checking \
                            account at a bank you don't want to connect, cash, or a loan you're \
                            paying down.

                            Once created, you add entries to it yourself: an Expense (money out), a \
                            Deposit (money in), a Refund, or a Transfer to/from another account. Each \
                            entry updates that account's balance immediately, so the balance shown is \
                            always the sum of everything you've entered.

                            When you add an expense, you can tag it as a Bill if it's paying \
                            something already listed in your Monthly Plan — this keeps it from being \
                            counted twice (once as "a bill you're expected to pay" and again as "a \
                            purchase you made"). If it's not a bill, it counts as normal spending. \
                            "Pay Bills" is a fast, one-tap way to pay several bills from your Monthly \
                            Plan at once from a Manual Account's register.

                            Manual Account data lives on your device and can also back up to the \
                            cloud tied to your sign-in, so it's recoverable if you get a new phone.
                            """
                    )

                    guideCard(
                        icon: "chart.pie.fill",
                        title: "4. Using a Monthly Plan",
                        body: """
                            A Monthly Plan (Settings ▸ Planning ▸ Monthly Plan) is where you enter \
                            your income, your regular bills, how much you want to save each month, \
                            and any extra buffer. From those, the app works out how much is \
                            genuinely left over for everyday spending, splits that into a weekly \
                            amount, and uses it as your Weekly Spending Limit everywhere in the app.

                            With a Monthly Plan filled in, you get the full picture: Projected \
                            Savings (are you on track to hit your savings goal?), Monthly Remaining \
                            (how much of this month's money is left, right now), and a Bill Payment \
                            Variance breakdown (did you pay more or less than planned for a \
                            particular bill?).

                            This is the recommended way to use the app if you want a real, complete \
                            budget — it ties your bills, savings, and spending together into one \
                            consistent picture.
                            """
                    )

                    guideCard(
                        icon: "slider.horizontal.3",
                        title: "5. Not Using a Monthly Plan? Here's How Spending Still Works",
                        body: """
                            You don't have to fill in a Monthly Plan at all. Your Spent This Week \
                            and Spent This Month totals are always based on your real transactions — \
                            Manual Account entries you've made, plus any Connected Accounts you've \
                            turned on under Auto Calculate — regardless of whether Monthly Plan has \
                            anything in it.

                            What a Monthly Plan actually supplies is the TARGET those totals get \
                            compared against. With nothing in Monthly Plan, that target defaults to \
                            $0, which would make every dollar you spend look "over budget." To avoid \
                            that without filling in a full Monthly Plan, go to Settings ▸ Planning \
                            and set a Custom Planned Weekly Spending amount — just a plain dollar \
                            figure you choose. That becomes your Weekly Spending Limit immediately, \
                            with no income or bills required anywhere.

                            In short: tracking what you spend never requires a Monthly Plan. A \
                            Monthly Plan is only needed if you also want the app to tell you whether \
                            that spending is on pace with your income, bills, and savings goals.
                            """
                    )

                    guideCard(
                        icon: "square.grid.2x2.fill",
                        title: "6. The Dashboard, Weekly Budget, and Activity",
                        body: """
                            The Dashboard is your home screen — This Week's spending at a glance, \
                            Quick Stats, Monthly Outlook, a week-by-week breakdown, Budget \
                            Exclusions, and your Recent Activity. Every card has its own "i" button \
                            in the corner if you want a deeper explanation of exactly what it shows.

                            Weekly Budget is a closer look at just the current week: your spending \
                            ring, a category breakdown (which kinds of purchases made up your \
                            spending), and a day-by-day list.

                            Activity is your full transaction history across every account, with \
                            filters for date range and tabs to switch between your own entries and \
                            any connected accounts.
                            """
                    )

                    guideCard(
                        icon: "eye.slash.fill",
                        title: "7. Keeping Things Private",
                        body: """
                            Under Settings ▸ Security & Privacy, you can require Face ID/Touch ID to \
                            open the app at all, and turn on Privacy Mode to hide every dollar amount \
                            behind dots until you tap to reveal them. Both are entirely optional and \
                            can be turned on or off any time.
                            """
                    )

                    guideCard(
                        icon: "person.2.fill",
                        title: "8. Sharing With a Household Member",
                        body: """
                            If you want a spouse or family member to see your finances, invite them \
                            from Settings ▸ Account. Once they accept, you choose exactly which \
                            accounts and how much of your Monthly Plan they can see — nothing is \
                            shared automatically just because they accepted. If someone invites YOU \
                            instead, you can optionally share your own accounts back with them from \
                            that same section.
                            """
                    )

                    guideCard(
                        icon: "questionmark.bubble.fill",
                        title: "9. Still Have a Question?",
                        body: """
                            Try Insights (Settings ▸ Planning ▸ Insights, also called "Ask \
                            SpendSmart") — type a plain-English question about your own bills, \
                            income, or spending, and get an answer computed entirely on your device \
                            from your real numbers. Nothing you ask is ever sent anywhere.
                            """
                    )
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("User's Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func guideCard(icon: String, title: String, body: String) -> some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.accent.opacity(0.16)))
                    Text(title)
                        .font(Theme.headlineFont)
                        .foregroundStyle(Theme.textPrimary)
                }
                Text(body)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

#Preview {
    UsersGuideView()
}
