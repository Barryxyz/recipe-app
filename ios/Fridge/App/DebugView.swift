import SwiftUI

/// Temporary F0.1 screen: calls the `hello` Edge Function and shows the result.
/// Replaced by real navigation once the pantry features land.
struct DebugView: View {
    let user: AppUser

    private enum Status {
        case loading
        case ok(HelloResponse)
        case failed(String)
    }

    @State private var status: Status = .loading

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
                Section("hello function") {
                    switch status {
                    case .loading:
                        ProgressView()
                    case .ok(let response):
                        LabeledContent("Message", value: response.message)
                        LabeledContent("Anthropic key set",
                                       value: response.anthropicKeyConfigured ? "Yes" : "No")
                        LabeledContent("Server time", value: response.serverTime)
                    case .failed(let error):
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Fridge (debug)")
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        do {
            status = .ok(try await DebugAPI.hello())
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

#Preview {
    DebugView(user: AppUser(id: UUID(), householdId: UUID(), createdAt: .now))
}
