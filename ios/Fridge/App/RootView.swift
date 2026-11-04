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

/// Signed in: the pantry, with onboarding (F1.7) on top the first time.
private struct ReadyView: View {
    let user: AppUser
    @State private var showOnboarding = false

    var body: some View {
        PantryListView(user: user)
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
