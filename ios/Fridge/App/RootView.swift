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
                DebugView(user: user)
            }
        }
        .task { await session.start() }
        .task { await session.observeAuthChanges() }
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
