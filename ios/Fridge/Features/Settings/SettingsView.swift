import SwiftUI

/// Settings: Food preferences (F1.7), Expiry defaults (F1.6) and About.
struct SettingsView: View {
    let user: AppUser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { FoodPrefsView(user: user) } label: {
                        Label("Food preferences", systemImage: "fork.knife")
                    }
                    NavigationLink { ExpiryDefaultsView() } label: {
                        Label("Expiry defaults", systemImage: "calendar.badge.clock")
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                    LabeledContent("Account", value: "Anonymous")
                    LabeledContent("User", value: user.id.uuidString.prefix(8) + "…")
                    LabeledContent("Household", value: user.householdId.uuidString.prefix(8) + "…")
                    LabeledContent("Server", value: AppConfig.supabaseURL.host ?? "?")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Settings → Food preferences: the onboarding choices as an editable form.
struct FoodPrefsView: View {
    let user: AppUser

    @State private var draft = PrefsDraft()
    @State private var saved = PrefsDraft()
    @State private var loaded = false
    @State private var status: String?

    var body: some View {
        Form {
            if loaded {
                Section("Diet") { DietPicker(draft: $draft) }
                Section("Allergies") { AllergyPicker(draft: $draft) }
                Section {
                    Text("Staples and seasonings are in your pantry, in Seasoning & Staples at the bottom.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Recipes") { ServingsStepper(draft: $draft) }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Food preferences")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(!loaded || draft == saved)
            }
        }
        .overlay(alignment: .bottom) {
            if let status {
                Text(status).padding(10).background(.regularMaterial, in: Capsule()).padding()
                    .task { try? await Task.sleep(for: .seconds(2)); self.status = nil }
            }
        }
        .task {
            guard let prefs = try? await PrefsAPI.load(userId: user.id) else { status = "Couldn't load"; return }
            draft = PrefsDraft(prefs, staples: [])
            saved = draft
            loaded = true
        }
    }

    private func save() async {
        do {
            try await PrefsAPI.save(draft.prefs, userId: user.id)
            OnboardingState.markDone(for: user.id)
            saved = draft
            status = "Saved"
        } catch {
            status = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

/// Settings → Expiry defaults: the user's "Always use N days" rules (F1.6), with edit and delete.
/// Changing a default doesn't change items already in the pantry.
struct ExpiryDefaultsView: View {
    @State private var defaults: [PrefsAPI.ExpiryDefault] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        List {
            if loaded && defaults.isEmpty {
                ContentUnavailableView("No expiry defaults",
                                       systemImage: "calendar",
                                       description: Text("When you change an item's date, turn on \u{201C}Always use N days\u{201D} to save one."))
            }
            ForEach($defaults) { $d in
                Stepper(value: $d.days, in: 0...3650) {
                    VStack(alignment: .leading) {
                        Text(d.name)
                        Text("\(d.location.title) · \(d.days) day\(d.days == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: d.days) { _, _ in Task { await update(d) } }
            }
            .onDelete { offsets in Task { await delete(offsets) } }
            if loaded && !defaults.isEmpty {
                Text("Changes apply to items added from now on. Swipe to delete a default.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Expiry defaults")
        .overlay { if !loaded { ProgressView() } }
        .alert("Something went wrong", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .task { await load() }
    }

    private func load() async {
        do { defaults = try await PrefsAPI.expiryDefaults() } catch { self.error = error.localizedDescription }
        loaded = true
    }

    private func update(_ d: PrefsAPI.ExpiryDefault) async {
        do { try await PrefsAPI.updateExpiryDefault(d) } catch { self.error = error.localizedDescription }
    }

    private func delete(_ offsets: IndexSet) async {
        let removed = offsets.map { defaults[$0] }
        defaults.remove(atOffsets: offsets)
        do {
            for d in removed { try await PrefsAPI.deleteExpiryDefault(d) }
        } catch {
            self.error = error.localizedDescription
            await load()
        }
    }
}
