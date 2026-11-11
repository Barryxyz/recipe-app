import SwiftUI

/// F3.6: a thin bar above the tab bar while offline or while changes wait to sync.
struct SyncStatusBar: View {
    private var store = OfflineStore.shared
    private var connectivity = Connectivity.shared

    var body: some View {
        if !connectivity.isOnline {
            bar(icon: "wifi.slash",
                text: store.pendingCount > 0
                    ? "Offline · \(store.pendingCount) change\(store.pendingCount == 1 ? "" : "s") will sync"
                    : "Offline · your changes sync when you're back online",
                tint: .orange)
        } else if store.pendingCount > 0 {
            bar(icon: "icloud.and.arrow.up", text: "Syncing \(store.pendingCount) change\(store.pendingCount == 1 ? "" : "s")…",
                tint: .secondary)
        }
    }

    private func bar(icon: String, text: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(.medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.bar)
            .accessibilityElement(children: .combine)
    }
}

/// "Needs internet" for features that use the server (scan, recipe ideas, editing recipes…).
struct NeedsInternet: ViewModifier {
    @State private var connectivity = Connectivity.shared
    func body(content: Content) -> some View {
        content.disabled(!connectivity.isOnline)
    }
}

extension View {
    /// Disabled while offline (F3.6).
    func needsInternet() -> some View { modifier(NeedsInternet()) }
}
