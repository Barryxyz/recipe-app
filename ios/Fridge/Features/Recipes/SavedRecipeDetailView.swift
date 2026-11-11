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
    @State private var sharing: ShareItem?
    @State private var shareBusy = false
    @State private var confirmStopSharing = false
    @State private var shareError: String?

    struct ShareItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

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
                // F4.1: a link anyone can open (the page shows the recipe as currently saved).
                ToolbarItem(placement: .primaryAction) {
                    if shareBusy { ProgressView() } else {
                        Button { Task { await share() } } label: { Label("Share", systemImage: "square.and.arrow.up") }
                            .needsInternet()
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button { editor = .duplicate } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        .needsInternet()
                }
                if recipe.share_token != nil {
                    ToolbarItem(placement: .secondaryAction) {
                        Button(role: .destructive) { confirmStopSharing = true } label: {
                            Label("Stop sharing", systemImage: "link.badge.plus")
                        }
                        .needsInternet()
                    }
                }
            }
            .sheet(item: $sharing) { item in
                ShareSheet(items: [ShareText(title: recipe.title, url: item.url), item.url]) { sharing = nil }
                    .ignoresSafeArea()
            }
            .confirmationDialog("Stop sharing this recipe?", isPresented: $confirmStopSharing, titleVisibility: .visible) {
                Button("Stop sharing", role: .destructive) { Task { await stopSharing() } }
            } message: {
                Text("The link stops working for everyone who has it. Sharing again makes a new link.")
            }
            .alert("Couldn't share", isPresented: .constant(shareError != nil)) {
                Button("OK") { shareError = nil }
            } message: { Text(shareError ?? "") }
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

    private func share() async {
        shareBusy = true
        defer { shareBusy = false }
        do {
            let token = try await SavedRecipesAPI.createShareLink(recipe.id)
            guard let url = AppConfig.shareURL(token: token) else { shareError = "Sharing isn't set up in this build."; return }
            if recipe.share_token == nil, let fresh = try? await SavedRecipesAPI.get(recipe.id) { recipe = fresh }
            Events.log(.shareCreated, ["source": .string(recipe.source)])
            sharing = ShareItem(url: url)
        } catch {
            shareError = error.localizedDescription
        }
    }

    private func stopSharing() async {
        do {
            try await SavedRecipesAPI.stopSharing(recipe.id)
            if let fresh = try? await SavedRecipesAPI.get(recipe.id) { recipe = fresh }
        } catch {
            shareError = error.localizedDescription
        }
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

/// The message that goes with a shared link: "<title>: a recipe from Fridge" (Messages and Mail
/// show it above the link preview).
final class ShareText: NSObject, UIActivityItemSource {
    let title: String
    let url: URL
    init(title: String, url: URL) { self.title = title; self.url = url }

    func activityViewControllerPlaceholderItem(_ vc: UIActivityViewController) -> Any { "" }
    func activityViewController(_ vc: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        type == .copyToPasteboard ? nil : "\(title): a recipe from Fridge"
    }
    func activityViewController(_ vc: UIActivityViewController, subjectForActivityType type: UIActivity.ActivityType?) -> String {
        "\(title): a recipe from Fridge"
    }
}
