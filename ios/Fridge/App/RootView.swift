import SwiftUI

/// Routes between the launch states of the session (F0.2).
struct RootView: View {
    @State private var session = SessionStore()

    var body: some View {
        Group {
            switch session.state {
            case .loading:
                ProgressView("Starting…")
            case .offline(let message):
                OfflineView(message: message) {
                    Task { await session.start() }
                }
            case .ready(let user):
                ReadyView(user: user)
            }
        }
        .task { await session.start() }
        .task { await session.observeAuthChanges() }
    }
}

/// Signed in: Pantry and Recipes tabs, with onboarding (F1.7) on top the first time.
private struct ReadyView: View {
    let user: AppUser
    @State private var showOnboarding = false

    @State private var tab: AppTab = .pantry

    init(user: AppUser) {
        self.user = user
        AppTabBar.applyAppearance()
    }

    var body: some View {
        TabView(selection: $tab) {
            PantryListView(user: user)
                .tabItem { Label(AppTab.pantry.title, systemImage: AppTab.pantry.icon) }
                .tag(AppTab.pantry)
            RecipesView(user: user)
                .tabItem { Label(AppTab.recipes.title, systemImage: AppTab.recipes.icon) }
                .tag(AppTab.recipes)
        }
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView(user: user) { showOnboarding = false }
            }
            .task(id: user.id) {
                guard !OnboardingState.isDone(for: user.id) else { return }
                // A reinstall with saved preferences skips onboarding.
                if let prefs = try? await PrefsAPI.load(userId: user.id), OnboardingState.prefsLookConfigured(prefs) {
                    OnboardingState.markDone(for: user.id)
                } else {
                    showOnboarding = true
                }
            }
    }
}

enum AppTab: CaseIterable {
    case pantry, recipes

    var title: String { self == .pantry ? "Pantry" : "Recipes" }
    var icon: String { self == .pantry ? "refrigerator" : "fork.knife" }
}

/// The standard iPhone tab bar, solid instead of translucent (like most fitness and food apps).
enum AppTabBar {
    static func applyAppearance() {
        let a = UITabBarAppearance()
        a.configureWithOpaqueBackground()
        a.backgroundColor = .systemBackground
        a.shadowColor = .separator            // thin line above the bar
        UITabBar.appearance().standardAppearance = a
        UITabBar.appearance().scrollEdgeAppearance = a
    }
}

struct OfflineView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Can't connect", systemImage: "wifi.slash")
        } description: {
            Text(message)
        } actions: {
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}
