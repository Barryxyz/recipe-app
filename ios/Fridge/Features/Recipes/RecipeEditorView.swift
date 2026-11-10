import SwiftUI

/// F3.2: edit every part of a recipe. Validation is shown inline; Save is enabled once valid.
/// F3.7: the same editor creates new recipes (`isNew`), with paste helpers, a kept draft and
/// catalog linking as you go.
struct RecipeEditorView: View {
    let navTitle: String
    let original: RecipeEditDraft
    var isNew = false
    /// New recipe: the form is kept on the device until saved or discarded.
    var keepsDraft = false
    /// Saves the draft; throws to keep the editor open with an error.
    var onSave: (RecipeEditDraft) async throws -> Void
    var onCancel: () -> Void

    @State private var draft: RecipeEditDraft
    @State private var editingIngredient: RecipeEditDraft.Ingredient?
    @State private var addingIngredient = false
    @State private var scaleBase: RecipeEditDraft.ScaleBase?
    @State private var confirmDiscard = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var showErrors = false
    @State private var editMode: EditMode = .inactive
    @State private var pasting: PasteKind?
    @State private var linking: Set<UUID> = []
    @State private var allergens: [String] = []
    @State private var allergenTags: [Int64: [String]] = [:]
    @State private var confirmKeepDraft = false
    @FocusState private var focusedTime: String?

    enum PasteKind: String, Identifiable { case ingredients, steps; var id: String { rawValue } }

