import SwiftUI

/// F2.4: loading, 1–3 recipe cards, or the reason there are none with one-tap fixes.
struct RecipeResultsView: View {
    /// Shown immediately (reopening "Your last ideas"); nil generates `request`.
    let initial: RecipeSession?
    let request: RecipeRequest
    /// Requests left before this one, for the Cancel note.
    let requestsLeft: Int?
    var onChangeOptions: (RecipeRequest) -> Void
    var onAddItems: () -> Void
    var onClose: () -> Void

    private enum Phase: Equatable {
        case loading
        case results(RecipeSession)
        case none(note: String, fixes: [RecipeFix])
        case failed(RecipeAPI.RecipeError)
    }

    @State private var phase: Phase = .loading
    @State private var current: RecipeRequest?
    @State private var task: Task<Void, Never>?
    @State private var started = Date()
    @State private var confirmRegenerate = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if phase != .loading {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { task?.cancel(); onClose() } }
                    }
                }
                .navigationDestination(for: RecipeAPI.Recipe.self) { recipe in
                    RecipeDetailView(recipe: recipe, initiallySaved: savedId(recipe) != nil,
                                     onSave: { try await save(recipe) },
                                     onUnsave: { try await unsave(recipe) })
                }
        }
        .onAppear {
            guard current == nil else { return }
            current = request
            if let initial {
                phase = .results(initial)
                Task { await reconcileSaved() }
            } else {
                run(request)
            }
        }
        .confirmationDialog("Replace these recipes?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("Regenerate") { run(current ?? request) }
        } message: { Text("You'll get new ideas with the same options. Save any you want to keep first.") }
    }

    private var title: String {
        if case .results(let s) = phase { return "\(s.response.recipes.count) recipe idea\(s.response.recipes.count == 1 ? "" : "s")" }
        return "Recipe ideas"
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading: loading
        case .results(let session):
            if session.response.recipes.isEmpty {
                noRecipes(note: session.response.note ?? "Your pantry doesn't make a good recipe with these options.",
                          fixes: RecipeFix.fixes(for: session.request, limitedBy: session.response.limited_by))
            } else {
                results(session)
            }
        case .none(let note, let fixes): noRecipes(note: note, fixes: fixes)
        case .failed(let error): failed(error)
        }
    }

    // MARK: Save (F3.1)

    private var session: RecipeSession? {
        if case .results(let s) = phase { return s }
        return nil
    }

    private func savedId(_ r: RecipeAPI.Recipe) -> UUID? { session?.savedIds?[r.temp_id] }

    private func unsave(_ r: RecipeAPI.Recipe) async throws {
        guard let id = savedId(r), var s = session else { return }
        try await SavedRecipesAPI.setDeleted(id, true)
        s.savedIds?[r.temp_id] = nil
        s.save()
        phase = .results(s)
    }

    /// Recipes saved from these results may have been deleted since (Recipes tab): forget those.
    private func reconcileSaved() async {
        guard var s = session, let ids = s.savedIds, !ids.isEmpty,
              let active = try? await SavedRecipesAPI.activeIds(among: Array(ids.values)) else { return }
        let kept = ids.filter { active.contains($0.value) }
        guard kept.count != ids.count else { return }
        s.savedIds = kept
        s.save()
        if case .results = phase { phase = .results(s) }
    }

    private func save(_ r: RecipeAPI.Recipe) async throws {
        guard savedId(r) == nil else { return }       // never saved twice
        let id = try await SavedRecipesAPI.save(r)
        guard var s = session else { return }
        s.savedIds = (s.savedIds ?? [:]).merging([r.temp_id: id]) { $1 }
        s.save()
        phase = .results(s)
    }

    // MARK: Generate

    private func run(_ r: RecipeRequest) {
        current = r
        phase = .loading
        started = .now
        task?.cancel()
        task = Task {
            do {
                let response = try await RecipeAPI.generate(r)
                if Task.isCancelled { return }
                let session = RecipeSession(request: r, response: response)
                session.save()
                phase = .results(session)
            } catch is CancellationError {
                return   // only the user cancels (Cancel / Done), and they've left this screen
            } catch RecipeAPI.RecipeError.noGoodRecipes {
                phase = .none(note: "Couldn't come up with good recipes with these options.",
                              fixes: RecipeFix.fixes(for: r, limitedBy: []))
            } catch let e as RecipeAPI.RecipeError {
                phase = .failed(e)
            } catch {
                if Task.isCancelled { return }
                phase = .failed(.failed(error.localizedDescription))
            }
        }
    }

    // MARK: Loading

    /// Steps shown once, in order, timed to a typical ~17 s request. They don't loop.
    private static let steps: [(after: Double, text: String)] = [
        (0, "Reading your pantry"),
        (2, "Choosing ingredients that go together"),
        (6, "Writing recipes"),
        (13, "Checking allergens and amounts"),
        (17, "Working out nutrition"),
    ]

    private var loading: some View {
        TimelineView(.periodic(from: started, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(started)
            let current = Self.steps.lastIndex { elapsed >= $0.after } ?? 0
            VStack(spacing: 28) {
                Spacer()
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, step in
                        HStack(spacing: 12) {
                            Group {
                                if i < current {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                } else if i == current {
                                    ProgressView()
                                } else {
                                    Image(systemName: "circle").foregroundStyle(.quaternary)
                                }
                            }
                            .frame(width: 22)
                            Text(step.text)
                                .foregroundStyle(i <= current ? .primary : .tertiary)
                                .fontWeight(i == current ? .semibold : .regular)
                        }
                    }
                }
                Text(elapsed > 30 ? "Taking a little longer than usual…" : "Usually about 15–20 seconds")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    task?.cancel()
                    onChangeOptions(self.current ?? request)
                }
                .buttonStyle(.bordered)
                if let left = requestsLeft, left <= 3 {
                    Text("A cancelled request still counts toward today's limit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
            .animation(.easeInOut, value: current)
        }
    }

    // MARK: Results

    private func results(_ session: RecipeSession) -> some View {
        List {
            if let note = session.response.note {
                Section {
                    Label(note, systemImage: "info.circle").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(session.response.recipes) { recipe in
                    NavigationLink(value: recipe) { RecipeCard(recipe: recipe, saved: session.savedIds?[recipe.temp_id] != nil) }
                }
            } footer: {
                Text("Nutrition is approximate.")
            }
            Section {
                Button { confirmRegenerate = true } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                Button { onChangeOptions(session.request) } label: { Label("Change options", systemImage: "slider.horizontal.3") }
            }
        }
    }

    // MARK: No recipes

    private func noRecipes(note: String, fixes: [RecipeFix]) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "fork.knife.circle").font(.system(size: 52)).foregroundStyle(.secondary)
                Text("No recipe ideas this time").font(.title3.bold())
                Text(note).multilineTextAlignment(.center).foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    ForEach(fixes) { fix in
                        Button {
                            if let next = fix.apply(to: current ?? request) { run(next) } else { onAddItems() }
                        } label: {
                            Text(fix.title).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button { onChangeOptions(current ?? request) } label: {
                        Text("Change options").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 8)
            }
            .padding(24)
        }
    }

    private func failed(_ error: RecipeAPI.RecipeError) -> some View {
        ContentUnavailableView {
            Label(errorTitle(error), systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.errorDescription ?? "")
        } actions: {
            switch error {
            case .limitReached, .aiDisabled: EmptyView()
            default: Button("Retry") { run(current ?? request) }.buttonStyle(.borderedProminent)
            }
            Button("Change options") { onChangeOptions(current ?? request) }
        }
    }

    private func errorTitle(_ e: RecipeAPI.RecipeError) -> String {
        switch e {
        case .limitReached: "Limit reached"
        case .offline: "You're offline"
        default: "Couldn't get recipes"
        }
    }
}

/// One result card: title, description, time, kcal and P/C/F, expiring and missing.
struct RecipeCard: View {
    let recipe: RecipeAPI.Recipe
    var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(recipe.title).font(.headline)
                Spacer()
                if saved {
                    Label("Saved", systemImage: "bookmark.fill").font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            Text(recipe.description).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 12) {
                Label(MacroFormat.minutes(recipe.totalMinutes), systemImage: "clock")
                Label("\(MacroFormat.prefix(recipe.macros_per_serving))\(MacroFormat.kcal(recipe.macros_per_serving.kcal)) kcal",
                      systemImage: "flame")
                Text("P \(MacroFormat.grams(recipe.macros_per_serving.protein_g)) · C \(MacroFormat.grams(recipe.macros_per_serving.carbs_g)) · F \(MacroFormat.grams(recipe.macros_per_serving.fat_g))")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            HStack(spacing: 6) {
                if !recipe.uses_expiring.isEmpty {
                    chip("Uses \(recipe.uses_expiring.count) expiring item\(recipe.uses_expiring.count == 1 ? "" : "s")", .orange)
                }
                if !recipe.missing.isEmpty {
                    chip("Missing: \(recipe.missing.count) item\(recipe.missing.count == 1 ? "" : "s")", .secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
