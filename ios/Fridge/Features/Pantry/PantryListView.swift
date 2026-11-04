import SwiftUI

/// Temporary pantry list for F1.5 (name, quantity, location, expiry). F1.4 replaces it with
/// tabs, badges, swipe actions and search.
struct PantryListView: View {
    let user: AppUser

    @State private var items: [PantryItem] = []
    @State private var loaded = false
    @State private var loadError: String?
    @State private var showAdd = false
    @State private var editing: PantryItem?
    @State private var showDebug = false

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView()
                } else if let loadError, items.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't load your pantry", systemImage: "exclamationmark.triangle")
                    } description: { Text(loadError) } actions: {
                        Button("Retry") { Task { await load() } }
                    }
                } else if items.isEmpty {
                    ContentUnavailableView {
                        Label("Your pantry is empty", systemImage: "refrigerator")
                    } description: {
                        Text("Add what's in your fridge, freezer and cupboards.")
                    } actions: {
                        Button("Add manually") { showAdd = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    List(items) { item in
                        Button { editing = item } label: { row(item) }
                            .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Pantry")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showDebug = true } label: { Image(systemName: "info.circle") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add items")
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showAdd) {
                ItemFormView(mode: .add) { Task { await load() } }
            }
            .sheet(item: $editing) { item in
                ItemFormView(mode: .edit(item)) { Task { await load() } }
            }
            .sheet(isPresented: $showDebug) { DebugView(user: user) }
        }
    }

    private func row(_ item: PantryItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                Text("\(QuantityFormat.string(item.quantity, unit: item.unit)) · \(item.location.title)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let expires = item.expiresAt {
                Text(expires.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("No expiry").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func load() async {
        do {
            items = try await PantryAPI.activeItems()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }
}
