import SwiftUI

/// F3.5: the Shopping tab. To buy by store aisle, Bought (collapsed) with Add to pantry.
struct ShoppingListView: View {
    @State private var items: [ShoppingItem] = []
    @State private var categories: [Int64: String] = [:]
    @State private var loaded = false
    @State private var newName = ""
    @State private var suggestions: [IngredientChoice] = []
    @State private var adding = false
    @State private var showBought = false
    @State private var editing: ShoppingItem?
    @State private var movingToPantry = false
    @State private var confirmClear = false
    @State private var toast: String?
    @State private var error: String?
    @FocusState private var addFocused: Bool

    private var bought: [ShoppingItem] { items.filter(\.checked) }

    var body: some View {
        NavigationStack {
            List {
                addSection

                if !loaded {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                } else if items.isEmpty {
                    Section {
                        ContentUnavailableView("Your list is empty", systemImage: "cart",
                                               description: Text("Add items above, or tap Add missing to shopping list on a recipe."))
                    }
                } else {
                    ForEach(ShoppingPlan.toBuy(items, categories: categories), id: \.0) { aisle, rows in
                        Section(aisle.title) {
                            ForEach(rows) { row($0) }
                                .onDelete { idx in Task { await delete(idx.map { rows[$0].id }) } }
                        }
                    }
                    if !bought.isEmpty { boughtSection }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Shopping")
            .refreshable { await load() }
            .task { await load() }
            .overlay(alignment: .bottom) { toastView }
            .sheet(item: $editing) { item in
                ShoppingItemEditSheet(item: item) { q, u in Task { await update(item, quantity: q, unit: u) } }
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $movingToPantry) {
                BoughtToPantrySheet(items: bought, categories: categories) { n in
                    Task {
                        await load()
                        show("\(n) item\(n == 1 ? "" : "s") added to your pantry")
                    }
                }
            }
            .confirmationDialog("Clear bought items?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear \(bought.count) item\(bought.count == 1 ? "" : "s")", role: .destructive) {
                    Task { await delete(bought.map(\.id)) }
                }
            } message: {
                Text("They're removed from the list without being added to your pantry.")
            }
            .alert("Something went wrong", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    // MARK: Add

    private var addSection: some View {
        Section {
            HStack {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                TextField("Add an item", text: $newName)
                    .focused($addFocused)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await addTyped() } }
                    .onChange(of: newName) { _, q in Task { await search(q) } }
                if adding { ProgressView() }
            }
            if addFocused {
                ForEach(suggestions) { s in
                    Button { Task { await add(name: s.name, ingredientId: s.id) } } label: {
                        HStack {
                            Text(s.name).foregroundStyle(.primary)
                            Spacer()
                            if s.isCustom { Text("your item").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
    }

    private func search(_ q: String) async {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { suggestions = []; return }
        let found = (try? await PantryAPI.search(query, limit: 5)) ?? []
        if newName == q { suggestions = found }
    }

    /// Return: a close catalog match is linked; anything else is kept as typed.
    private func addTyped() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let match = try? await RecipeCreator.match(name)
        await add(name: match?.name ?? name, ingredientId: match?.id)
    }

    private func add(name: String, ingredientId: Int64?) async {
        adding = true
        defer { adding = false }
        let line = ShoppingPlan.Line(id: 0, ingredientId: ingredientId, name: name, quantity: nil, unit: nil, isShortfall: false)
        let adds = ShoppingPlan.adds([line], existing: items, recipeId: nil, recipeTitle: nil, conversions: [:])
        if adds.first?.merge_id != nil {
            show("\(name) is already on your list")
        } else {
            do { try await ShoppingAPI.add(adds) } catch { self.error = "Couldn't add \(name)." ; return }
            Events.log(.shoppingItemsAdded, ["from": "manual", "count": 1, "linked": .bool(ingredientId != nil)])
        }
        newName = ""
        suggestions = []
        addFocused = true                       // ready for the next item
        await load()
    }

    // MARK: Rows

    private func row(_ item: ShoppingItem) -> some View {
        HStack(spacing: 12) {
            Button { Task { await toggle(item) } } label: {
                Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.checked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.checked ? "Mark as not bought" : "Mark as bought")

            Button { editing = item } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).strikethrough(item.checked).foregroundStyle(item.checked ? .secondary : .primary)
                        if let title = item.sourceRecipeTitle {
                            Text("for \(title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(amount(item)).monospacedDigit().foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func amount(_ item: ShoppingItem) -> String {
        guard item.quantity != nil else { return "" }
        let u = item.unit == "each" ? nil : item.unit
        return MacroFormat.amount(item.quantity, unit: u)
    }

    private var boughtSection: some View {
        Section {
            if showBought {
                ForEach(bought) { row($0) }
                    .onDelete { idx in Task { await delete(idx.map { bought[$0].id }) } }
                Button(role: .destructive) { confirmClear = true } label: { Label("Clear bought", systemImage: "trash") }
            }
        } header: {
            HStack {
                Button { withAnimation { showBought.toggle() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showBought ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold))
                        Text("Bought (\(bought.count))")
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Button(Connectivity.shared.isOnline ? "Add to pantry (\(bought.count))" : "Add to pantry needs internet") {
                    movingToPantry = true
                }
                .needsInternet()
                    .font(.footnote.weight(.semibold))
                    .textCase(nil)
            }
        }
    }

    // MARK: Actions

    private func load() async {
        do {
            items = try await ShoppingAPI.list()
            let ids = items.compactMap(\.ingredientId).filter { categories[$0] == nil }
            if !ids.isEmpty, let found = try? await ShoppingAPI.categories(ids) { categories.merge(found) { $1 } }
        } catch {
            if !loaded { self.error = "Couldn't load your shopping list. Pull down to try again." }
        }
        loaded = true
    }

    private func toggle(_ item: ShoppingItem) async {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        withAnimation { items[i].checked.toggle() }
        ShoppingBadge.shared.set(items.filter { !$0.checked }.count)
        do { try await ShoppingAPI.setChecked(item.id, items[i].checked) } catch { await load() }
    }

    private func update(_ item: ShoppingItem, quantity: Double?, unit: String?) async {
        do { try await ShoppingAPI.update(item.id, quantity: quantity, unit: unit) } catch { self.error = "Couldn't save the change." }
        await load()
    }

    private func delete(_ ids: [UUID]) async {
        withAnimation { items.removeAll { ids.contains($0.id) } }
        do { try await ShoppingAPI.delete(ids) } catch { self.error = "Couldn't delete." }
        await load()
    }

    // MARK: Toast

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toast == text { withAnimation { toast = nil } }
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Tap a row: change the amount and unit.
struct ShoppingItemEditSheet: View {
    let item: ShoppingItem
    var onSave: (Double?, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var quantity: Double?
    @State private var unit: String
    @FocusState private var amountFocused: Bool

    init(item: ShoppingItem, onSave: @escaping (Double?, String?) -> Void) {
        self.item = item
        self.onSave = onSave
        _quantity = State(initialValue: item.quantity)
        _unit = State(initialValue: item.unit ?? "each")
    }

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    Text("Amount")
                    TextField("some", value: $quantity, format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .focused($amountFocused)
                }
                .contentShape(Rectangle())
                .onTapGesture { amountFocused = true }
                Picker("Unit", selection: $unit) {
                    ForEach(MeasureUnit.allCases.map(\.rawValue) + (MeasureUnit(rawValue: unit) == nil ? [unit] : []), id: \.self) {
                        Text($0).tag($0)
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(quantity, quantity == nil ? nil : unit); dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }
}
