import SwiftUI

/// Temporary screen until the pantry features land (F1.4).
/// Shows the signed-in anonymous user (F0.2).
struct DebugView: View {
    let user: AppUser

    var body: some View {
        NavigationStack {
            List {
                Section("Signed in (anonymous)") {
                    LabeledContent("User", value: user.id.uuidString.prefix(8) + "…")
                    LabeledContent("Household", value: user.householdId.uuidString.prefix(8) + "…")
                    LabeledContent("Since", value: user.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                Section("Supabase") {
                    LabeledContent("URL", value: AppConfig.supabaseURL.host ?? "?")
                }
            }
            .navigationTitle("Fridge (debug)")
        }
    }
}

#Preview {
    DebugView(user: AppUser(id: UUID(), householdId: UUID(), createdAt: .now))
}
