import SwiftUI

/// A small "i" button for a Dashboard card's top-right corner — taps open a plain-English
/// explanation sheet (title + body text, written for someone with no technical background,
/// real-life examples only, never a code/field name). Reusable across any card; each call site
/// supplies its own title/explanation copy.
struct InfoButton: View {
    let title: String
    let explanation: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(title)")
        .sheet(isPresented: $isPresented) {
            InfoExplanationSheet(title: title, explanation: explanation)
        }
    }
}

private struct InfoExplanationSheet: View {
    let title: String
    let explanation: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(explanation)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}

#Preview {
    InfoButton(title: "About This Week", explanation: "This shows how much you've spent so far this week compared to your weekly limit.")
        .padding()
        .background(Theme.backgroundGradient)
}
