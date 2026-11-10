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
    @State private var confirmDiscardExpired: [PantryItem]?

    @State private var showAdd = false
    @State private var editing: PantryItem?
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showScan = false
    @State private var notice: String?
    @State private var pendingReview: ScanReview?
    @State private var resumingReview: ScanReview?
    @State private var undo: UndoAction?
    @State private var actionError: String?

    private struct UndoAction: Equatable {
        let items: [PantryItem]
        let status: PantryItem.Status
        let id = UUID()
        var message: String {
            let what = items.count == 1 ? items[0].displayName : "\(items.count) items"
            return "\(what) \(status == .used ? "marked used" : "discarded")"
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Pantry")
                .toolbar { toolbar }
                .searchable(text: $search, prompt: "Search your pantry")
                .refreshable { await load() }
                .task { await load() }
                // A tapped expiry reminder (F5.1): All, with Use these first open.
                .onChange(of: ExpiryReminders.shared.openPantryRequest) { _, _ in
                    search = ""
                    tab = .all
                    useFirstExpanded = true
                    Task { await load() }
                }
                .sheet(isPresented: $showAdd) { ItemFormView(mode: .add) { Task { await load() } } }
                .sheet(item: $editing) { item in ItemFormView(mode: .edit(item)) { Task { await load() } } }
                .sheet(isPresented: $showSettings) { SettingsView(user: user) }
                .sheet(isPresented: $showHistory) { HistoryView { Task { await load() } } }
                .fullScreenCover(isPresented: $showScan) {
                    ScanView(onAddManually: { Task { try? await Task.sleep(for: .milliseconds(400)); showAdd = true } },
                             onSaved: { n in savedFromScan(n) })
                }
                .fullScreenCover(item: $resumingReview) { draft in
                    NavigationStack {
                        ScanReviewView(review: draft,
                                       onSaved: { n in resumingReview = nil; savedFromScan(n) },
                                       onDiscard: { resumingReview = nil },
                                       onRetake: nil,
                                       onAddManually: { resumingReview = nil; showAdd = true })
                    }
                }
                .alert("Finish reviewing your last scan?", isPresented: Binding(
                    get: { pendingReview != nil }, set: { if !$0 { pendingReview = nil } })) {
                    Button("Review") { resumingReview = pendingReview; pendingReview = nil }
                    Button("Discard", role: .destructive) { ScanReview.clearDraft(); pendingReview = nil }
                } message: {
                    Text("\(pendingReview?.rows.count ?? 0) items are waiting. Nothing has been added to your pantry yet.")
                }
                .task {
                    // A review left unfinished (e.g. the app was closed) can be resumed (F1.3).
                    if !showScan, let draft = ScanReview.loadDraft() { pendingReview = draft }
                }
                .overlay(alignment: .bottom) { undoToast }
                .confirmationDialog(
                    "Discard \(confirmDiscardExpired?.count ?? 0) expired item\(confirmDiscardExpired?.count == 1 ? "" : "s")?",
                    isPresented: Binding(get: { confirmDiscardExpired != nil }, set: { if !$0 { confirmDiscardExpired = nil } }),
                    titleVisibility: .visible
                ) {
                    Button("Discard all", role: .destructive) {
                        if let list = confirmDiscardExpired { Task { await change(list, to: .discarded) } }
                        confirmDiscardExpired = nil
                    }
                } message: {
                    Text("They'll be marked as thrown out. You can undo right after.")
                }
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
            // Both ways to add, equally weighted (F1.4).
            ContentUnavailableView {
                Label("Your pantry is empty", systemImage: "refrigerator")
            } description: {
                Text("Add what's in your fridge, freezer and cupboards.")
            } actions: {
                HStack {
                    Button { showScan = true } label: {
                        Label("Scan your fridge", systemImage: "camera").frame(maxWidth: .infinity)
                    }
                    Button { showAdd = true } label: {
                        Label("Add manually", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
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
                Text("\(loc.title) \(items.filter { $0.location == loc && !$0.isStaple }.count)").tag(Tab.location(loc))
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
                let parts = PantryGrouping.sections(items)
                expiredSection(parts.expired)
                let groups = PantryGrouping.groups(parts.regular, sort: sort)
                let soon = groups.filter { $0.badge().isUseSoon }
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
                    let rest = groups.filter { $0.location == loc && !$0.badge().isUseSoon }
                    if !rest.isEmpty {
                        Section(loc.title) { rows(rest, showLocation: false) }
                    }
                }
                staplesSection(parts.staples)
            case .location(let loc):
                // Staples have their own place (bottom of All), not a location tab.
                let here = items.filter { $0.location == loc && !$0.isStaple }
                let parts = PantryGrouping.sections(here)
                if here.isEmpty {
                    Text("Nothing in the \(loc.title.lowercased()) yet.").foregroundStyle(.secondary)
                } else {
                    expiredSection(parts.expired)
                    let groups = PantryGrouping.groups(parts.regular, sort: sort)
                    if !groups.isEmpty { Section { rows(groups, showLocation: false) } }
                }
            }
        }
    }

    /// Seasonings & Staples: its own place, last on All since it's checked least. A–Z, no badges
    /// unless dated.
    @ViewBuilder
    private func staplesSection(_ staples: [PantryItem]) -> some View {
        if !staples.isEmpty {
            Section("Seasonings & Staples (\(staples.count))") {
                rows(PantryGrouping.groups(staples, sort: .name), showLocation: false)
            }
        }
    }

    /// Shown only when something has expired. "Discard all" asks first and can be undone.
    @ViewBuilder
    private func expiredSection(_ expired: [PantryItem]) -> some View {
        if !expired.isEmpty {
            Section {
                rows(PantryGrouping.groups(expired, sort: sort), showLocation: tab == .all)
            } header: {
                HStack {
                    Text("Expired (\(expired.count))").foregroundStyle(.red)
                    Spacer()
                    Button("Discard all") { confirmDiscardExpired = expired }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                        .textCase(nil)
                }
            } footer: {
                Text("Still good? Tap an item to change its date.")
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
                              place: showLocation ? (group.earliest.isStaple ? "Staples" : group.location.title) : nil,
                              badge: group.badge(),
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
                      place: showLocation ? (item.isStaple ? "Staples" : item.location.title) : nil,
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
            HStack {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
                Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .accessibilityLabel("History")
            }
        }
        // Recipes (F2.1) joins these when it ships.
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(PantrySort.allCases) { Text($0.title).tag($0) }
                }
            } label: { Image(systemName: "arrow.up.arrow.down") }
            .accessibilityLabel("Sort")
            Button { showScan = true } label: { Image(systemName: "camera") }
                .accessibilityLabel("Scan")
            Button { showAdd = true } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add items")
        }
    }

    @ViewBuilder
    private var undoToast: some View {
        if let notice {
            Label(notice, systemImage: "checkmark.circle.fill")
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { self.notice = nil }
                }
        } else if let undo {
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

    private func savedFromScan(_ count: Int) {
        Task { await load() }
        withAnimation { notice = "\(count) item\(count == 1 ? "" : "s") added" }
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

    private func change(_ item: PantryItem, to status: PantryItem.Status) async {
        await change([item], to: status)
    }

    /// Removes the rows right away, saves, and offers Undo for 5 s.
    private func change(_ list: [PantryItem], to status: PantryItem.Status) async {
        let ids = Set(list.map(\.id))
        withAnimation { items.removeAll { ids.contains($0.id) } }
        do {
            try await PantryAPI.setStatus(Array(ids), status)
            withAnimation { undo = UndoAction(items: list, status: status) }
        } catch {
            actionError = error.localizedDescription
            await load()
        }
    }

    private func revert(_ action: UndoAction) async {
        withAnimation { undo = nil }
        do {
            try await PantryAPI.setStatus(action.items.map(\.id), .active)
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
    /// "Fridge", "Staples"… shown in mixed lists (search, Use these first, Expired).
    let place: String?
    let badge: ExpiryBadge
    let chevron: Chevron?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(place.map { "\(amount) · \($0)" } ?? amount)
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
