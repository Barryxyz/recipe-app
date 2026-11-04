import SwiftUI

/// F1.5: the add sheet (search, recent chips, Add & next) and the edit sheet (same form plus
/// Mark used / Discard / Delete). No AI calls.
struct ItemFormView: View {
    enum Mode: Equatable {
        case add
        case edit(PantryItem)
    }

    let mode: Mode
    /// Called after anything is saved, so the list can refresh.
    var onChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var draft = ItemDraft()
    @State private var query = ""
    @State private var results: [IngredientChoice] = []
    @State private var recent: [IngredientChoice] = []
    @State private var isSearching = false
    @State private var changingIngredient = false

    @State private var shelfLife: CatalogShelfLife?
    @State private var userDefaults: [ExpiryCalculator.DefaultKey: Int] = [:]

    @State private var sessionLocation: StorageLocation?
    @State private var addedCount = 0
    @State private var lastAdded: String?

    @State private var showExpiryEditor = false
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var confirmZeroQuantity = false
    @State private var confirmDelete = false
    @State private var updateExisting: (ids: [UUID], name: String)?

    @FocusState private var searchFocused: Bool

    private var isAdd: Bool { mode == .add }
    private var editingItem: PantryItem? { if case .edit(let item) = mode { item } else { nil } }
    private var addedAt: Date { editingItem?.addedAt ?? .now }
    private var showSearch: Bool { draft.ingredient == nil || changingIngredient }

