import SwiftUI
import SwiftData

/// Dashboard ▸ Quick Stats "+" — lets the user choose which of the 6 Quick Stat tiles show on the
/// Dashboard. Unlike `FavoritesConfigurationView`, there is no reorder or capacity limit here:
/// Quick Stats always render in their fixed canonical order (see `DashboardView.quickStatsSection`),
/// this screen only controls which are shown at all.
struct QuickStatsConfigurationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// Sorted deterministically (`\.id`) so this screen and `DashboardView`'s own identically-sorted
    /// `@Query` always agree on which row is "first" — same reasoning as
    /// `FavoritesConfigurationView`'s own `@Query`.
    @Query(sort: \QuickStatsSettings.id) private var quickStatsSettingsList: [QuickStatsSettings]

    private var settings: QuickStatsSettings? {
        quickStatsSettingsList.first
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(QuickStatID.allCases) { stat in
                        row(for: stat)
                    }
                } footer: {
                    Text("Choose which stats appear on the Dashboard's Quick Stats card.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Quick Stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .onAppear {
                QuickStatsSettings.resolveCanonicalRecord(existing: quickStatsSettingsList, in: modelContext)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(for stat: QuickStatID) -> some View {
        let isShown = !(settings?.isHidden(stat) ?? false)
        return Button {
            toggle(stat, currentlyShown: isShown)
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: stat.systemImageName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.accent.opacity(0.16)))
                    .opacity(isShown ? 1 : 0.55)

                Text(stat.displayName)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                Image(systemName: isShown ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isShown ? Theme.accent : Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.cardSurface)
        .accessibilityAddTraits(isShown ? [.isSelected] : [])
    }

    private func toggle(_ stat: QuickStatID, currentlyShown: Bool) {
        let record = QuickStatsSettings.resolveCanonicalRecord(existing: quickStatsSettingsList, in: modelContext)
        record.setHidden(stat, hidden: currentlyShown)
    }
}

#Preview {
    QuickStatsConfigurationView()
        .modelContainer(SampleData.previewContainer)
}
