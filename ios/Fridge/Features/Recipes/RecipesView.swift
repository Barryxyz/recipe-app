import SwiftUI

/// The Recipes tab: "Get recipe ideas" (F2.1) -> results (F2.4), and "Your last ideas" to reopen
/// them until the next generation. Saved recipes are listed here later (F3.1).
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
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ideasCard
                    if let lastSession, !lastSession.response.recipes.isEmpty { lastIdeasCard(lastSession) }
                    ContentUnavailableView("No saved recipes yet", systemImage: "book.closed",
                                           description: Text("Recipes you save will appear here."))
                        .padding(.top, 24)
                }
                .padding()
            }
            .navigationTitle("Recipes")
            .onAppear { lastSession = RecipeSession.load() }
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
            .fullScreenCover(item: $results, onDismiss: { lastSession = RecipeSession.load() }) { input in
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
        }
    }

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
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .foregroundStyle(.primary)
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
