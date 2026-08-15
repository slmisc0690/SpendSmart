import SwiftUI
import SwiftData

/// "Restore Missing Transactions from CSV" preview — presented after a CSV file is picked and
/// parsed. Purely a review/confirm step: nothing is written to the store until the user taps
/// "Restore Missing Transactions" (Cancel/dismiss writes nothing at all). Always makes explicit
/// that this is a MERGE, never a replace — see `TransactionCSVImportService`'s own header for the
/// full non-destructive design this view is presenting.
struct CSVImportPreviewView: View {
    let preview: TransactionCSVImportService.PreviewResult
    let accounts: [Account]
    let categories: [Category]
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var isRestoring = false
    @State private var restoredCount: Int?
    @State private var errorMessage: String?
    @State private var isPresentingError = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    if let restoredCount {
                        successCard(restoredCount: restoredCount)
                    } else {
                        summaryCard
                        if !preview.restorable.isEmpty {
                            missingListCard
                        }
                        if !preview.skipped.isEmpty {
                            skippedCard
                        }
                        actionButtons
                    }
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Restore from CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(restoredCount == nil ? "Cancel" : "Done") {
                        dismiss()
                        onFinished()
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
            }
            .alert("Couldn't Restore", isPresented: $isPresentingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "This restore couldn't be completed, so nothing in this batch was changed. Please try again.")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Summary

    private var summaryCard: some View {
        CardBackground {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("This restores ONLY transactions missing from your current data — nothing on this device is replaced, overwritten, or deleted.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)

                Divider().overlay(Theme.cardStroke)

                summaryRow(title: "CSV Transactions", value: "\(preview.totalCSVRows)")
                summaryRow(title: "Already Present", value: "\(preview.alreadyPresentCount)")
                summaryRow(title: "Missing", value: "\(preview.restorable.count)", emphasized: true)
                if !preview.skipped.isEmpty {
                    summaryRow(title: "Skipped", value: "\(preview.skipped.count)")
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    @ViewBuilder
    private func summaryRow(title: String, value: String, emphasized: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(emphasized ? Theme.headlineFont : Theme.bodyFont)
                .foregroundStyle(emphasized ? Theme.accent : Theme.textPrimary)
        }
    }

    // MARK: - Missing list

    private var missingListCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Transactions to Restore")
            CardBackground {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(Array(preview.restorable.enumerated()), id: \.offset) { index, row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.description.isEmpty ? "(No description)" : row.description)
                                    .font(Theme.bodyFont)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Text("\(row.accountName) \u{00B7} \(row.date.formatted(date: .abbreviated, time: .omitted))")
                                    .font(Theme.captionFont)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            Text(row.type.label)
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        if index < preview.restorable.count - 1 {
                            Divider().overlay(Theme.cardStroke)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Skipped

    private var skippedCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Skipped Rows")
            CardBackground {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(skippedSummaries.enumerated()), id: \.offset) { _, summary in
                        Text(summary)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private var skippedSummaries: [String] {
        var counts: [String: Int] = [:]
        for row in preview.skipped {
            counts[label(for: row.reason), default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { "\($0.value) \u{00D7} \($0.key)" }
    }

    private func label(for reason: TransactionCSVImportService.SkipReason) -> String {
        switch reason {
        case .malformedRow: return "Malformed row"
        case .unsupportedType: return "Unsupported transaction type"
        case .accountNotFound: return "Account not found"
        case .ambiguousAccount: return "Ambiguous account name"
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: Theme.Spacing.sm) {
            PremiumActionButton(title: "Restore Missing Transactions", systemIconName: "arrow.down.doc") {
                restore()
            }
            .disabled(preview.restorable.isEmpty || isRestoring)
            .padding(.horizontal, Theme.Spacing.lg)

            Button {
                dismiss()
                onFinished()
            } label: {
                Text("Cancel")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, Theme.Spacing.xs)
        }
    }

    private func successCard(restoredCount: Int) -> some View {
        CardBackground {
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(Theme.statusGood)
                Text(restoredCount == 1 ? "Restored 1 transaction." : "Restored \(restoredCount) transactions.")
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private func restore() {
        guard !isRestoring, !preview.restorable.isEmpty else { return }
        isRestoring = true
        do {
            let count = try TransactionCSVImportService.restore(
                restorable: preview.restorable,
                accounts: accounts,
                categories: categories,
                context: modelContext
            )
            restoredCount = count
        } catch {
            errorMessage = "These transactions couldn't be saved, so nothing in this batch was changed. Please try again."
            isPresentingError = true
        }
        isRestoring = false
    }
}
