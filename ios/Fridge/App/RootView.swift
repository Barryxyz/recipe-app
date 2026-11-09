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

    var body: some View {
        GeometryReader { geo in
            // Both tabs stay alive so each keeps its place, search and scroll position.
            ZStack {
                tabContent(.pantry) { PantryListView(user: user) }
                tabContent(.recipes) { RecipesView(user: user) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: AppTabBar.height) }
            .overlay(alignment: .bottom) {
                AppTabBar(selection: $tab, bottomInset: geo.safeAreaInsets.bottom)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .ignoresSafeArea(.keyboard)
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

private extension ReadyView {
    func tabContent<V: View>(_ t: AppTab, @ViewBuilder _ view: () -> V) -> some View {
        view()
            .opacity(tab == t ? 1 : 0)
            .allowsHitTesting(tab == t)
            .accessibilityHidden(tab != t)
    }
}

/// Solid (not translucent) tab bar with its items centred in the visible bar, kept clear of
/// the home indicator.
struct AppTabBar: View {
    @Binding var selection: AppTab
    let bottomInset: CGFloat
    /// Bar height above the home-indicator area (the standard tab bar is 49).
    static let height: CGFloat = 50

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                ForEach(AppTab.allCases, id: \.self) { t in
                    Button { selection = t } label: {
                        // Icon and title as one block, centred together.
                        VStack(spacing: 2) {
                            Image(systemName: t.icon)
                                .font(.system(size: 19, weight: .medium))
                                .frame(height: 22)          // same height for both icons
                            Text(t.title).font(.caption2.weight(.medium))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .foregroundStyle(selection == t ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == t ? [.isSelected, .isButton] : .isButton)
                }
            }
            // Centred in the visible bar: the bar plus the part of the home-indicator area
            // above the indicator itself.
            .frame(height: Self.height + bottomInset * 0.35)
            Color.clear.frame(height: bottomInset * 0.65)
        }
        .background(Color(.systemBackground))
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
