import SwiftUI

/// F2.4: one recipe. Ingredients marked pantry / staple / missing, steps large enough to cook
/// from, and the screen stays on while it's open.
struct RecipeDetailView: View {
    let recipe: RecipeAPI.Recipe
    /// Save / unsave (F3.1). Nil hides the button.
    var initiallySaved = false
    var onSave: (() async throws -> Void)? = nil
    var onUnsave: (() async throws -> Void)? = nil
    /// Saved recipes: Edit (F3.2) and the state of the nutrition recalculation.
    var onEdit: (() -> Void)? = nil
    var macroStatus: MacroStatus? = nil
    /// The user's own recipes (F3.7) have no AI disclaimer.
    var isAIRecipe = true
    /// Blank prep / cook times show "—" (F3.7).
    var timesKnown: (prep: Bool, cook: Bool) = (true, true)

    enum MacroStatus {
        case updating
        case outOfDate(retry: () -> Void)
    }

    @State private var showTotal = false
    @State private var saved: Bool?
    @State private var saving = false
    @State private var saveError: String?
    @State private var cooking = false
    @State private var cookedUndo: [CookedAPI.Snapshot]?
    @State private var shopping: (lines: [ShoppingPlan.Line], conversions: [Int64: CookedThis.Conversion])?
    @State private var addingMissing = false
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(recipe.title).font(.title2.bold())
                    Text(recipe.description).foregroundStyle(.secondary)
                    HStack(spacing: 0) {
                        info("person.2", "\(recipe.servings) serving\(recipe.servings == 1 ? "" : "s")")
                        info("knife", "Prep \(timesKnown.prep ? MacroFormat.minutes(recipe.prep_min) : "—")")
                        info("frying.pan", "Cook \(timesKnown.cook ? MacroFormat.minutes(recipe.cook_min) : "—")")
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
                switch macroStatus {
                case .updating:
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Updating nutrition…") }
                case .outOfDate(let retry):
                    HStack {
                        Label("Nutrition out of date", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("Retry", action: retry).font(.footnote.weight(.semibold))
                    }
                case nil:
                    Text(macroFootnote)
                }
            }

            Section("Ingredients") {
                ForEach(recipe.ingredients) { ingredientRow($0) }
            }

            Section("Steps") {
                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(i + 1)").font(.title3.bold()).foregroundStyle(Color.accentColor).frame(minWidth: 24)
                        Text(RecipeText.stepWithoutNumber(step)).font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                }
            }

            Section {
                Button { cooking = true } label: {
                    // Not a Label: inside a List, a Label's title is pushed into a column after
                    // the icon, so it doesn't centre.
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                        Text("Cooked this")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                if let shopping, !shopping.lines.isEmpty {
                    Button { addingMissing = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "cart.badge.plus")
                            Text("Add missing to shopping list (\(shopping.lines.count))")
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
                    }
                    .buttonStyle(.bordered)
                    .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            } footer: {
                Text("Takes what you used out of your pantry.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if isAIRecipe { Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("AI-generated. Check that meat, poultry, fish and eggs reach safe temperatures.",
                          systemImage: "exclamationmark.shield")
                    Label("Recipes avoid the allergies in your settings, but can't catch everything. Always read ingredient labels: packaged foods (sauces, stocks, spice mixes) can contain hidden allergens or traces. If an allergy is severe, double-check every ingredient before cooking.",
                          systemImage: "allergens")
                }
                .font(.footnote).foregroundStyle(.secondary)
            } }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onEdit {
                ToolbarItem(placement: .primaryAction) { Button("Edit", action: onEdit) }
            }
            if let onSave, let onUnsave {
                ToolbarItem(placement: .primaryAction) {
                    let isSaved = saved ?? initiallySaved
                    Button {
                        Task {
                            saving = true
                            defer { saving = false }
                            do {
                                if isSaved { try await onUnsave() } else { try await onSave() }
                                saved = !isSaved
                            } catch {
                                saveError = error.localizedDescription
                            }
                        }
                    } label: {
                        if saving {
                            ProgressView()
                        } else {
                            Label(isSaved ? "Saved" : "Save", systemImage: isSaved ? "bookmark.fill" : "bookmark")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .disabled(saving)
                    .accessibilityHint(isSaved ? "Removes it from your saved recipes" : "Adds it to your saved recipes")
                }
            }
        }
        .sheet(isPresented: $cooking) {
            CookedThisView(recipe: recipe) { snapshot in
                withAnimation { cookedUndo = snapshot }
                Task {
                    await loadShopping()
                    try? await Task.sleep(for: .seconds(5))
                    if cookedUndo == snapshot { withAnimation { cookedUndo = nil } }
                }
            }
        }
        .sheet(isPresented: $addingMissing) {
            if let shopping {
                AddMissingSheet(recipe: recipe, lines: shopping.lines, conversions: shopping.conversions) { n in
                    let text = "\(n) item\(n == 1 ? "" : "s") added to shopping list"
                    withAnimation { toast = text }
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        if toast == text { withAnimation { toast = nil } }
                    }
                }
            }
        }
        .task { await loadShopping() }
        .overlay(alignment: .bottom) {
            if let toast, cookedUndo == nil {
                Label(toast, systemImage: "cart.fill")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let snapshot = cookedUndo {
                HStack {
                    Label("Pantry updated", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Undo") {
                        withAnimation { cookedUndo = nil }
                        Task {
                            do { try await CookedAPI.undo(snapshot) }
                            catch { saveError = "Couldn't undo the pantry change." }
                            await loadShopping()
                        }
                    }
                    .fontWeight(.semibold)
                }
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert("Something went wrong", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "") }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    /// What the recipe still needs from the shop, against the pantry as it is now (F3.5).
    private func loadShopping() async {
        guard let pantry = try? await PantryAPI.activeItems() else { return }
        let ids = recipe.ingredients.compactMap(\.ingredient_id) + pantry.compactMap(\.ingredientId)
        let conversions = (try? await CookedAPI.conversions(ids)) ?? [:]
        shopping = (ShoppingPlan.lines(for: recipe, pantry: pantry, conversions: conversions), conversions)
    }

    /// One of the three header facts: equal width, always one line.
    private func info(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
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
