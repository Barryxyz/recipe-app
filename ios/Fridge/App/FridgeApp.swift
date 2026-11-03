import SwiftUI

@main
struct FridgeApp: App {
    /// Unit tests launch the app as their host. Don't sign in there: it would create a real
    /// anonymous account in the database on every test run.
    private static let isRunningUnitTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some Scene {
        WindowGroup {
            if Self.isRunningUnitTests {
                Text("Running tests")
            } else {
                RootView()
            }
        }
    }
}
