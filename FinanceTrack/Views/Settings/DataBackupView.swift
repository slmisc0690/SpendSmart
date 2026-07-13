import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Export/import/auto-backup screen. Everything here is local-only: backups are plain JSON files
/// written to this device (Documents directory for auto-backups, a temp file handed to the share
/// sheet for manual export) and never sent anywhere. See `SpendSmartBackupService` for exactly
/// what is and isn't included — no Plaid tokens, Supabase secrets, or Amex credentials are ever
/// present in this app to begin with, so there's nothing here that could leak them.
struct DataBackupView: View {
    @Query private var accounts: [Account]
    @Query private var transactions: [FinanceTransaction]
    @Query private var categories: [Category]
    @Query private var settingsList: [BudgetSettings]
    @Query private var monthlyPlanSettingsList: [MonthlyPlanSettings]
    @Query private var incomeSources: [IncomeSource]
    @Query private var recurringExpenses: [RecurringExpense]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AutoBackupManager.self) private var autoBackupManager

    @State private var manualExportURL: URL?
    @State private var isPresentingFileImporter = false
    @State private var pendingDocument: SpendSmartBackupService.Document?
    @State private var isPresentingReplaceConfirmation = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var isPresentingAlert = false
    @State private var autoBackupFiles: [URL] = []

    private var settings: BudgetSettings? { settingsList.first }

    private var latestAutoBackupDate: Date? {
        guard let latest = autoBackupFiles.first else { return nil }
        return (try? latest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    header
                    privacyWarningCard
                    manualBackupSection
                    if let pendingDocument {
                        importPreviewSection(pendingDocument)
                    }
                    automaticBackupsSection
                }
                .padding(.vertical, Theme.Spacing.lg)
            }
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .task { refreshAutoBackupFiles() }
            .onAppear { prepareManualExport() }
            .fileImporter(isPresented: $isPresentingFileImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    loadBackupFile(from: url)
                case .failure(let error):
                    showAlert(title: "Couldn't Open File", message: error.localizedDescription)
                }
            }
            .confirmationDialog(
                "Replace current data with this backup?",
                isPresented: $isPresentingReplaceConfirmation,
                titleVisibility: .visible
            ) {
                Button("Replace All Data", role: .destructive) { performRestore() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Importing this backup will replace the current data on this device. This cannot be undone unless you export your current data first.")
            }
            .alert(alertTitle, isPresented: $isPresentingAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Data Backup")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("Export, import, and protect your finance data")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private var privacyWarningCard: some View {
        CardBackground {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.statusWarning)
                Text("Backup files contain your financial data. Store them somewhere private and secure.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Manual backup

    private var manualBackupSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Manual Backup")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if let manualExportURL {
                        ShareLink(item: manualExportURL) {
                            actionRow(icon: "square.and.arrow.up", title: "Export Full Backup", subtitle: "Save a full backup to Files, iCloud Drive, or elsewhere")
                        }
                    } else {
                        actionRow(icon: "square.and.arrow.up", title: "Export Full Backup", subtitle: "Preparing…")
                            .opacity(0.5)
                    }

                    Divider().overlay(Theme.cardStroke)

                    Button {
                        isPresentingFileImporter = true
                    } label: {
                        actionRow(icon: "square.and.arrow.down", title: "Import Backup File", subtitle: "Pick a SpendSmart backup .json file from Files")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    // MARK: - Import preview

    @ViewBuilder
    private func importPreviewSection(_ document: SpendSmartBackupService.Document) -> some View {
        let preview = SpendSmartBackupService.summary(for: document)
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Import Preview")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    previewRow(title: "Created", value: preview.createdAt.formatted(date: .abbreviated, time: .shortened))
                    previewRow(title: "Accounts", value: "\(preview.accountsCount)")
                    previewRow(title: "Transactions", value: "\(preview.transactionsCount)")
                    previewRow(title: "Categories", value: "\(preview.categoriesCount)")
                    previewRow(title: "Income Sources", value: "\(preview.incomeSourcesCount)")
                    previewRow(title: "Recurring Expenses", value: "\(preview.recurringExpensesCount)")

                    Divider().overlay(Theme.cardStroke)

                    Text("Importing this backup will replace the current data on this device. This cannot be undone unless you export your current data first.")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.statusOver)

                    HStack(spacing: Theme.Spacing.sm) {
                        PremiumActionButton(title: "Restore", systemIconName: "arrow.counterclockwise") {
                            isPresentingReplaceConfirmation = true
                        }
                        Button {
                            self.pendingDocument = nil
                        } label: {
                            Text("Cancel")
                                .font(Theme.bodyFont)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Theme.Spacing.sm)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    @ViewBuilder
    private func previewRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Text(value)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    // MARK: - Automatic backups

    private var automaticBackupsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            DashboardSectionHeader(title: "Automatic Backups")

            CardBackground {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    TransactionToggleRow(
                        title: "Auto Backup Enabled",
                        subtitle: "Automatically save a local backup shortly after your data changes",
                        isOn: Binding(
                            get: { settings?.autoBackupEnabled ?? true },
                            set: { newValue in
                                if let settings {
                                    settings.autoBackupEnabled = newValue
                                    settings.updatedAt = .now
                                } else {
                                    let created = BudgetSettings(autoBackupEnabled: newValue)
                                    modelContext.insert(created)
                                }
                            }
                        )
                    )

                    Divider().overlay(Theme.cardStroke)

                    previewRow(title: "Last Automatic Backup", value: latestAutoBackupDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                    previewRow(title: "Saved Backups", value: "\(autoBackupFiles.count) of 5")

                    if let lastBackupError = autoBackupManager.lastBackupError {
                        Text("Last attempt failed: \(lastBackupError)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.statusOver)
                    }

                    Divider().overlay(Theme.cardStroke)

                    if let latest = autoBackupFiles.first {
                        ShareLink(item: latest) {
                            actionRow(icon: "square.and.arrow.up", title: "Export Latest Auto Backup", subtitle: "Save the newest automatic backup elsewhere")
                        }

                        Divider().overlay(Theme.cardStroke)

                        Button {
                            loadLatestAutoBackup()
                        } label: {
                            actionRow(icon: "arrow.counterclockwise", title: "Restore Latest Auto Backup", subtitle: "Preview and confirm before replacing current data")
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("No automatic backups have been saved yet.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    @ViewBuilder
    private func actionRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.accent.opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
    }

    // MARK: - Actions

    private func prepareManualExport() {
        do {
            let document = try SpendSmartBackupService.fetchAndMakeDocument(context: modelContext)
            let data = try SpendSmartBackupService.encode(document)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(SpendSmartBackupService.backupFilename())
            try data.write(to: url, options: .atomic)
            manualExportURL = url
        } catch {
            showAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }

    private func refreshAutoBackupFiles() {
        autoBackupFiles = SpendSmartBackupService.autoBackupFiles(in: SpendSmartBackupService.documentsDirectory())
    }

    private func loadBackupFile(from url: URL) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            pendingDocument = try SpendSmartBackupService.decode(data)
        } catch let error as SpendSmartBackupService.BackupError {
            showAlert(title: "Invalid Backup", message: error.errorDescription ?? "This file couldn't be read.")
        } catch {
            showAlert(title: "Invalid Backup", message: "This file couldn't be read.")
        }
    }

    private func loadLatestAutoBackup() {
        guard let latest = autoBackupFiles.first else {
            showAlert(title: "No Automatic Backups", message: "No automatic backups have been saved yet.")
            return
        }
        do {
            let data = try Data(contentsOf: latest)
            pendingDocument = try SpendSmartBackupService.decode(data)
        } catch {
            showAlert(title: "Invalid Backup", message: "The latest automatic backup couldn't be read.")
        }
    }

    private func performRestore() {
        guard let pendingDocument else { return }
        do {
            try SpendSmartBackupService.restore(pendingDocument, into: modelContext)
            self.pendingDocument = nil
            refreshAutoBackupFiles()
            prepareManualExport()
            showAlert(title: "Backup Restored", message: "Your data has been restored from this backup.")
        } catch {
            showAlert(title: "Restore Failed", message: error.localizedDescription)
        }
    }

    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        isPresentingAlert = true
    }
}

#Preview {
    DataBackupView()
        .modelContainer(SampleData.previewContainer)
        .environment(AutoBackupManager())
}