    init(navTitle: String, draft: RecipeEditDraft, isNew: Bool = false, keepsDraft: Bool = false,
         onSave: @escaping (RecipeEditDraft) async throws -> Void,
         onCancel: @escaping () -> Void) {
        self.navTitle = navTitle
        self.original = draft
        self.isNew = isNew
        self.keepsDraft = keepsDraft
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: draft)
    }

    private var errors: [RecipeEditDraft.Field: String] { draft.errors }

    var body: some View {
        NavigationStack {
            Form {
                if let warning = AllergenCheck.warning(
                    AllergenCheck.found(in: draft.ingredients, allergens: allergens, tags: allergenTags)) {
                    Section {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    TextField("Recipe name", text: $draft.title)
                    error(.title)
                    TextField("Description (optional)", text: $draft.description, axis: .vertical)
                        .lineLimit(2...5)
                    error(.description)
                }

                Section {
                    Stepper(value: Binding(get: { draft.servings }, set: { draft.changeServings(to: $0, base: &scaleBase) }),
                            in: RecipeEditDraft.servingsRange) {
                        Text("Servings: \(draft.servings)")
                    }
                    minutesField("Prep", value: $draft.prepMin)
                    error(.prep)
                    minutesField("Cook", value: $draft.cookMin)
                    error(.cook)
                }

                Section {
                    ForEach(draft.ingredients) { ing in
                        Button { editingIngredient = ing } label: { ingredientRow(ing) }
                            .foregroundStyle(.primary)
                    }
                    .onMove { draft.ingredients.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { draft.ingredients.remove(atOffsets: $0) }
                    Button { addingIngredient = true } label: { Label("Add ingredient", systemImage: "plus") }
                    Button { pasting = .ingredients } label: { Label("Paste list", systemImage: "doc.on.clipboard") }
                    error(.ingredients)
                } header: {
                    sectionHeader("Ingredients")
                }

                Section {
                    ForEach($draft.steps) { $step in
                        let n = (draft.steps.firstIndex { $0.id == step.id } ?? 0) + 1
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(n)").font(.headline).foregroundStyle(Color.accentColor).frame(minWidth: 20)
                            TextField("Describe this step", text: $step.text, axis: .vertical)
                        }
                    }
                    .onMove { draft.steps.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { draft.steps.remove(atOffsets: $0) }
                    Button { draft.steps.append(.init(text: "")) } label: { Label("Add step", systemImage: "plus") }
                    Button { pasting = .steps } label: { Label("Paste steps", systemImage: "doc.on.clipboard") }
                    error(.steps)
                } header: {
                    sectionHeader("Steps")
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(keepsDraft ? draft.hasContent : draft != original)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Save") {
                            showErrors = true
                            guard draft.isValid else { return }
                            Task { await save() }
                        }
                        .fontWeight(.semibold)
                        .disabled(!isNew && draft == original)
                    }
                }
            }
            .sheet(item: $editingIngredient) { ing in
                IngredientEditSheet(ingredient: ing, isNew: false, savesCustom: isNew) {
                    draft.update($0)
                    linkIfNeeded([$0])
                }
            }
            .sheet(isPresented: $addingIngredient) {
                IngredientEditSheet(ingredient: .init(name: "", quantity: nil, unit: "g", note: "", isOptional: false),
                                    isNew: true, savesCustom: isNew) {
                    draft.ingredients.append($0)
                    linkIfNeeded([$0])
                }
            }
            .sheet(item: $pasting) { kind in
                PasteSheet(kind: kind) { text in
                    if kind == .ingredients {
                        let before = draft.ingredients.count
                        draft.appendPasted(RecipePaste.ingredients(text))
                        linkIfNeeded(Array(draft.ingredients[before...]))
                    } else {
                        draft.appendPasted(steps: RecipePaste.steps(text))
                    }
                }
            }
            .confirmationDialog("Keep this recipe as a draft?", isPresented: $confirmKeepDraft, titleVisibility: .visible) {
                Button("Keep draft") { RecipeCreator.keepDraft(draft); onCancel() }
                Button("Discard", role: .destructive) { RecipeCreator.discardDraft(); onCancel() }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("A kept draft opens again from New recipe.")
            }
            .onChange(of: draft) { _, d in if keepsDraft { RecipeCreator.keepDraft(d) } }
            .task {
                allergens = await RecipeCreator.prefs()?.allergens ?? []
            }
            .task(id: draft.ingredients.compactMap(\.ingredientId)) {
                let ids = draft.ingredients.compactMap(\.ingredientId).filter { allergenTags[$0] == nil }
                guard !ids.isEmpty, let found = try? await RecipeCreator.allergenTags(ids) else { return }
                allergenTags.merge(found) { $1 }
            }
            .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { onCancel() }
                Button("Keep editing", role: .cancel) {}
            }
            .alert("Couldn't save", isPresented: .constant(saveError != nil)) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
        }
    }

    private func cancel() {
        if keepsDraft {
            if draft.hasContent { confirmKeepDraft = true } else { RecipeCreator.discardDraft(); onCancel() }
        } else if draft != original {
            confirmDiscard = true
        } else {
            onCancel()
        }
    }

    /// New recipes: links typed or pasted names to the catalog when the match is good, so the
    /// rows left "Custom" are the ones that will become the user's own ingredients.
    private func linkIfNeeded(_ rows: [RecipeEditDraft.Ingredient]) {
        guard isNew else { return }
        for row in rows where row.ingredientId == nil {
            linking.insert(row.id)
            Task {
                let found = try? await RecipeCreator.match(row.name)
                linking.remove(row.id)
                if let found, let i = draft.ingredients.firstIndex(where: { $0.id == row.id && $0.name == row.name }) {
                    draft.ingredients[i].ingredientId = found.id
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do { try await onSave(draft) } catch { saveError = error.localizedDescription }
    }

    // MARK: Pieces

    @ViewBuilder private func error(_ field: RecipeEditDraft.Field) -> some View {
        // Shown once the user tries to save, or straight away for length limits.
        if let message = errors[field], showErrors || field == .description || (field == .title && !draft.title.isEmpty) {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.footnote).foregroundStyle(.red)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(editMode.isEditing ? "Done" : "Reorder") {
                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
            }
            .font(.footnote.weight(.semibold))
            .textCase(nil)
        }
    }

    private func minutesField(_ label: String, value: Binding<Int?>) -> some View {
        // The field fills the row and a tap anywhere on the row focuses it.
        HStack {
            Text(label)
            TextField("0", value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, minHeight: 32)
                .focused($focusedTime, equals: label)
            Text("min").foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { focusedTime = label }
    }

    private func ingredientRow(_ ing: RecipeEditDraft.Ingredient) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(MacroFormat.amount(ing.quantity, unit: ing.unit == "to taste" ? nil : ing.unit) +
                 (ing.unit == "to taste" ? "to taste" : ""))
                .monospacedDigit().foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(ing.name).italic(ing.isOptional)
                if !ing.note.isEmpty { Text(ing.note).font(.caption).foregroundStyle(.secondary) }
            }
            if ing.isOptional { Text("optional").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if linking.contains(ing.id) {
                ProgressView().controlSize(.mini)
            } else if isNew && (ing.ingredientId == nil || ing.ingredientId! >= PantryItem.customIdStart) {
                Text("Custom").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// One ingredient: name (with catalog / your items suggestions), amount, unit, note, optional.
struct IngredientEditSheet: View {
    @State var ingredient: RecipeEditDraft.Ingredient
    let isNew: Bool
    /// New recipes save unmatched names as the user's own ingredients (F3.7).
    var savesCustom = false
    var onDone: (RecipeEditDraft.Ingredient) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [IngredientChoice] = []
    /// The name the catalog link belongs to; typing something else unlinks it.
    @State private var linkedName: String?
    @FocusState private var focus: Bool
    @FocusState private var amountFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ingredient", text: $ingredient.name)
                        .focused($focus)
                        .autocorrectionDisabled()
                        .onChange(of: ingredient.name) { _, q in Task { await search(q) } }
                    if focus {
                        ForEach(suggestions) { s in
                            Button {
                                linkedName = s.name
                                ingredient.name = s.name
                                ingredient.ingredientId = s.id
                                focus = false
                                suggestions = []
                            } label: {
                                HStack {
                                    Text(s.name)
                                    Spacer()
                                    if s.isCustom { Text("your item").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                } footer: {
                    Text(ingredient.ingredientId == nil && !ingredient.name.isEmpty
                         ? (savesCustom ? "Not picked from the food list: a close match is linked automatically, otherwise it's saved as your own ingredient with estimated nutrition."
                                        : "Not linked to the food list: kept as typed, without nutrition data.")
                         : "")
                }

                Section {
                    HStack {
                        Text("Amount")
                        TextField("some", value: $ingredient.quantity, format: .number.precision(.fractionLength(0...2)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .focused($amountFocused)
                            .disabled(ingredient.unit == "to taste")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if ingredient.unit != "to taste" { amountFocused = true } }
                    Picker("Unit", selection: $ingredient.unit) {
                        ForEach(RecipeEditDraft.units(including: ingredient.unit), id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Note (e.g. finely chopped)", text: $ingredient.note)
                    Toggle("Optional", isOn: $ingredient.isOptional)
                }
            }
            .navigationTitle(isNew ? "Add ingredient" : "Edit ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        var out = ingredient
                        out.name = out.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if out.unit == "to taste" { out.quantity = nil }
                        onDone(out)
                        dismiss()
                    }
                    .disabled(ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if ingredient.ingredientId != nil { linkedName = ingredient.name }
                if isNew { focus = true }
            }
        }
    }

    private func search(_ q: String) async {
        // Typing a new name unlinks the old catalog match until a suggestion is picked.
        if ingredient.ingredientId != nil && q != linkedName {
            ingredient.ingredientId = nil
            linkedName = nil
        }
        if q == linkedName { suggestions = []; return }
        let query = q.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { suggestions = []; return }
        let found = (try? await PantryAPI.search(query, limit: 6)) ?? []
        if ingredient.name == q { suggestions = found }
    }
}

/// F3.7: paste an ingredient list or steps copied from a website or a note.
struct PasteSheet: View {
    let kind: RecipeEditorView.PasteKind
    var onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focus: Bool

    private var count: Int {
        kind == .ingredients ? RecipePaste.ingredients(text).count : RecipePaste.steps(text).count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 220)
                        .focused($focus)
                        .autocorrectionDisabled()
                } header: {
                    Text(kind == .ingredients ? "One ingredient per line" : "Numbered steps, or one per paragraph")
                } footer: {
                    if !text.isEmpty {
                        Text(count == 0 ? "Nothing found yet." :
                             "\(count) \(kind == .ingredients ? "ingredient" : "step")\(count == 1 ? "" : "s") found.")
                    } else {
                        Text(kind == .ingredients ? "For example:\n2 cups flour\n1 1/2 tsp salt\n3 eggs, beaten"
                                                  : "For example:\n1. Heat the oil.\n2. Add the onion and cook for 5 minutes.")
                    }
                }
                if UIPasteboard.general.hasStrings {
                    Button { text = UIPasteboard.general.string ?? text } label: {
                        Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                    }
                }
            }
            .navigationTitle(kind == .ingredients ? "Paste ingredients" : "Paste steps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { onAdd(text); dismiss() }.disabled(count == 0)
                }
            }
            .onAppear { focus = true }
        }
    }
}
