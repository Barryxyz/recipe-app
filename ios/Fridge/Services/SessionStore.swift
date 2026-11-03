import Foundation
import Observation
import Supabase

/// Owns the user's session (F0.2).
///
/// - First launch: signs in anonymously; the `on_auth_user_created` trigger creates the
///   household, `app.users` row and default prefs.
/// - Later launches: the SDK restores the session from the Keychain and refreshes it.
/// - A session the server no longer accepts (e.g. the account was deleted) goes back to first launch.
/// - Network failures never create a new account; they show the offline screen instead,
///   so a flaky connection can't orphan the user's data.
@MainActor
@Observable
final class SessionStore {
    enum State: Equatable {
        case loading
        case offline(String)
        case ready(AppUser)
    }

    private(set) var state: State = .loading
    private var isStarting = false

    /// Errors meaning the stored session is permanently unusable.
    private static let deadSessionCodes: Set<ErrorCode> = [
        .refreshTokenNotFound, .sessionNotFound, .sessionExpired, .userNotFound,
    ]

    func start() async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        state = .loading
        do {
            let session = try await currentOrNewSession()
            let user: AppUser = try await supabase.schema("app")
                .from("users")
                .select("id, household_id, created_at")
                .eq("id", value: session.user.id)
                .single()
                .execute()
                .value
            state = .ready(user)
        } catch {
            state = .offline(Self.message(for: error))
        }
    }

    /// Restarts from first launch if the session ends (e.g. deleted on another device).
    func observeAuthChanges() async {
        for await (event, _) in supabase.auth.authStateChanges where event == .signedOut {
            await start()
        }
    }

    private func currentOrNewSession() async throws -> Session {
        if supabase.auth.currentSession != nil {
            do {
                return try await supabase.auth.session   // refreshes if expired
            } catch let error as AuthError where Self.isDeadSession(error) {
                try? await supabase.auth.signOut(scope: .local)
            }
        }
        return try await supabase.auth.signInAnonymously()
    }

    private static func isDeadSession(_ error: AuthError) -> Bool {
        if case .sessionMissing = error { return true }
        return deadSessionCodes.contains(error.errorCode)
    }

    private static func message(for error: Error) -> String {
        if error is URLError {
            return "You're offline. Connect to the internet and try again."
        }
        return "Couldn't reach the server. Try again in a moment.\n(\(error.localizedDescription))"
    }
}
