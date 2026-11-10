import SwiftUI

/// The Recipes tab: "Get recipe ideas" (F2.1) -> results (F2.4), "Your last ideas", and the
/// saved recipes (F3.1) with search, filters and swipe to delete with undo (F3.3).
struct RecipesView: View {
    let user: AppUser

    @State private var sheet: SheetInput?
    @State private var results: ResultsInput?
    @State private var lastSession: RecipeSession?
    @State private var usage: RecipeAPI.Usage?
    @State private var loading = false
    @State private var loadError: String?
    @State private var showScan = false
    @State private var showAdd = false

    @State private var saved: [SavedRecipe] = []
    @State private var pantry = PantryMatcher()
    @State private var loadedSaved = false
    @State private var search = ""
    @State private var filters: Set<SavedRecipeFilter> = []
    @State private var deleted: SavedRecipe?
    @State private var actionError: String?
    @State private var path: [SavedRecipe] = []
    @State private var newRecipe: RecipeEditDraft?
    @State private var justCreated: Set<UUID> = []

    struct SheetInput: Identifiable {
        let id = UUID()
        let pantry: RecipePantry
        let options: RecipeOptions
        let excluded: Set<UUID>
    }

    struct ResultsInput: Identifiable {
        let id = UUID()
        let request: RecipeRequest
        let session: RecipeSession?
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ideasCard
                    if let lastSession, !lastSession.response.recipes.isEmpty { lastIdeasCard(lastSession) }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))

                savedSection
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Recipes")
            .navigationDestination(for: SavedRecipe.self) { r in
                SavedRecipeDetailView(recipe: r, pantry: pantry, recomputeOnAppear: justCreated.contains(r.id))
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { Task { await startNewRecipe() } } label: { Label("New recipe", systemImage: "square.and.pencil") }
                    } label: {
                        Image(systemName: "plus").accessibilityLabel("Add a recipe")
                    }
                }
            }
            .fullScreenCover(item: Binding(get: { newRecipe.map(NewRecipeInput.init) }, set: { if $0 == nil { newRecipe = nil } })) { input in
                RecipeEditorView(navTitle: "New recipe", draft: input.draft, isNew: true, keepsDraft: true,
                                 onSave: { draft in try await createRecipe(draft) },
                                 onCancel: { newRecipe = nil })
            }
            .refreshable { await loadSaved() }
            .onAppear {
                // Also runs when coming back from a recipe, so unsaved ones disappear.
                lastSession = RecipeSession.load()
                Task { await loadSaved() }
            }
            .overlay(alignment: .bottom) { undoToast }
            .sheet(item: $sheet) { input in
                RecipeOptionsView(pantry: input.pantry, options: input.options, excluded: input.excluded,
                                  usage: usage,
                                  onGenerate: { request in
                                      sheet = nil
                                      Task { try? await Task.sleep(for: .milliseconds(350))
                                          results = ResultsInput(request: request, session: nil) }
                                  },
                                  onScan: { showScan = true },
                                  onAddManually: { showAdd = true })
            }
            .fullScreenCover(item: $results, onDismiss: {
                lastSession = RecipeSession.load()
                Task { await loadSaved() }
            }) { input in
                RecipeResultsView(initial: input.session, request: input.request, requestsLeft: usage?.left,
                                  onChangeOptions: { request in
                                      results = nil
                                      Task { try? await Task.sleep(for: .milliseconds(350))
                                          await openOptions(from: request) }
                                  },
                                  onAddItems: {
                                      results = nil
                                      Task { try? await Task.sleep(for: .milliseconds(350)); showAdd = true }
                                  },
                                  onClose: { results = nil })
            }
            .fullScreenCover(isPresented: $showScan) {
                ScanView(onAddManually: { Task { try? await Task.sleep(for: .milliseconds(400)); showAdd = true } },
                         onSaved: { _ in showScan = false })
            }
            .sheet(isPresented: $showAdd) { ItemFormView(mode: .add) {} }
            .alert("Couldn't load your pantry", isPresented: .constant(loadError != nil)) {
                Button("OK") { loadError = nil }
            } message: { Text(loadError ?? "") }
            .alert("Something went wrong", isPresented: .constant(actionError != nil)) {
                Button("OK") { actionError = nil }
            } message: { Text(actionError ?? "") }
        }
    }

    // MARK: Saved recipes

    private var shown: [SavedRecipe] {
        SavedRecipeSearch.filter(saved, search: search, filters: filters, pantry: pantry)
    }

    @ViewBuilder private var savedSection: some View {
        if !loadedSaved {
            Section { ProgressView().frame(maxWidth: .infinity) }
        } else if saved.isEmpty {
            Section {
                ContentUnavailableView {
                    Label("No saved recipes yet", systemImage: "book.closed")
                } description: {
                    Text("Save a recipe idea, or write down one of your own.")
                } actions: {
                    Button { Task { await startNewRecipe() } } label: { Label("Write your own", systemImage: "square.and.pencil") }
                        .buttonStyle(.bordered)
                }
            }
        } else {
            Section {
                searchField
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SavedRecipeFilter.allCases) { f in
                            let on = filters.contains(f)
                            Button {
                                if on { filters.remove(f) } else { filters.insert(f) }
                            } label: {
                                Text(f.title).font(.subheadline)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(on ? Color.accentColor.opacity(0.18) : Color(.secondarySystemFill), in: Capsule())
                                    .overlay(Capsule().stroke(on ? Color.accentColor : .clear, lineWidth: 1.5))
                                    .foregroundStyle(on ? Color.accentColor : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                if shown.isEmpty {
                    Text(search.isEmpty ? "No saved recipes match these filters." : "No saved recipes match \u{201C}\(search)\u{201D}.")
                        .foregroundStyle(.secondary)
                }
                ForEach(shown) { r in
                    NavigationLink(value: r) { savedRow(r) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { Task { await delete(r) } } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            } header: {
                Text("Saved recipes (\(saved.count))")
            }
        }
    }

    /// In the list (below the ideas cards) rather than pinned under the title.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search saved recipes", text: $search)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        .listRowSeparator(.hidden)
    }

    private func savedRow(_ r: SavedRecipe) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(r.title).font(.headline)
                if let tag = r.tag {
                    Text(tag).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            // Fixed-width columns so time, calories and "Can make now" line up on every row.
            HStack(spacing: 0) {
                Group {
                    if let t = r.totalMinutes { Label(MacroFormat.minutes(t), systemImage: "clock") } else { Text("") }
                }
                .frame(width: 92, alignment: .leading)
                Group {
                    if let m = r.macros_per_serving {
                        Label("\(MacroFormat.prefix(m))\(MacroFormat.kcal(m.kcal)) kcal", systemImage: "flame")
                    } else { Text("") }
                }
                .frame(width: 96, alignment: .leading)
                if pantry.canMakeNow(r) {
                    Label("Can make now", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .monospacedDigit()
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: Write your own (F3.7)

    struct NewRecipeInput: Identifiable {
        let draft: RecipeEditDraft
        var id: Int { 0 }
    }

    /// Opens the kept draft, or an empty recipe for the user's default number of servings.
    private func startNewRecipe() async {
        if let kept = RecipeCreator.loadDraft() { newRecipe = kept; return }
        let servings = await RecipeCreator.prefs()?.defaultServings ?? 2
        newRecipe = RecipeEditDraft(servings: min(max(servings, RecipeEditDraft.servingsRange.lowerBound),
                                                  RecipeEditDraft.servingsRange.upperBound))
    }

    /// Saves, forgets the draft and opens the new recipe, which then calculates its nutrition.
    private func createRecipe(_ draft: RecipeEditDraft) async throws {
        let id = try await RecipeCreator.save(draft, source: "manual")
        RecipeCreator.discardDraft()
        newRecipe = nil
        await loadSaved()
        var found = saved.first { $0.id == id }
        if found == nil { found = try? await SavedRecipesAPI.get(id) }
        if let r = found {
            justCreated.insert(id)
            try? await Task.sleep(for: .milliseconds(350))
            path.append(r)
        }
    }

    private func loadSaved() async {
        async let items = try? PantryAPI.activeItems()
        do {
            saved = try await SavedRecipesAPI.list()
        } catch {
            if !loadedSaved { actionError = "Couldn't load your saved recipes. Pull down to try again." }
        }
        pantry = PantryMatcher(await items ?? [])
        loadedSaved = true
    }

    private func delete(_ r: SavedRecipe) async {
        withAnimation { saved.removeAll { $0.id == r.id } }
        do {
            try await SavedRecipesAPI.setDeleted(r.id, true)
            withAnimation { deleted = r }
            let shownFor = r.id
            try? await Task.sleep(for: .seconds(5))
            if deleted?.id == shownFor { withAnimation { deleted = nil } }
        } catch {
            await loadSaved()
            actionError = "Couldn't delete the recipe."
        }
    }

    private func undoDelete() async {
        guard let r = deleted else { return }
        withAnimation { deleted = nil }
        do {
            try await SavedRecipesAPI.setDeleted(r.id, false)
        } catch {
            actionError = "Couldn't restore the recipe."
        }
        await loadSaved()
    }

    @ViewBuilder private var undoToast: some View {
        if let deleted {
            HStack {
                Text("\u{201C}\(deleted.title)\u{201D} deleted").lineLimit(1)
                Spacer()
                Button("Undo") { Task { await undoDelete() } }.fontWeight(.semibold)
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Ideas

    private var ideasCard: some View {
        Button { Task { await openOptions(from: nil) } } label: {
            HStack(spacing: 14) {
                Image(systemName: "sparkles").font(.title)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Get recipe ideas").font(.headline)
                    Text("From what's in your pantry, using what expires first.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if loading { ProgressView().tint(.white) } else { Image(systemName: "chevron.right") }
            }
            .foregroundStyle(.white)
            .padding()
            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(loading)
    }

    private func lastIdeasCard(_ s: RecipeSession) -> some View {
        Button { results = ResultsInput(request: s.request, session: s) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your last ideas").font(.headline)
                    Text(s.response.recipes.map(\.title).joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    Text(s.createdAt.formatted(.relative(presentation: .named)))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    /// Opens the options sheet: fresh defaults, or the options of a previous request.
    private func openOptions(from request: RecipeRequest?) async {
        loading = true
        defer { loading = false }
        do {
            async let prefs = try? PrefsAPI.load(userId: user.id)
            async let left = try? RecipeAPI.usage()
            let items = try await PantryAPI.activeItems()
            let servings = await prefs?.defaultServings ?? 2
            usage = await left
            let options = request?.options
                ?? .initial(defaultServings: servings, remembered: RecipeOptions.loadRemembered())
            sheet = SheetInput(pantry: RecipePantry(items), options: options,
                               excluded: Set(request?.exclude_pantry_item_ids ?? []))
        } catch {
            loadError = error.localizedDescription
        }
    }
}

extension SavedRecipe: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
