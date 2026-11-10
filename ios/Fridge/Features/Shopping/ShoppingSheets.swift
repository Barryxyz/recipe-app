import SwiftUI

/// F3.5: bought items -> pantry. Location (default from category, as in F1.5) and the amount
/// bought; expiry comes from the F1.6 rules on the server.
struct BoughtToPantrySheet: View {
    var onDone: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row]
    @State private var saving = false
    @State private var error: String?

    struct Row: Identifiable {
        let item: ShoppingItem
        var quantity: Double?
        var unit: String
        var location: StorageLocation
        var id: UUID { item.id }
    }

    init(items: [ShoppingItem], categories: [Int64: String], onDone: @escaping (Int) -> Void) {
        self.onDone = onDone
        _rows = State(initialValue: items.map {
            Row(item: $0, quantity: $0.quantity, unit: $0.unit ?? "each",
                location: PantryDefaults.location(forCategory: $0.ingredientId.flatMap { categories[$0] }))
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach($rows) { $row in
                    Section(row.item.name) {
                        Picker("Where", selection: $row.location) {
                            ForEach(StorageLocation.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Text("Amount")
                            TextField("some", value: $row.quantity, format: .number.precision(.fractionLength(0...2)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: .infinity, minHeight: 32)
                            Picker("", selection: $row.unit) {
                                ForEach(MeasureUnit.allCases.map(\.rawValue) + (MeasureUnit(rawValue: row.unit) == nil ? [row.unit] : []),
                                        id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
            }
            .navigationTitle("Add to pantry")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Add \(rows.count)") { Task { await save() } }.fontWeight(.semibold).disabled(rows.isEmpty)
                    }
                }
            }
            .alert("Couldn't add to your pantry", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let n = try await ShoppingAPI.moveToPantry(rows.map {
                .init(id: $0.id, location: $0.location.rawValue, quantity: $0.quantity, unit: $0.unit)
            })
            onDone(n)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// F3.5: "Add missing to shopping list" preview: each line with a checkbox.
struct AddMissingSheet: View {
    let recipe: RecipeAPI.Recipe
    let lines: [ShoppingPlan.Line]
    let conversions: [Int64: CookedThis.Conversion]
    var onAdded: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int>
    @State private var saving = false
    @State private var error: String?

    init(recipe: RecipeAPI.Recipe, lines: [ShoppingPlan.Line], conversions: [Int64: CookedThis.Conversion],
         onAdded: @escaping (Int) -> Void) {
        self.recipe = recipe
        self.lines = lines
        self.conversions = conversions
        self.onAdded = onAdded
        _selected = State(initialValue: Set(lines.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(lines) { line in
                        Button {
                            if selected.contains(line.id) { selected.remove(line.id) } else { selected.insert(line.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(line.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selected.contains(line.id) ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.name).foregroundStyle(.primary)
                                    if line.isShortfall {
                                        Text("You have some, but not enough").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(line.quantity == nil ? "" : MacroFormat.amount(line.quantity, unit: line.unit == "each" ? nil : line.unit))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Items already on your list get the amounts added instead of a second row.")
                }
            }
            .navigationTitle("Add to shopping list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Add \(selected.count)") { Task { await add() } }
                            .fontWeight(.semibold).disabled(selected.isEmpty)
                    }
                }
            }
            .alert("Couldn't add to the list", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func add() async {
        saving = true
        defer { saving = false }
        do {
            let existing = try await ShoppingAPI.list()
            let adds = ShoppingPlan.adds(lines.filter { selected.contains($0.id) }, existing: existing,
                                         recipeId: UUID(uuidString: recipe.temp_id), recipeTitle: recipe.title,
                                         conversions: conversions)
            try await ShoppingAPI.add(adds)
            onAdded(adds.count)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
