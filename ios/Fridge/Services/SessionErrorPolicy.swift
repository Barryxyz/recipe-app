import Foundation
import Supabase

/// Decides what to do when restoring the stored session fails (F0.2).
///
/// Getting this wrong loses data: starting over creates a new anonymous account, and the
/// old account's pantry and recipes become unreachable. So only errors that prove the
/// session is permanently unusable start over; everything else (offline, timeouts,
/// server errors, unknown errors) shows the offline screen and lets the user retry.
enum SessionErrorPolicy {
    enum Action: Equatable {
        /// The server rejected the session for good: sign in again as a new user.
        case startOver
        /// Temporary or unknown problem: keep the session and show Retry.
        case retryLater
    }

    /// Auth error codes meaning the stored session can never be refreshed.
    static let deadSessionCodes: Set<ErrorCode> = [
        .refreshTokenNotFound, .sessionNotFound, .sessionExpired, .userNotFound,
    ]

    static func action(forRestoreError error: Error) -> Action {
        guard let authError = error as? AuthError else { return .retryLater }
        if case .sessionMissing = authError { return .startOver }
        if case .api = authError, deadSessionCodes.contains(authError.errorCode) { return .startOver }
        return .retryLater
    }

    /// Text for the offline screen.
    static func message(for error: Error) -> String {
        if error is URLError {
            return "You're offline. Connect to the internet and try again."
        }
        return "Couldn't reach the server. Try again in a moment.\n(\(error.localizedDescription))"
    }
}
