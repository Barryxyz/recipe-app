import SwiftUI

/// A saved recipe: the shared detail view plus Saved toggle (unsave = delete) and Edit (F3.2).
struct SavedRecipeDetailView: View {
    @State var recipe: SavedRecipe
    let pantry: PantryMatcher

    @State private var editing = false
    @State private var macroStatus: RecipeDetailView.MacroStatus?

    var body: some View {
        RecipeDetailView(recipe: recipe.asRecipe(pantry: pantry), initiallySaved: true,
                         onSave: { try await SavedRecipesAPI.setDeleted(recipe.id, false) },
                         onUnsave: { try await SavedRecipesAPI.setDeleted(recipe.id, true) },
                         onEdit: { editing = true },
                         macroStatus: macroStatus)
            .id(recipe.updated_at)
            .fullScreenCover(isPresented: $editing) {
                RecipeEditorView(navTitle: "Edit recipe", draft: RecipeEditDraft(recipe),
                                 onSave: { draft in try await save(draft) },
                                 onCancel: { editing = false })
            }
    }

    /// Saves (one transaction), closes the editor, then recalculates nutrition if needed.
    /// A failed recalculation keeps the edit and offers Retry (F3.2 step 3).
    private func save(_ draft: RecipeEditDraft) async throws {
        let before = RecipeEditDraft(recipe)
        try await SavedRecipesAPI.update(recipe.id, draft)
        editing = false
        if let fresh = try? await SavedRecipesAPI.get(recipe.id) { recipe = fresh }
        if draft.needsMacros(comparedTo: before) { await recompute() }
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
