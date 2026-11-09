import SwiftUI

/// F3.2: edit every part of a recipe. Validation is shown inline; Save is enabled once valid.
struct RecipeEditorView: View {
    let navTitle: String
    let original: RecipeEditDraft
    /// Saves the draft; throws to keep the editor open with an error.
    var onSave: (RecipeEditDraft) async throws -> Void
    var onCancel: () -> Void

    @State private var draft: RecipeEditDraft
    @State private var editingIngredient: RecipeEditDraft.Ingredient?
    @State private var addingIngredient = false
    @State private var pendingServings: Int?
    @State private var confirmDiscard = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var showErrors = false
    @State private var editMode: EditMode = .inactive

    init(navTitle: String, draft: RecipeEditDraft, onSave: @escaping (RecipeEditDraft) async throws -> Void,
         onCancel: @escaping () -> Void) {
        self.navTitle = navTitle
        self.original = draft
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: draft)
    }

    private var errors: [RecipeEditDraft.Field: String] { draft.errors }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Recipe name", text: $draft.title)
                    error(.title)
                    TextField("Description (optional)", text: $draft.description, axis: .vertical)
                        .lineLimit(2...5)
                    error(.description)
                }

                Section {
                    Stepper(value: Binding(get: { draft.servings }, set: { askToScale($0) }),
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
                    error(.steps)
                } header: {
                    sectionHeader("Steps")
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(draft != original)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if draft != original { confirmDiscard = true } else { onCancel() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Save") {
                            showErrors = true
                            guard draft.isValid else { return }
                            Task { await save() }
                        }
                        .fontWeight(.semibold)
                        .disabled(draft == original)
                    }
                }
            }
            .sheet(item: $editingIngredient) { ing in
                IngredientEditSheet(ingredient: ing, isNew: false) { draft.update($0) }
            }
            .sheet(isPresented: $addingIngredient) {
                IngredientEditSheet(ingredient: .init(name: "", quantity: nil, unit: "g", note: "", isOptional: false),
                                    isNew: true) { draft.ingredients.append($0) }
            }
            .confirmationDialog("Scale ingredients?", isPresented: Binding(
                get: { pendingServings != nil }, set: { if !$0 { pendingServings = nil } }), titleVisibility: .visible) {
                if let n = pendingServings {
                    Button("Scale ingredients for \(n)") { draft.scale(to: n); pendingServings = nil }
                    Button("Just change the number") { draft.servings = n; pendingServings = nil }
                }
            } message: {
                Text("Change every amount to match the new number of servings?")
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

    private func askToScale(_ n: Int) {
        guard n != draft.servings else { return }
        if draft.ingredients.contains(where: { $0.quantity != nil }) { pendingServings = n } else { draft.servings = n }
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
        HStack {
            Text(label)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Text("min").foregroundStyle(.secondary)
        }
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
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// One ingredient: name (with catalog / your items suggestions), amount, unit, note, optional.
struct IngredientEditSheet: View {
    @State var ingredient: RecipeEditDraft.Ingredient
    let isNew: Bool
    var onDone: (RecipeEditDraft.Ingredient) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [IngredientChoice] = []
    /// The name the catalog link belongs to; typing something else unlinks it.
    @State private var linkedName: String?
    @FocusState private var focus: Bool

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
                         ? "Not linked to the food list: kept as typed, without nutrition data."
                         : "")
                }

                Section {
                    HStack {
                        Text("Amount")
                        Spacer()
                        TextField("some", value: $ingredient.quantity, format: .number.precision(.fractionLength(0...2)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .disabled(ingredient.unit == "to taste")
                    }
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
