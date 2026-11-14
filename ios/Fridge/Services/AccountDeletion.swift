import Foundation
import Supabase

/// F5.3 / F0.2: Delete account. The server deletes everything at once (`app.delete_my_account`);
/// then the device is cleared like a fresh install and a new anonymous account starts
/// (SessionStore restarts on sign-out).
@MainActor
enum AccountDeletion {
    static func deleteEverything() async throws {
        try await supabase.schema("app").rpc("delete_my_account").execute()
        Events.discardPending()
        await ExpiryReminders.cancelAll()
        OfflineStore.shared.wipe()
        RecipeSession.clear()
        RecipeCreator.discardDraft()
        // Settings held in memory go back to a fresh install's, then the stored ones are removed.
        ExpiryReminders.shared.enabled = false
        AIConsent.shared.granted = false
        SharedLinkRouter.shared.pending = nil
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        try? await supabase.auth.signOut(scope: .local)
    }
}
