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
                ExpiryRemindersSection()

                Section {
                    Button { SubscriptionStore.shared.showPaywall = true } label: {
                        LabeledContent {
                            Text(SubscriptionStore.shared.status?.active == true ? "Active" : "Not subscribed")
                        } label: { Label("Subscription", systemImage: "sparkles") }
                    }
                    .foregroundStyle(.primary)
                }

                PrivacySection()
                DeleteAccountSection()

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

/// Settings → Expiry reminders (F5.1): on/off, time, how early, and a test.
struct ExpiryRemindersSection: View {
    @Bindable private var reminders = ExpiryReminders.shared
    @State private var blocked = false
    @State private var testMessage: String?

    var body: some View {
        Section {
            Toggle("Daily reminder", isOn: Binding(get: { reminders.enabled }, set: { on in
                if on { Task { blocked = !(await reminders.turnOn()) } } else { reminders.enabled = false }
            }))
            if blocked {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notifications are off for Fridge in iOS Settings.").font(.footnote).foregroundStyle(.secondary)
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.footnote.weight(.semibold))
                }
            }
            if reminders.enabled {
                DatePicker("Time", selection: $reminders.time, displayedComponents: .hourAndMinute)
                Picker("Warn me", selection: $reminders.leadDays) {
                    Text("1 day before").tag(1)
                    Text("2 days before").tag(2)
                    Text("3 days before").tag(3)
                }
                Button("Send a test reminder") {
                    Task {
                        testMessage = await reminders.sendTest()
                            ?? "Sent: it appears in about 5 seconds. Lock the phone or go to the Home Screen to see it there."
                    }
                }
                if let testMessage { Text(testMessage).font(.footnote).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Expiry reminders")
        } footer: {
            Text("At most one a day, listing what's about to expire. Seasonings & staples aren't included.")
        }
        .task { if reminders.enabled { blocked = !(await reminders.systemAllows()) } }
    }
}

/// F5.3: the AI consent (can be withdrawn) and the privacy policy.
struct PrivacySection: View {
    @State private var consent = AIConsent.shared

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { consent.granted }, set: { consent.granted = $0 })) {
                Label("Use AI features", systemImage: "sparkles.rectangle.stack")
            }
            if let url = AppConfig.privacyURL {
                Link(destination: url) { Label("Privacy policy", systemImage: "hand.raised") }
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Scanning, recipe ideas and nutrition estimates send photos, your pantry and preferences to Anthropic's AI. Photos aren't stored. Turned off, those features ask first.")
        }
    }
}

/// F5.3: Delete account, with a confirmation that says what goes and what doesn't.
struct DeleteAccountSection: View {
    @State private var subscriptions = SubscriptionStore.shared
    @State private var manage = false
    @State private var confirming = false
    @State private var deleting = false
    @State private var error: String?

    var body: some View {
        Section {
            Button(role: .destructive) { confirming = true } label: {
                HStack {
                    Label("Delete account", systemImage: "trash")
                    if deleting { Spacer(); ProgressView() }
                }
            }
            .disabled(deleting)
            .needsInternet()
        } footer: {
            Text("Permanently deletes your pantry, recipes, shopping list and preferences, and turns off your shared links.")
        }
        .confirmationDialog("Delete your account?", isPresented: $confirming, titleVisibility: .visible) {
            if subscribedUntil != nil {
                Button("Manage subscription") { manage = true }
            }
            Button("Delete everything", role: .destructive) { Task { await delete() } }
        } message: {
            Text(Self.message(subscribedUntil: subscribedUntil))
        }
        .manageSubscriptionsSheet(isPresented: $manage)
        .alert("Couldn't delete your account", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    /// The renewal date while the subscription is active (F0.6).
    private var subscribedUntil: Date? {
        guard let s = subscriptions.status, s.active else { return nil }
        return s.expires_at ?? .distantFuture
    }

    static func message(subscribedUntil: Date?) -> String {
        let data = "Your pantry, saved recipes, shopping list, preferences and shared links are deleted straight away. This can't be undone."
        guard let until = subscribedUntil else {
            return data + "\n\nIf you subscribed, deleting your account doesn't cancel it: cancel in Settings → Apple ID → Subscriptions."
        }
        let date = until == .distantFuture ? "" : " (renews or ends \(until.formatted(date: .long, time: .omitted)))"
        return data + "\n\nYou're subscribed\(date). Deleting your account doesn't cancel it: Apple keeps billing your Apple ID until you cancel. Tap Manage subscription to cancel first. If you keep it, it moves to your new account the next time you open the app."
    }

    private func delete() async {
        deleting = true
        defer { deleting = false }
        do { try await AccountDeletion.deleteEverything() }
        catch { self.error = "Nothing was deleted. Check your connection and try again." }
    }
}
