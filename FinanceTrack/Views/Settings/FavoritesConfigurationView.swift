import SwiftUI
import SwiftData

/// "Profile ▸ Favorites" — reachable from `SettingsView`'s new Favorites row, matching every other
/// settings-style sheet in this app (`ConnectedAccountsView`, `CategoryManagementView`, ...):
/// `@Query`/`@Environment(\.modelContext)` read directly, no primitive-`@State`-snapshot pattern,
/// because (unlike `SettingsView`/`AccountView`) this screen never triggers sign-out and so can
/// never race a `ModelContext` being torn down mid-render.
///
/// Two sections, matching the locked "add / remove / reorder selected" requirement precisely:
/// "Selected" (the current Dashboard order — tap to remove, drag to reorder) and "Available" (tap
/// to add). Splitting them this way means reordering can only ever apply to the selected subset —
/// never accidentally shuffling an unselected destination into the middle of the selected order.
struct FavoritesConfigurationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AccountRelatedOptionsViewModel.self) private var accountRelatedOptionsViewModel
    /// Sorted deterministically (`\.id`) so this screen and `DashboardView`'s own identically-sorted
    /// `@Query` always agree on which row is "first" — see `FavoritesSettings.resolveCanonicalRecord`'s
    /// own header for why an unsorted `.first` was part of the proven real-device bug.
    @Query(sort: \FavoritesSettings.id) private var favoritesSettingsList: [FavoritesSettings]
    /// TWO-LINE FAVORITES PHASE — candidates for the "Checking Register" Favorite's "Change"
    /// affordance below, same non-archived-Manual-Account scoping `DashboardView`'s own picker uses.
    @Query(sort: \Account.createdAt) private var manualAccounts: [Account]

    @State private var isPresentingMaxCapacityAlert = false
    /// TWO-LINE FAVORITES PHASE — non-`nil` while re-choosing the "Checking Register" Favorite's
    /// target account from this screen (the "Change" affordance on its already-selected row).
    @State private var isPresentingCheckingRegisterPicker = false

    /// Read-only — a plain array read, never an insert. Creating/merging the canonical record only
    /// ever happens explicitly from `.onAppear` or a mutation call site below, never as a side
    /// effect of simply computing what to display (see `FavoritesSettings.resolveCanonicalRecord`'s
    /// own header for exactly why that distinction is the fix).
    private var favoritesSettings: FavoritesSettings? {
        favoritesSettingsList.first
    }

    /// Every destination currently eligible for this user — an ineligible destination (today, only
    /// `.accountSharing` before role resolution completes) never appears here at all, matching the
    /// locked "only eligible favorites should be shown" requirement.
    private var eligibleDestinations: [FavoriteDestinationID] {
        FavoriteDestinationID.allCases.filter {
            FavoriteDestinationID.isEligible($0, accountRelatedOptionsVisibility: accountRelatedOptionsViewModel.visibility)
        }
    }

    private var selectedDestinations: [FavoriteDestinationID] {
        (favoritesSettings?.validDestinationIDs ?? []).filter { eligibleDestinations.contains($0) }
    }

    private var availableDestinations: [FavoriteDestinationID] {
        eligibleDestinations.filter { !selectedDestinations.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !selectedDestinations.isEmpty {
                    Section {
                        ForEach(selectedDestinations) { destination in
                            row(for: destination, isSelected: true)
                        }
                        .onMove(perform: moveSelected)
                    } header: {
                        Text("Selected")
                    } footer: {
                        Text("\(selectedDestinations.count) of \(FavoritesBarLayout.maximumFavoritesCount) selected. Drag to reorder — the same order appears on the Dashboard.")
                    }
                }

                if !availableDestinations.isEmpty {
                    Section("Available") {
                        ForEach(availableDestinations) { destination in
                            row(for: destination, isSelected: false)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                if selectedDestinations.count > 1 {
                    ToolbarItem(placement: .primaryAction) {
                        EditButton()
                    }
                }
            }
            .onAppear {
                let record = FavoritesSettings.resolveCanonicalRecord(existing: favoritesSettingsList, in: modelContext)
                // PHASE 2B VISUAL FIX — must run BEFORE reconcileEligibility (see that method's
                // own migration-ordering note): converts any legacy "addToSavings" favorite to
                // "monthlyPlan" persistently, before eligibility filtering would otherwise strip
                // it outright now that it's no longer a separately selectable destination.
                record.migrateAddToSavingsToMonthlyPlanIfNeeded()
                record.reconcileEligibility(accountRelatedOptionsVisibility: accountRelatedOptionsViewModel.visibility)
            }
            .alert("No more Favorites can be added", isPresented: $isPresentingMaxCapacityAlert) {
                Button("OK") {}
            } message: {
                Text("Remove an existing favorite to add another.")
            }
            .sheet(isPresented: $isPresentingCheckingRegisterPicker) {
                CheckingRegisterAccountPickerView(accounts: manualAccounts.filter { !$0.isArchived }) { account in
                    let record = FavoritesSettings.resolveCanonicalRecord(existing: favoritesSettingsList, in: modelContext)
                    record.setCheckingRegisterAccount(account.id)
                    try? modelContext.save()
                    isPresentingCheckingRegisterPicker = false
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(for destination: FavoriteDestinationID, isSelected: Bool) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button {
                toggle(destination, currentlySelected: isSelected)
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    FavoriteDestinationIconBadge(destination: destination, diameter: 32, symbolSize: 15)
                        .opacity(isSelected ? 1 : 0.55)

                    Text(destination.displayName)
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.textPrimary)

                    Spacer()

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // TWO-LINE FAVORITES PHASE — lets Scott re-map the "Checking Register" Favorite to a
            // different Manual Account later, per Part 7's "low-risk, if practical" request, without
            // disturbing the row's own existing select/deselect tap target above.
            if isSelected && destination == .checkingRegister {
                Button("Change") {
                    isPresentingCheckingRegisterPicker = true
                }
                .font(Theme.captionFont)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
        }
        .listRowBackground(Theme.cardSurface)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func toggle(_ destination: FavoriteDestinationID, currentlySelected: Bool) {
        let record = FavoritesSettings.resolveCanonicalRecord(existing: favoritesSettingsList, in: modelContext)
        if currentlySelected {
            record.removeFavorite(destination)
        } else {
            let added = record.addFavorite(destination)
            if !added {
                isPresentingMaxCapacityAlert = true
            }
        }
    }

    private func moveSelected(from source: IndexSet, to destination: Int) {
        let record = FavoritesSettings.resolveCanonicalRecord(existing: favoritesSettingsList, in: modelContext)
        record.moveFavorites(fromOffsets: source, toOffset: destination)
    }
}

#Preview {
    FavoritesConfigurationView()
        .modelContainer(SampleData.previewContainer)
        .environment(AccountRelatedOptionsViewModel())
}
