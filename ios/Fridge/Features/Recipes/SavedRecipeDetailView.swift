import SwiftUI

/// A saved recipe: the shared detail view plus Saved toggle (unsave = delete), Edit (F3.2)
/// and Duplicate (F3.7).
struct SavedRecipeDetailView: View {
    @State var recipe: SavedRecipe
    let pantry: PantryMatcher
    /// Just created: calculate nutrition when it opens (F3.7 step 2).
    var recomputeOnAppear = false

    @State private var editor: Editor?
    @State private var macroStatus: RecipeDetailView.MacroStatus?
    @State private var didRecompute = false

    enum Editor: String, Identifiable { case edit, duplicate; var id: String { rawValue } }

    var body: some View {
        RecipeDetailView(recipe: recipe.asRecipe(pantry: pantry), initiallySaved: true,
                         onSave: {
                             try await SavedRecipesAPI.setDeleted(recipe.id, false)
                             Events.log(.recipeSaved, ["source": .string(recipe.source)])
                         },
                         onUnsave: {
                             try await SavedRecipesAPI.setDeleted(recipe.id, true)
                             Events.log(.recipeDeleted, ["source": .string(recipe.source), "via": "unsave"])
                         },
                         onEdit: { editor = .edit },
                         macroStatus: macroStatus,
                         isAIRecipe: recipe.source != "manual",
                         timesKnown: (recipe.prep_min != nil, recipe.cook_min != nil))
            .id(recipe.updated_at)
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    Button { editor = .duplicate } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                }
            }
            .fullScreenCover(item: $editor) { mode in
                switch mode {
                case .edit:
                    RecipeEditorView(navTitle: "Edit recipe", draft: RecipeEditDraft(recipe),
                                     onSave: { draft in try await save(draft) },
                                     onCancel: { editor = nil })
                case .duplicate:
                    RecipeEditorView(navTitle: "New recipe", draft: RecipeEditDraft(recipe).duplicated(), isNew: true,
                                     onSave: { draft in try await duplicate(draft) },
                                     onCancel: { editor = nil })
                }
            }
            .task {
                guard recomputeOnAppear, !didRecompute else { return }
                didRecompute = true
                await recompute()
            }
    }

    /// Saves (one transaction), closes the editor, then recalculates nutrition if needed.
    /// A failed recalculation keeps the edit and offers Retry (F3.2 step 3).
    private func save(_ draft: RecipeEditDraft) async throws {
        let before = RecipeEditDraft(recipe)
        try await SavedRecipesAPI.update(recipe.id, draft)
        Events.log(.recipeEdited, ["source": .string(recipe.source)])
        editor = nil
        if let fresh = try? await SavedRecipesAPI.get(recipe.id) { recipe = fresh }
        if draft.needsMacros(comparedTo: before) { await recompute() }
    }

    /// Saves the copy as a new recipe and shows it here (the list has both when going back).
    private func duplicate(_ draft: RecipeEditDraft) async throws {
        let id = try await RecipeCreator.save(draft, source: RecipeEditDraft.duplicateSource(of: recipe.source))
        Events.log(.recipeCreated, draft.eventProps(duplicate: true))
        editor = nil
        if let copy = try? await SavedRecipesAPI.get(id) { recipe = copy }
        await recompute()
    }

    private func recompute() async {
        macroStatus = .updating
        do {
            try await SavedRecipesAPI.recomputeMacros(recipe.id)
            if let fresh = try? await SavedRecipesAPI.get(recipe.id) { recipe = fresh }
            macroStatus = nil
        } catch {
            macroStatus = .outOfDate(retry: { Task { await recompute() } })
        }
    }
}
