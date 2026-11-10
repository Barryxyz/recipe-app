import BackgroundTasks
import Foundation

/// F5.1: the daily background refresh that keeps the scheduled expiry reminders current when
/// the app isn't opened. iOS decides when it actually runs.
enum BackgroundRefresh {
    /// Asks for the next run (about a day from now). Called when the app goes to the background
    /// and after each run.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: ExpiryReminders.backgroundTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run() async {
        schedule()
        _ = try? await PantryAPI.activeItems()       // reschedules the reminders with fresh data
    }
}
