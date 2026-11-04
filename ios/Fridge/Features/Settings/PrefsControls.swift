import SwiftUI

/// Controls shared by onboarding (F1.7) and Settings → Food preferences.

/// Wrapping grid of toggle chips.
struct ChipGrid<Item: Identifiable>: View {
    let items: [Item]
    let title: (Item) -> String
    let isOn: (Item) -> Bool
    let toggle: (Item) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                let on = isOn(item)
                Button { toggle(item) } label: {
                    Text(title(item))
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(on ? Color.accentColor.opacity(0.18) : Color(.secondarySystemFill),
                                    in: Capsule())
                        .overlay(Capsule().stroke(on ? Color.accentColor : .clear, lineWidth: 1.5))
                        .foregroundStyle(on ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

struct DietPicker: View {
    @Binding var draft: PrefsDraft

    var body: some View {
        ChipGrid(items: Diet.allCases, title: \.title, isOn: { draft.diets.contains($0) },
                 toggle: { draft.toggle($0) })
    }
}

struct AllergyPicker: View {
    @Binding var draft: PrefsDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChipGrid(items: AllergyChoice.allCases, title: \.title, isOn: { draft.allergies.contains($0) },
                     toggle: { draft.toggle($0) })
            TextField("Other (e.g. mustard, celery)", text: $draft.otherAllergies)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Label("We'll avoid these in recipes, but always check labels.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct ServingsStepper: View {
    @Binding var draft: PrefsDraft

    var body: some View {
        Stepper(value: $draft.servings, in: PrefsDraft.servingsRange) {
            Text("Servings: \(draft.servings)")
        }
    }
}

/// Staples list with remove and an add search (catalog + custom items).
struct StaplesEditor: View {
    @Binding var draft: PrefsDraft
    @State private var query = ""
    @State private var results: [IngredientChoice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(draft.staples) { staple in
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                    Text(staple.name)
                    Spacer()
                    Button { draft.removeStaple(staple.id) } label: {
                        Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(staple.name)")
                }
            }
            if draft.staples.isEmpty {
                Text("No staples. Recipes will only count what's in your pantry.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                TextField("Add a staple…", text: $query).autocorrectionDisabled()
            }
            .padding(8)
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            ForEach(results.filter { r in !draft.staples.contains { $0.id == r.id } }.prefix(5)) { choice in
                Button {
                    draft.addStaple(choice)
                    query = ""
                } label: {
                    Label(choice.name, systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { results = []; return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            results = (try? await PantryAPI.search(q, limit: 8)) ?? []
        }
    }
}
