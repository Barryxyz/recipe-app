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
    @State private var confirmRegenerate = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if phase != .loading {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { onClose() } }
                    }
                }
                .navigationDestination(for: RecipeAPI.Recipe.self) { RecipeDetailView(recipe: $0) }
        }
        .onAppear {
            guard current == nil else { return }
            current = request
            if let initial { phase = .results(initial) } else { run(request) }
        }
        .onDisappear { task?.cancel() }
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

    // MARK: Generate

    private func run(_ r: RecipeRequest) {
        current = r
        phase = .loading
        task?.cancel()
        task = Task {
            do {
                let response = try await RecipeAPI.generate(r)
                let session = RecipeSession(request: r, response: response)
                session.save()
                phase = .results(session)
            } catch is CancellationError {
                return
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

    private static let lines = ["Checking what's expiring…", "Looking at your pantry…", "Matching your preferences…",
                                "Writing recipes…", "Checking allergens…", "Working out nutrition…"]

    private var loading: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView().controlSize(.large)
            TimelineView(.periodic(from: .now, by: 3)) { context in
                let i = Int(context.date.timeIntervalSinceReferenceDate / 3) % Self.lines.count
                Text(Self.lines[i]).font(.headline).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut, value: i)
            }
            Text("This usually takes 15–20 seconds.").font(.footnote).foregroundStyle(.tertiary)
            Spacer()
            Button("Cancel") {
                task?.cancel()
                onChangeOptions(current ?? request)
            }
            .buttonStyle(.bordered)
            if let left = requestsLeft, left <= 3 {
                Text("A cancelled request still counts toward today's limit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
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
                    NavigationLink(value: recipe) { RecipeCard(recipe: recipe) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recipe.title).font(.headline)
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
