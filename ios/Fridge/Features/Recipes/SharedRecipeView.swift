import SwiftUI

/// F4.3: a recipe opened from a share link. The F2.4 detail layout with a "Shared recipe"
/// label, marks from the recipient's own pantry, Save to my recipes, Add missing and Cooked
/// this. The owner's own link opens their saved recipe instead.
struct SharedRecipeView: View {
    let token: String
    var onClose: () -> Void

    private enum Phase {
        case loading
        case gone
        case failed(String)
        case own(SavedRecipe)
        case shared(SharedRecipe)
    }

    @State private var phase: Phase = .loading
    @State private var pantry = PantryMatcher()
    @State private var savedCopy: UUID?

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose) }
                }
        }
        .task(id: token) { await load() }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Opening recipe…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .gone:
            ContentUnavailableView("This recipe is no longer shared", systemImage: "link",
                                   description: Text("The person who shared it stopped sharing it, or deleted it."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't open the recipe", systemImage: "wifi.slash")
            } description: { Text(message) } actions: {
                Button("Try again") { Task { await load() } }.buttonStyle(.borderedProminent)
            }
        case .own(let recipe):
            SavedRecipeDetailView(recipe: recipe, pantry: pantry)
        case .shared(let recipe):
            RecipeDetailView(recipe: recipe.asRecipe(pantry: pantry), initiallySaved: false,
                             onSave: { try await saveCopy(recipe) },
                             onUnsave: { try await removeCopy() },
                             isAIRecipe: recipe.is_ai,
                             timesKnown: (recipe.prep_min != nil, recipe.cook_min != nil),
                             banner: "Shared recipe")
        }
    }

    private func load() async {
        phase = .loading
        pantry = PantryMatcher((try? await PantryAPI.activeItems()) ?? [])
        // Your own link: open the saved recipe (the token is on it while it's shared).
        if let own = ((try? await SavedRecipesAPI.list()) ?? []).first(where: { $0.share_token == token }) {
            phase = .own(own)
            return
        }
        do {
            if let recipe = try await SharedRecipeAPI.fetch(token) {
                phase = .shared(recipe)
                Events.log(.sharedRecipeOpened, ["is_ai": .bool(recipe.is_ai)])
            } else {
                phase = .gone
            }
        } catch {
            phase = .failed(Connectivity.shared.isOnline ? "Something went wrong. Try again."
                                                         : "Opening a shared recipe needs internet.")
        }
    }

    /// An independent copy: later edits by the owner don't change it.
    private func saveCopy(_ recipe: SharedRecipe) async throws {
        let id = try await RecipeCreator.save(recipe.draft, source: "shared")
        savedCopy = id
        Events.log(.recipeSaved, ["source": "shared"])
        NotificationCenter.default.post(name: .savedRecipesChanged, object: nil)
        // Nutrition from the recipient's catalog view (F2.3); the list updates when it's done.
        Task {
            try? await SavedRecipesAPI.recomputeMacros(id)
            NotificationCenter.default.post(name: .savedRecipesChanged, object: nil)
        }
    }

    private func removeCopy() async throws {
        guard let id = savedCopy else { return }
        try await SavedRecipesAPI.setDeleted(id, true)
        savedCopy = nil
        NotificationCenter.default.post(name: .savedRecipesChanged, object: nil)
    }
}
