import SwiftUI

/// The Recipes tab. Today: "Get recipe ideas" (F2.1). Saved recipes are listed here later (F3.1).
struct RecipesView: View {
    let user: AppUser

    @State private var sheet: SheetInput?
    @State private var loading = false
    @State private var loadError: String?
    @State private var showScan = false
    @State private var showAdd = false
    @State private var lastRequest: RecipeRequest?

    struct SheetInput: Identifiable {
        let id = UUID()
        let pantry: RecipePantry
        let options: RecipeOptions
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ideasCard
                    ContentUnavailableView("No saved recipes yet", systemImage: "book.closed",
                                           description: Text("Recipes you save will appear here."))
                        .padding(.top, 24)
                }
                .padding()
            }
            .navigationTitle("Recipes")
            .sheet(item: $sheet) { input in
                RecipeOptionsView(pantry: input.pantry, options: input.options,
                                  onGenerate: { request in sheet = nil; lastRequest = request },
                                  onScan: { showScan = true },
                                  onAddManually: { showAdd = true })
            }
            .fullScreenCover(isPresented: $showScan) {
                ScanView(onAddManually: { Task { try? await Task.sleep(for: .milliseconds(400)); showAdd = true } },
                         onSaved: { _ in showScan = false })
            }
            .sheet(isPresented: $showAdd) { ItemFormView(mode: .add) {} }
            .alert("Couldn't load your pantry", isPresented: .constant(loadError != nil)) {
                Button("OK") { loadError = nil }
            } message: { Text(loadError ?? "") }
            // Placeholder until generation (F2.2) and results (F2.4) are built.
            .alert("Request ready", isPresented: .constant(lastRequest != nil)) {
                Button("OK") { lastRequest = nil }
            } message: {
                Text(lastRequest.map(summary) ?? "")
            }
        }
    }

    private var ideasCard: some View {
        Button { Task { await openOptions() } } label: {
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

    private func openOptions() async {
        loading = true
        defer { loading = false }
        do {
            async let prefs = try? PrefsAPI.load(userId: user.id)
            let items = try await PantryAPI.activeItems()
            let servings = await prefs?.defaultServings ?? 2
            sheet = SheetInput(pantry: RecipePantry(items),
                               options: .initial(defaultServings: servings, remembered: RecipeOptions.loadRemembered()))
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func summary(_ r: RecipeRequest) -> String {
        let time = r.max_minutes.map { "\($0) min" } ?? "any time"
        return "\(r.servings) servings · \(r.meal) · \(time) · \(r.cuisine ?? "any cuisine")" +
            "\(r.only_on_hand ? " · only what I have" : "")" +
            "\(r.exclude_pantry_item_ids.isEmpty ? "" : " · \(r.exclude_pantry_item_ids.count) left out")" +
            "\n\nRecipe generation is the next step (F2.2)."
    }
}
