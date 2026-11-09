import SwiftUI

/// F2.1: options before generating. The defaults work, so Generate is one tap away.
struct RecipeOptionsView: View {
    let pantry: RecipePantry
    @State var options: RecipeOptions
    var onGenerate: (RecipeRequest) -> Void
    var onScan: () -> Void
    var onAddManually: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var excluded: Set<UUID> = []
    @State private var customCuisine = ""

    var body: some View {
        NavigationStack {
            Group {
                if pantry.isEmpty { emptyPantry } else { form }
            }
            .navigationTitle("Recipe ideas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .onAppear {
            if let c = options.cuisine, Cuisine(rawValue: c) == nil { customCuisine = c }
        }
    }

    // MARK: Empty pantry

    private var emptyPantry: some View {
        ContentUnavailableView {
            Label("Your pantry is empty", systemImage: "refrigerator")
        } description: {
            Text("Add what you have first, and we'll suggest recipes that use it.")
        } actions: {
            Button { dismiss(); onScan() } label: { Label("Scan", systemImage: "camera") }
                .buttonStyle(.borderedProminent)
            Button("Add manually") { dismiss(); onAddManually() }
        }
    }

    // MARK: Options

    private var form: some View {
        Form {
            Section {
                NavigationLink {
                    ExcludeItemsView(pantry: pantry, excluded: $excluded)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(usingText)
                        Text(excluded.isEmpty ? "Tap to leave items out" : "\(excluded.count) left out for this request")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if pantry.expiredCount > 0 {
                    Label("\(pantry.expiredCount) expired item\(pantry.expiredCount == 1 ? "" : "s") left out",
                          systemImage: "calendar.badge.exclamationmark")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                Stepper(value: $options.servings, in: RecipeOptions.servingsRange) {
                    Text("Servings: \(options.servings)")
                }
            }

            Section("Max total time") {
                ChipGrid(items: TimeChoice.all, title: \.title,
                         isOn: { $0.minutes == options.maxMinutes },
                         toggle: { options.maxMinutes = $0.minutes })
            }

            Section("Meal") {
                ChipGrid(items: Meal.allCases, title: \.title, isOn: { $0 == options.meal },
                         toggle: { options.meal = $0 })
            }

            Section("Cuisine (optional)") {
                ChipGrid(items: Cuisine.allCases, title: \.title, isOn: { $0.rawValue == options.cuisine },
                         toggle: { c in
                             customCuisine = ""
                             options.cuisine = options.cuisine == c.rawValue ? nil : c.rawValue
                         })
                TextField("Other (e.g. Korean)", text: $customCuisine)
                    .autocorrectionDisabled()
                    .onChange(of: customCuisine) { _, new in
                        if !new.isEmpty || Cuisine(rawValue: options.cuisine ?? "") == nil { options.cuisine = new }
                    }
            }

            Section {
                Toggle("Use expiring items first", isOn: $options.preferExpiring)
                Toggle("Only use what I have", isOn: $options.onlyOnHand)
            } footer: {
                Text(options.onlyOnHand ? "No shopping needed: recipes use only your pantry and staples."
                                        : "Recipes may add up to 3 items you don't have.")
            }
        }
        .safeAreaInset(edge: .bottom) { generateBar }
    }

    private var usingText: String {
        let n = pantry.itemCount(excluding: excluded), s = pantry.stapleCount(excluding: excluded)
        return "Using \(n) item\(n == 1 ? "" : "s")" + (s > 0 ? " + \(s) staple\(s == 1 ? "" : "s")" : "")
    }

    private var warning: RecipePantry.Warning? { pantry.warning(excluding: excluded, onlyOnHand: options.onlyOnHand) }

    private var generateBar: some View {
        VStack(spacing: 8) {
            if let warning {
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                options.remember()
                onGenerate(RecipeRequest(options: options, excluding: excluded))
            } label: {
                Label("Generate", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(warning == .nothingSelected)
        }
        .padding()
        .background(.bar)
    }

    private struct TimeChoice: Identifiable {
        let minutes: Int?
        var id: Int { minutes ?? 0 }
        var title: String { minutes.map { "\($0) min" } ?? "Any" }
        static let all = RecipeOptions.timeChoices.map { TimeChoice(minutes: $0) } + [TimeChoice(minutes: nil)]
    }
}

/// Leave items out for this request only (e.g. "save the steak").
private struct ExcludeItemsView: View {
    let pantry: RecipePantry
    @Binding var excluded: Set<UUID>

    var body: some View {
        List {
            Section {
                ForEach(pantry.items) { row($0) }
            } footer: {
                Text("Left-out items stay in your pantry; they're only skipped for this request.")
            }
            if !pantry.staples.isEmpty {
                Section("Seasonings & Staples") { ForEach(pantry.staples) { row($0) } }
            }
        }
        .navigationTitle("Items to use")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(excluded.isEmpty ? "None" : "All") {
                    excluded = excluded.isEmpty ? Set((pantry.items + pantry.staples).map(\.id)) : []
                }
            }
        }
    }

    private func row(_ item: PantryItem) -> some View {
        let on = !excluded.contains(item.id)
        return Button {
            if on { excluded.insert(item.id) } else { excluded.remove(item.id) }
        } label: {
            HStack {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                VStack(alignment: .leading) {
                    Text(item.displayName).foregroundStyle(on ? .primary : .secondary)
                    let badge = ExpiryBadge(expiresAt: item.expiresAt)
                    if badge.isUseSoon, let label = badge.label {
                        Text("Expires: \(label)").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}
