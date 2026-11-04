import SwiftUI

/// F1.7: four short, skippable screens. Skip saves what's been chosen so far and finishes.
struct OnboardingView: View {
    let user: AppUser
    var onFinish: () -> Void

    @State private var step = 0
    @State private var draft = PrefsDraft()
    @State private var saving = false
    @State private var saveError: String?

    private let lastStep = 3

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch step {
                    case 0: welcome
                    case 1:
                        header("Any diets?", "Pick any that apply. You can change this later in Settings.")
                        DietPicker(draft: $draft)
                    case 2:
                        header("Any allergies?", "Recipes will leave these out.")
                        AllergyPicker(draft: $draft)
                    default:
                        header("Do you usually have these?", "They go in Seasoning & Staples at the bottom of your pantry. No amounts or dates needed.")
                        StaplesEditor(draft: $draft)
                        Divider()
                        ServingsStepper(draft: $draft)
                    }
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                Button { Task { await next() } } label: {
                    Text(step == 0 ? "Get started" : step == lastStep ? "Finish" : "Next")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(saving)
                .padding(20)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step > 0 { Button("Back") { step -= 1 } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") { Task { await finish() } }.disabled(saving)
                }
            }
            .alert("Couldn't save", isPresented: .constant(saveError != nil)) {
                Button("Try again") { saveError = nil; Task { await finish() } }
                Button("Skip for now") { saveError = nil; onFinish() }
            } message: { Text(saveError ?? "") }
            .task {
                // Staples start pre-checked.
                if draft.staples.isEmpty { draft.staples = (try? await PrefsAPI.catalogStaples()) ?? [] }
            }
        }
        .interactiveDismissDisabled()
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "refrigerator").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Welcome to Fridge").font(.largeTitle.bold())
            Text("Keep track of what's in your fridge, freezer and pantry, use things before they expire, and get recipes from what you have.")
            Label {
                Text("When you scan your fridge, the photo is sent to an AI service to identify the food. Photos aren't stored.")
            } icon: { Image(systemName: "camera") }
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
    }

    private func next() async {
        if step < lastStep { withAnimation { step += 1 } } else { await finish() }
    }

    private func finish() async {
        saving = true
        defer { saving = false }
        do {
            try await PrefsAPI.save(draft.prefs, userId: user.id)
            try await PantryAPI.addStaples(draft.staples)
            OnboardingState.markDone(for: user.id)
            onFinish()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// "Onboarding complete" is stored on the device (F1.7). A reinstall with an account that
/// already has preferences skips onboarding.
enum OnboardingState {
    private static func key(_ userId: UUID) -> String { "onboarding.done.\(userId.uuidString)" }

    static func isDone(for userId: UUID) -> Bool { UserDefaults.standard.bool(forKey: key(userId)) }
    static func markDone(for userId: UUID) { UserDefaults.standard.set(true, forKey: key(userId)) }

    /// Preferences that show the user already went through onboarding (e.g. before a reinstall).
    static func prefsLookConfigured(_ prefs: UserPrefs) -> Bool {
        !prefs.diets.isEmpty || !prefs.allergens.isEmpty || prefs.defaultServings != 2
    }
}
