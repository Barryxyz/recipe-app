import SwiftUI

/// F3.4: review what the recipe used, then reduce the pantry in one go.
struct CookedThisView: View {
    let recipe: RecipeAPI.Recipe
    /// Called after the pantry was updated, with what Undo needs.
    var onApplied: ([CookedAPI.Snapshot]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var servings: Int
    @State private var pantry: [PantryItem] = []
    @State private var conversions: [Int64: CookedThis.Conversion] = [:]
    @State private var rows: [CookedThis.Row] = []
    @State private var loading = true
    @State private var applying = false
    @State private var error: String?

    init(recipe: RecipeAPI.Recipe, onApplied: @escaping ([CookedAPI.Snapshot]) -> Void) {
        self.recipe = recipe
        self.onApplied = onApplied
        _servings = State(initialValue: max(1, recipe.servings))
    }

    private var changes: [CookedThis.Change] { CookedThis.changes(rows, conversions: conversions) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $servings, in: 1...24) { Text("Servings cooked: \(servings)") }
                        .onChange(of: servings) { _, _ in rebuild(keepModes: true) }
                }
                if loading {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                } else if rows.isEmpty {
                    Section {
                        Text("None of this recipe's ingredients are in your pantry, so there's nothing to update.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach($rows) { $row in CookedRowView(row: $row, conversions: conversions) }
                    } footer: {
                        Text("Staples, optional ingredients and items without an amount are skipped unless you change them.")
                    }
                }
            }
            .navigationTitle("Cooked this")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if applying { ProgressView() } else {
                        Button("Update pantry") { Task { await apply() } }
                            .fontWeight(.semibold)
                            .disabled(loading || changes.isEmpty)
                    }
                }
            }
            .alert("Couldn't update the pantry", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
            .task { await load() }
        }
    }

    private func load() async {
        do {
            pantry = try await PantryAPI.activeItems()
            let ids = recipe.ingredients.compactMap(\.ingredient_id) + pantry.compactMap(\.ingredientId)
            conversions = (try? await CookedAPI.conversions(ids)) ?? [:]
            rebuild(keepModes: false)
        } catch {
            self.error = "Couldn't load your pantry. Check your connection and try again."
        }
        loading = false
    }

    /// Recalculates amounts for the servings cooked; the user's choice of action is kept.
    private func rebuild(keepModes: Bool) {
        let previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        rows = CookedThis.rows(for: recipe, servings: servings, pantry: pantry, conversions: conversions).map { row in
            guard keepModes, let old = previous[row.id] else { return row }
            var r = row
            r.mode = old.mode
            switch old.mode {
            case .setLeft: r.amount = old.amount                  // typed by the user
            case .subtract: r.amount = row.convertedAmount ?? old.amount
            default: break
            }
            return r
        }
    }

    private func apply() async {
        applying = true
        defer { applying = false }
        do {
            let snapshot = try await CookedAPI.apply(changes)
            onApplied(snapshot)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct CookedRowView: View {
    @Binding var row: CookedThis.Row
    let conversions: [Int64: CookedThis.Conversion]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.headline)
                    Text(recipeAmount).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Picker("Action", selection: $row.mode) {
                        ForEach(row.modes) { Text(title($0)).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(title(row.mode))
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.subheadline.weight(.medium))
                }
            }

            if row.mode == .subtract || row.mode == .setLeft {
                HStack {
                    Text(row.mode == .subtract ? "Use" : "Left")
                    TextField(row.mode == .subtract ? "amount" : "how much is left", value: $row.amount,
                              format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, minHeight: 30)
                    Text(row.unit == "each" ? "" : row.unit).foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }

            ForEach(CookedThis.effects(row, conversions: conversions), id: \.item.id) { e in
                Text(effectText(e)).font(.subheadline).foregroundStyle(e.usedUp ? .orange : .secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(row.mode == .skip ? 0.55 : 1)
        .onChange(of: row.mode) { _, mode in
            switch mode {
            case .subtract: row.amount = row.convertedAmount ?? row.amount
            case .setLeft: row.amount = nil
            default: break
            }
        }
    }

    private var recipeAmount: String {
        var parts: [String] = []
        if let q = row.recipeQuantity {
            parts.append("Recipe: " + MacroFormat.amount(q, unit: row.recipeUnit))
        } else {
            parts.append("Recipe: some")
        }
        let have = row.items.map { MacroFormat.amount($0.quantity, unit: $0.unit).nilIfEmpty ?? "some" }
        parts.append("You have " + have.joined(separator: " + "))
        if row.isStaple { parts.append("staple") }
        if row.isOptional { parts.append("optional") }
        return parts.joined(separator: " · ")
    }

    private func title(_ m: CookedThis.Mode) -> String {
        switch m {
        case .subtract: "Subtract"
        case .usedUp: "Used it up"
        case .skip: row.isSome ? "Still have some" : "Skip"
        case .setLeft: "Set what's left"
        }
    }

    private func effectText(_ e: CookedThis.Effect) -> String {
        let before = MacroFormat.amount(e.item.quantity, unit: e.item.unit).nilIfEmpty ?? "some"
        if e.usedUp { return "\(e.item.displayName): \(before) → used up" }
        return "\(e.item.displayName): \(before) → \(MacroFormat.amount(e.after, unit: e.item.unit))"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