    var body: some View {
        NavigationStack {
            Form {
                if showSearch { searchSection }
                if draft.ingredient != nil && !changingIngredient { detailsSection }
                if let editingItem { editActions(editingItem) }
                if isAdd, let lastAdded { addedSection(lastAdded) }
            }
            .navigationTitle(isAdd ? "Add items" : "Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .disabled(saving)
            .task { await loadInitial() }
            .task(id: query) { await runSearch() }
            .task(id: draft.ingredient?.id) { await loadShelfLife() }
            .sheet(isPresented: $showExpiryEditor) { expiryEditor }
            .alert("Something went wrong", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: { Text(errorMessage ?? "") })
            .confirmationDialog("Quantity is 0. Mark it used?", isPresented: $confirmZeroQuantity, titleVisibility: .visible) {
                Button("Mark used") { Task { await setStatus(.used) } }
                Button("Keep at 0") { Task { await saveEdit(force: true) } }
            }
            .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await deleteItem() } }
            } message: {
                Text("For mistakes. To record that you finished or threw it out, use Mark used or Discard.")
            }
            .alert("Update existing items?", isPresented: .constant(updateExisting != nil), presenting: updateExisting) { pending in
                Button("Also update \(pending.ids.count) existing") { Task { await recalc(pending.ids) } }
                Button("Only new items", role: .cancel) { updateExisting = nil }
            } message: { pending in
                Text("The new default applies to \(pending.name) added from now on. \(pending.ids.count) item(s) you already have still use the old date.")
            }
        }
        .presentationDetents([.large])
    }

    // MARK: Search

    private var searchSection: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search ingredients…", text: $query)
                    .focused($searchFocused)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if isSearching { ProgressView() }
            }

            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if !recent.isEmpty { recentChips }
            } else {
                ForEach(results) { choice in
                    Button { pick(choice) } label: { resultRow(choice) }
                }
                Button {
                    Task { await addCustom(trimmed) }
                } label: {
                    Label("Add \u{201C}\(trimmed)\u{201D} as custom item", systemImage: "plus.circle")
                }
            }
            if changingIngredient {
                Button("Keep \(draft.ingredient?.name ?? "current")") { changingIngredient = false; query = "" }
            }
        }
    }

    private var recentChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(recent) { choice in
                        Button(choice.name) { pick(choice) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func resultRow(_ choice: IngredientChoice) -> some View {
        HStack {
            Image(systemName: CategoryIcon.symbol(for: choice))
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading) {
                Text(choice.name).foregroundStyle(.primary)
                Text(choice.isCustom ? "Your item" : (choice.category ?? "").capitalized)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Details

    private var detailsSection: some View {
        Section {
            HStack {
                Text(draft.ingredient?.name ?? "").font(.headline)
                Spacer()
                Button("Change") { changingIngredient = true; searchFocused = true }
                    .font(.subheadline)
            }

            Toggle("Some (no exact amount)", isOn: Binding(get: { draft.isSome }, set: { draft.setSome($0) }))

            if !draft.isSome {
                HStack {
                    Button { draft.decrement() } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless)
                    TextField("Qty", value: Binding(get: { draft.quantity ?? 0 }, set: { draft.quantity = $0 }),
                              format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .frame(width: 70)
                    Button { draft.increment() } label: { Image(systemName: "plus.circle.fill") }
                        .buttonStyle(.borderless)
                    Spacer()
                    Picker("Unit", selection: $draft.unit) {
                        ForEach(MeasureUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
                .font(.title3)
            }

            Picker("Location", selection: $draft.location) {
                ForEach(StorageLocation.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: draft.location) { _, new in if isAdd { sessionLocation = new } }

            Button { showExpiryEditor = true } label: {
                HStack {
                    Text("Expires").foregroundStyle(.primary)
                    Spacer()
                    Text(expiryText).foregroundStyle(.secondary)
                    Image(systemName: "pencil").foregroundStyle(.tint)
                }
            }
        }
    }

    private var previewExpiry: Date? {
        if draft.expiryOverridden { return draft.chosenExpiry }
        let calc = ExpiryCalculator(timeZone: .current, userDefaults: userDefaults, catalog: { _ in shelfLife })
        return calc.defaultExpiry(ingredientId: draft.ingredient?.id, location: draft.location, addedAt: addedAt)
    }

    private var expiryText: String {
        guard let date = previewExpiry else { return "No expiry" }
        let suffix = draft.expiryOverridden ? " (set by you)" : ""
        return date.formatted(.dateTime.month(.abbreviated).day().year()) + suffix
    }

    // MARK: Expiry editor

    private var expiryEditor: some View {
        ExpiryEditor(
            ingredientName: draft.ingredient?.name ?? "this item",
            location: draft.location,
            addedAt: addedAt,
            initial: previewExpiry ?? Calendar.current.date(byAdding: .day, value: 7, to: .now)!,
            isOverridden: draft.expiryOverridden,
            onSave: { date, alwaysUse in Task { await applyExpiry(date, alwaysUse: alwaysUse) } },
            onNoExpiry: { draft.overrideExpiry(nil) },
            onUseDefault: { draft.chosenExpiry = nil; draft.expiryOverridden = false }
        )
    }

    // MARK: Edit actions

    private func editActions(_ item: PantryItem) -> some View {
        Section {
            Button { Task { await setStatus(.used) } } label: { Label("Mark used", systemImage: "checkmark.circle") }
            Button { Task { await setStatus(.discarded) } } label: { Label("Discard", systemImage: "trash.slash") }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func addedSection(_ name: String) -> some View {
        Section {
            Label("Added \(name) · \(addedCount) added", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(isAdd && addedCount > 0 ? "Close" : "Cancel") { dismiss() }
        }
        if isAdd {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { Task { await done() } }
            }
            ToolbarItem(placement: .bottomBar) {
                Button { Task { await addAndNext() } } label: {
                    Label("Add & next", systemImage: "plus").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!draft.canAdd || changingIngredient)
            }
        } else {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await saveEdit(force: false) } }
                    .disabled(!draft.canSaveEdit || changingIngredient)
            }
        }
    }

    // MARK: Actions

    private func loadInitial() async {
        async let defaults = try? PantryAPI.userDefaults()
        if let item = editingItem {
            let choice = (try? await PantryAPI.choice(for: item))
                ?? IngredientChoice(id: item.ingredientId ?? 0, name: item.displayName, category: nil,
                                    defaultUnit: item.unit, isCustom: true)
            draft = ItemDraft(ingredient: choice, quantity: item.quantity,
                              unit: MeasureUnit(catalogUnit: item.unit), location: item.location,
                              chosenExpiry: item.expiryOverridden ? item.expiresAt : nil,
                              expiryOverridden: item.expiryOverridden)
        } else {
            recent = (try? await PantryAPI.recentIngredients()) ?? []
            searchFocused = true
        }
        userDefaults = await defaults ?? [:]
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; return }
        try? await Task.sleep(for: .milliseconds(200))   // debounce
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        if let found = try? await PantryAPI.search(q) , !Task.isCancelled {
            results = found
        }
    }

    private func loadShelfLife() async {
        guard let id = draft.ingredient?.id else { shelfLife = nil; return }
        shelfLife = try? await PantryAPI.shelfLife(for: id)
    }

    private func pick(_ choice: IngredientChoice) {
        if changingIngredient {
            // Keep amounts and location; the server recalculates the date for the new ingredient.
            draft.ingredient = choice
            if !draft.expiryOverridden { draft.chosenExpiry = nil }
            changingIngredient = false
        } else {
            draft.pick(choice, sessionLocation: sessionLocation)
        }
        query = ""
        results = []
        searchFocused = false
    }

    private func addCustom(_ name: String) async {
        do {
            pick(try await PantryAPI.customIngredient(named: name))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyExpiry(_ date: Date, alwaysUse: Bool) async {
        let endOfDay = ItemDraft.endOfDay(date, in: .current)
        guard alwaysUse, let ingredient = draft.ingredient else {
            draft.overrideExpiry(endOfDay)
            return
        }
        let days = ItemDraft.days(from: addedAt, to: endOfDay, in: .current)
        do {
            try await PantryAPI.saveDefault(ingredientId: ingredient.id, location: draft.location, days: days)
            userDefaults[.init(ingredientId: ingredient.id, location: draft.location)] = days
            draft.chosenExpiry = nil
            draft.expiryOverridden = false
            let others = try await PantryAPI.itemsUsingDefault(ingredientId: ingredient.id, location: draft.location,
                                                                excluding: editingItem?.id)
            if !others.isEmpty { updateExisting = (others, ingredient.name) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func recalc(_ ids: [UUID]) async {
        updateExisting = nil
        do {
            try await PantryAPI.recalculateExpiry(ids)
            onChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func saveNew() async -> Bool {
        guard draft.canAdd else { return false }
        saving = true
        defer { saving = false }
        do {
            _ = try await PantryAPI.add(draft)
            addedCount += 1
            lastAdded = draft.ingredient?.name
            onChange()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func addAndNext() async {
        guard await saveNew() else { return }
        sessionLocation = draft.location
        draft = ItemDraft()
        query = ""
        recent = (try? await PantryAPI.recentIngredients()) ?? recent
        searchFocused = true
    }

    private func done() async {
        if draft.canAdd && !changingIngredient {
            guard await saveNew() else { return }
        }
        dismiss()
    }

    private func saveEdit(force: Bool) async {
        guard let item = editingItem else { return }
        if !force, draft.quantity == 0 { confirmZeroQuantity = true; return }
        saving = true
        defer { saving = false }
        do {
            _ = try await PantryAPI.update(item.id, with: draft)
            onChange()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setStatus(_ status: PantryItem.Status) async {
        guard let item = editingItem else { return }
        do {
            try await PantryAPI.setStatus(item.id, status)
            onChange()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteItem() async {
        guard let item = editingItem else { return }
        do {
            try await PantryAPI.delete(item.id)
            onChange()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Date picker for an item's expiry, with "Always use N days for <ingredient>" (F1.6).
private struct ExpiryEditor: View {
    let ingredientName: String
    let location: StorageLocation
    let addedAt: Date
    let initial: Date
    let isOverridden: Bool
    let onSave: (Date, Bool) -> Void
    let onNoExpiry: () -> Void
    let onUseDefault: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var alwaysUse = false

    private var days: Int { ItemDraft.days(from: addedAt, to: date, in: .current) }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Expires", selection: $date, in: Calendar.current.startOfDay(for: addedAt)..., displayedComponents: .date)
                    .datePickerStyle(.graphical)
                Toggle("Always use \(days) day\(days == 1 ? "" : "s") for \(ingredientName) in the \(location.title.lowercased())",
                       isOn: $alwaysUse)
                Section {
                    Button("No expiry date") { onNoExpiry(); dismiss() }
                    if isOverridden {
                        Button("Use the default date") { onUseDefault(); dismiss() }
                    }
                }
            }
            .navigationTitle("Expiry date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(date, alwaysUse); dismiss() }
                }
            }
            .onAppear { date = initial }
        }
        .presentationDetents([.large])
    }
}

/// SF Symbol per catalog category (search results).
enum CategoryIcon {
    static func symbol(for choice: IngredientChoice) -> String {
        if choice.isCustom { return "person.crop.circle" }
        switch choice.category {
        case "produce": return "leaf"
        case "frozen": return "snowflake"
        case "dairy": return "drop"
        case "meat": return "fork.knife"
        case "seafood": return "fish"
        case "protein": return "square.stack.3d.up"
        case "bakery": return "birthday.cake"
        case "grains": return "takeoutbag.and.cup.and.straw"
        case "baking": return "scalemass"
        case "spices": return "sparkles"
        case "oils": return "drop.triangle"
        case "condiments": return "takeoutbag.and.cup.and.straw.fill"
        case "canned": return "cylinder"
        case "nuts": return "circle.hexagongrid"
        case "drinks": return "cup.and.saucer"
        default: return "circle"
        }
    }
}
