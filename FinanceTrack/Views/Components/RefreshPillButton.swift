import SwiftUI

/// Small, compact capsule button for the Dashboard's per-connected-account "Refresh" action —
/// deliberately NOT full-width and NOT `PremiumActionButton` (that component is full-width, the
/// wrong shape for a control that must sit directly under one account's balance amount). Modeled
/// on `FilterChip`'s `Capsule()` shape for visual consistency with the rest of the app's compact
/// controls, but with its own fixed green fill (`Theme.statusGood`) and white text, per the
/// product's exact spec — not derived from `FilterChip`'s selected/unselected styling, which
/// doesn't apply here.
///
/// Three states, all visually simple (no large explanatory copy):
/// - Idle: green pill, white "Refresh" text, tappable.
/// - Refreshing: same pill, dimmed, disabled, brief `ProgressView` in place of the label.
/// - Rate-limited: dimmed gray pill, disabled, "Daily limit reached" text — the server is always
///   the authority on this; this state only reflects what the app has already learned from a real
///   429 response (or a mirrored `remaining` count), never a client-side guess about a fresh day.
struct RefreshPillButton: View {
    var isRefreshing: Bool
    var isRateLimited: Bool
    var action: () -> Void

    private var isDisabled: Bool { isRefreshing || isRateLimited }

    var body: some View {
        Button(action: action) {
            Group {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else if isRateLimited {
                    Text("Daily limit reached")
                } else {
                    Text("Refresh")
                }
            }
            .font(Theme.captionFont)
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(
                Capsule().fill(isRateLimited ? Theme.textSecondary.opacity(0.4) : Theme.statusGood)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isRefreshing ? 0.7 : 1)
    }
}

#Preview {
    VStack(spacing: 12) {
        RefreshPillButton(isRefreshing: false, isRateLimited: false) {}
        RefreshPillButton(isRefreshing: true, isRateLimited: false) {}
        RefreshPillButton(isRefreshing: false, isRateLimited: true) {}
    }
    .padding()
    .background(Theme.backgroundGradient)
}
