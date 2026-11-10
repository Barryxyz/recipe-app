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
    @Environment(\.scenePhase) private var scenePhase
    private var reminders = ExpiryReminders.shared

    init(user: AppUser) {
        self.user = user
        AppTabBar.applyAppearance()
    }

    var body: some View {
        TabView(selection: $tab) {
            PantryListView(user: user)
                .tabItem { AppTabBar.label(.pantry) }
                .tag(AppTab.pantry)
                .background(TabBarHeight(extra: AppTabBar.extraHeight))
            RecipesView(user: user)
                .tabItem { AppTabBar.label(.recipes) }
                .tag(AppTab.recipes)
                .background(TabBarHeight(extra: AppTabBar.extraHeight))
            ShoppingListView()
                .tabItem { AppTabBar.label(.shopping) }
                .tag(AppTab.shopping)
                .badge(ShoppingBadge.shared.count)
                .background(TabBarHeight(extra: AppTabBar.extraHeight))
        }
            .task { await ShoppingBadge.shared.refresh() }
            // F5.1: rebuild reminders when the app comes back; a tapped reminder opens the pantry.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { reminders.pantryChanged() }
                if phase == .background { BackgroundRefresh.schedule(); Events.flush() }
            }
            .onChange(of: reminders.openPantryRequest) { _, _ in tab = .pantry }
            .alert("Get a heads-up before food expires?", isPresented: Binding(
                get: { reminders.offerPrompt }, set: { reminders.offerPrompt = $0 })) {
                Button("Turn on") { Task { await reminders.turnOn() } }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("Fridge can send one reminder a day, at \(reminders.time.formatted(date: .omitted, time: .shortened)), listing what's about to expire. You can change this in Settings.")
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
    case pantry, recipes, shopping

    var title: String {
        switch self { case .pantry: "Pantry"; case .recipes: "Recipes"; case .shopping: "Shopping" }
    }
    var icon: String {
        switch self { case .pantry: "refrigerator"; case .recipes: "fork.knife"; case .shopping: "cart" }
    }
}

/// The standard iPhone tab bar, solid instead of translucent (like most fitness and food apps).
enum AppTabBar {
    /// Space added above each icon, and to the bar's height, so icons don't hug the top edge.
    static let iconTopSpace: CGFloat = 5
    static let extraHeight: CGFloat = 6

    static func label(_ tab: AppTab) -> some View {
        Label { Text(tab.title) } icon: { Image(uiImage: icon(tab.icon)) }
    }

    /// The SF Symbol drawn with transparent space above it (tab bars have no icon offset setting).
    static func icon(_ name: String) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        guard let base = UIImage(systemName: name, withConfiguration: config) else { return UIImage() }
        let size = CGSize(width: base.size.width, height: base.size.height + iconTopSpace)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            base.draw(at: CGPoint(x: 0, y: iconTopSpace))
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    static func applyAppearance() {
        let a = UITabBarAppearance()
        a.configureWithOpaqueBackground()
        a.backgroundColor = .systemBackground
        a.shadowColor = .separator            // thin line above the bar
        UITabBar.appearance().standardAppearance = a
        UITabBar.appearance().scrollEdgeAppearance = a
    }
}

/// Makes the system tab bar a little taller: its height follows the tab bar controller's bottom
/// safe area, so a few points of extra inset give the items more room.
private struct TabBarHeight: UIViewControllerRepresentable {
    let extra: CGFloat

    func makeUIViewController(context: Context) -> Finder { Finder(extra: extra) }
    func updateUIViewController(_ vc: Finder, context: Context) {}

    final class Finder: UIViewController {
        let extra: CGFloat
        init(extra: CGFloat) { self.extra = extra; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError() }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            var vc: UIViewController? = parent
            while let current = vc, !(current is UITabBarController) { vc = current.parent }
            if let tabs = vc as? UITabBarController, tabs.additionalSafeAreaInsets.bottom != extra {
                tabs.additionalSafeAreaInsets.bottom = extra
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
