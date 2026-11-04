import SwiftUI

/// F1.4: the home screen. Tabs (All / Fridge / Freezer / Pantry) with counts, expiry badges,
/// "Use these first", search, grouped batches ("Milk ×2"), swipe left for Used / Discard with undo.
struct PantryListView: View {
    let user: AppUser

    private enum Tab: Hashable {
        case all
        case location(StorageLocation)
    }

    @State private var items: [PantryItem] = []
    @State private var loaded = false
    @State private var loadError: String?
    @State private var tab: Tab = .all
    @State private var sort: PantrySort = .expiry
    @State private var search = ""
    @State private var expanded: Set<String> = []
    @State private var useFirstExpanded = true

    @State private var showAdd = false
    @State private var editing: PantryItem?
    @State private var showDebug = false
    @State private var undo: UndoAction?
    @State private var actionError: String?

    private struct UndoAction: Equatable {
        let item: PantryItem
        let status: PantryItem.Status
        let id = UUID()
        var message: String { "\(item.displayName) \(status == .used ? "marked used" : "discarded")" }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Pantry")
                .toolbar { toolbar }
                .searchable(text: $search, prompt: "Search your pantry")
                .refreshable { await load() }
                .task { await load() }
                .sheet(isPresented: $showAdd) { ItemFormView(mode: .add) { Task { await load() } } }
                .sheet(item: $editing) { item in ItemFormView(mode: .edit(item)) { Task { await load() } } }
                .sheet(isPresented: $showDebug) { DebugView(user: user) }
                .overlay(alignment: .bottom) { undoToast }
                .alert("Something went wrong", isPresented: .constant(actionError != nil)) {
                    Button("OK") { actionError = nil }
                } message: { Text(actionError ?? "") }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !loaded {
            ProgressView()
        } else if let loadError, items.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load your pantry", systemImage: "exclamationmark.triangle")
            } description: { Text(loadError) } actions: {
                Button("Retry") { Task { await load() } }
            }
        } else if items.isEmpty {
            // "Scan your fridge" joins "Add manually" here when scanning ships (F1.1).
            ContentUnavailableView {
                Label("Your pantry is empty", systemImage: "refrigerator")
            } description: {
                Text("Add what's in your fridge, freezer and cupboards.")
            } actions: {
                Button("Add manually") { showAdd = true }.buttonStyle(.borderedProminent)
            }
        } else {
            List {
                if !isSearching {
                    Section { tabPicker }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                listSections
            }
            .listStyle(.insetGrouped)
            .animation(.default, value: items)
        }
    }

    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    private var tabPicker: some View {
        Picker("Location", selection: $tab) {
            Text("All \(items.count)").tag(Tab.all)
            ForEach(StorageLocation.allCases) { loc in
                Text("\(loc.title) \(items.filter { $0.location == loc }.count)").tag(Tab.location(loc))
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var listSections: some View {
        if isSearching {
            let found = PantryGrouping.searchResults(items, search: search, sort: sort)
            if found.isEmpty {
                Text("No items match \u{201C}\(search)\u{201D}").foregroundStyle(.secondary)
            } else {
                Section("Results") { rows(found, showLocation: true) }
            }
        } else {
            switch tab {
            case .all:
                let groups = PantryGrouping.groups(items, sort: sort)
                let soon = groups.filter { $0.badge().isExpiringSoon }
                if !soon.isEmpty {
                    Section {
                        if useFirstExpanded { rows(soon, showLocation: true) }
                    } header: {
                        Button { withAnimation { useFirstExpanded.toggle() } } label: {
                            HStack {
                                Text("Use these first (\(soon.count))")
                                Spacer()
                                Image(systemName: useFirstExpanded ? "chevron.down" : "chevron.right")
                            }
                        }
                        .foregroundStyle(.orange)
                    }
                }
                ForEach(StorageLocation.allCases) { loc in
                    let rest = groups.filter { $0.location == loc && !$0.badge().isExpiringSoon }
                    if !rest.isEmpty {
                        Section(loc.title) { rows(rest, showLocation: false) }
                    }
                }
            case .location(let loc):
                let groups = PantryGrouping.groups(items.filter { $0.location == loc }, sort: sort)
                if groups.isEmpty {
                    Text("Nothing in the \(loc.title.lowercased()) yet.").foregroundStyle(.secondary)
                } else {
                    Section { rows(groups, showLocation: false) }
                }
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rows(_ groups: [PantryGroup], showLocation: Bool) -> some View {
        ForEach(groups) { group in
            if group.isGroup {
                Button {
                    withAnimation { toggle(group.id) }
                } label: {
                    PantryRow(name: "\(group.name)  ×\(group.count)", amount: group.amountText,
                              location: showLocation ? group.location : nil, badge: group.badge(),
                              chevron: expanded.contains(group.id) ? .expanded : .collapsed)
                }
                .foregroundStyle(.primary)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) { swipeButtons(group.earliest) }

                if expanded.contains(group.id) {
                    ForEach(group.items) { item in itemRow(item, showLocation: false, indented: true) }
                }
            } else {
                itemRow(group.earliest, showLocation: showLocation, indented: false)
            }
        }
    }

    private func itemRow(_ item: PantryItem, showLocation: Bool, indented: Bool) -> some View {
        Button { editing = item } label: {
            PantryRow(name: item.displayName, amount: QuantityFormat.string(item.quantity, unit: item.unit),
                      location: showLocation ? item.location : nil,
                      badge: ExpiryBadge(expiresAt: item.expiresAt), chevron: nil)
                .padding(.leading, indented ? 20 : 0)
        }
        .foregroundStyle(.primary)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) { swipeButtons(item) }
    }

    /// Swiping left reveals Used and Discard side by side (user's choice, option B).
    /// Used comes first, so a full swipe marks the item used.
    @ViewBuilder
    private func swipeButtons(_ item: PantryItem) -> some View {
        usedButton(item)
        discardButton(item)
    }

    private func usedButton(_ item: PantryItem) -> some View {
        Button { Task { await change(item, to: .used) } } label: { Label("Used", systemImage: "checkmark") }
            .tint(.green)
    }

    private func discardButton(_ item: PantryItem) -> some View {
        Button { Task { await change(item, to: .discarded) } } label: { Label("Discard", systemImage: "trash") }
            .tint(.red)
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: Toolbar & undo

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showDebug = true } label: { Image(systemName: "info.circle") }
        }
        // Scan (F1.1) and Recipes (F2.1) join + when those features ship.
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(PantrySort.allCases) { Text($0.title).tag($0) }
                }
            } label: { Image(systemName: "arrow.up.arrow.down") }
            .accessibilityLabel("Sort")
            Button { showAdd = true } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add items")
        }
    }

    @ViewBuilder
    private var undoToast: some View {
        if let undo {
            HStack {
                Text(undo.message).lineLimit(1)
                Spacer()
                Button("Undo") { Task { await revert(undo) } }.fontWeight(.semibold)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: undo.id) {
                try? await Task.sleep(for: .seconds(5))
                if self.undo?.id == undo.id { withAnimation { self.undo = nil } }
            }
        }
    }

    // MARK: Actions

    private func load() async {
        do {
            items = try await PantryAPI.activeItems()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }

    /// Removes the row right away, saves, and offers Undo for 5 s.
    private func change(_ item: PantryItem, to status: PantryItem.Status) async {
        withAnimation { items.removeAll { $0.id == item.id } }
        do {
            try await PantryAPI.setStatus(item.id, status)
            withAnimation { undo = UndoAction(item: item, status: status) }
        } catch {
            actionError = error.localizedDescription
            await load()
        }
    }

    private func revert(_ action: UndoAction) async {
        withAnimation { undo = nil }
        do {
            try await PantryAPI.setStatus(action.item.id, .active)
        } catch {
            actionError = error.localizedDescription
        }
        await load()
    }
}

/// One pantry row: name, amount, optional location, expiry badge.
private struct PantryRow: View {
    enum Chevron { case collapsed, expanded }

    let name: String
    let amount: String
    let location: StorageLocation?
    let badge: ExpiryBadge
    let chevron: Chevron?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(location.map { "\(amount) · \($0.title)" } ?? amount)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            BadgeView(badge: badge)
            if let chevron {
                Image(systemName: chevron == .expanded ? "chevron.down" : "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct BadgeView: View {
    let badge: ExpiryBadge

    var body: some View {
        switch badge {
        case .later, .none:
            if let label = badge.label {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("No expiry").font(.caption).foregroundStyle(.tertiary)
            }
        default:
            Text(badge.label ?? "")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        switch badge {
        case .expired: .red
        case .today, .tomorrow: .orange
        default: .yellow
        }
    }
}
