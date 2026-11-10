import SwiftUI

@main
struct FridgeApp: App {
    /// Unit tests launch the app as their host. Don't sign in there: it would create a real
    /// anonymous account in the database on every test run.
    private static let isRunningUnitTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        // Become the notification delegate at launch, so tapping a reminder that started the
        // app still opens the pantry (F5.1).
        if !Self.isRunningUnitTests { _ = ExpiryReminders.shared }
    }

    var body: some Scene {
        WindowGroup {
            if Self.isRunningUnitTests {
                Text("Running tests")
            } else {
                RootView()
            }
        }
        // F5.1: about once a day, iOS wakes the app to rebuild the expiry reminders.
        .backgroundTask(.appRefresh(ExpiryReminders.backgroundTaskId)) {
            await BackgroundRefresh.run()
        }
    }
}
