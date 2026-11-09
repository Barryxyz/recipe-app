import SwiftUI

/// F2.4: one recipe. Ingredients marked pantry / staple / missing, steps large enough to cook
/// from, and the screen stays on while it's open.
struct RecipeDetailView: View {
    let recipe: RecipeAPI.Recipe
    @State private var showTotal = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(recipe.title).font(.title2.bold())
                    Text(recipe.description).foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Label("\(recipe.servings) serving\(recipe.servings == 1 ? "" : "s")", systemImage: "person.2")
                        Label("Prep \(MacroFormat.minutes(recipe.prep_min))", systemImage: "knife")
                        Label("Cook \(MacroFormat.minutes(recipe.cook_min))", systemImage: "frying.pan")
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                macros
            } header: {
                Picker("", selection: $showTotal) {
                    Text("Per serving").tag(false)
                    Text("Total").tag(true)
                }
                .pickerStyle(.segmented)
                .textCase(nil)
            } footer: {
                Text(macroFootnote)
            }

            Section("Ingredients") {
                ForEach(recipe.ingredients) { ingredientRow($0) }
            }

            Section("Steps") {
                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(i + 1)").font(.title3.bold()).foregroundStyle(Color.accentColor).frame(minWidth: 24)
                        Text(step).font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                }
            }

            Section {
                Label("AI-generated. Check that meat, poultry, fish and eggs reach safe temperatures.",
                      systemImage: "exclamationmark.shield")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var shown: RecipeAPI.Macros { showTotal ? recipe.macros_total : recipe.macros_per_serving }

    private var macros: some View {
        let m = shown, p = MacroFormat.prefix(m)
        return HStack {
            stat("\(p)\(MacroFormat.kcal(m.kcal))", "kcal")
            stat("\(p)\(MacroFormat.grams(m.protein_g)) g", "protein")
            stat("\(p)\(MacroFormat.grams(m.carbs_g)) g", "carbs")
            stat("\(p)\(MacroFormat.grams(m.fat_g)) g", "fat")
        }
    }

    private var macroFootnote: String {
        (shown.estimated ? "Some values estimated. " : "") + "Nutrition is approximate."
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func ingredientRow(_ ing: RecipeAPI.Ingredient) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            switch ing.kind {
            case .pantry: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .staple: Image(systemName: "circle").foregroundStyle(.secondary)
            case .missing: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(amount(ing)).monospacedDigit().foregroundStyle(.secondary)
                    Text(ing.name).italic(ing.is_optional)
                    if ing.is_optional { Text("optional").font(.caption).foregroundStyle(.secondary) }
                }
                if let note = ing.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if ing.kind == .missing {
                Text("Missing").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(ing.kind == .pantry ? "In your pantry" : ing.kind == .staple ? "Staple" : "You need to buy this")
    }

    private func amount(_ ing: RecipeAPI.Ingredient) -> String {
        MacroFormat.amount(ing.quantity, unit: ing.unit)
    }
}

extension RecipeAPI.Recipe: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(temp_id); hasher.combine(title) }
}
